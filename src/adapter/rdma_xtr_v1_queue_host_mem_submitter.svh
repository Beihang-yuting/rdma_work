// Transactional host-memory access for XTR v1 queue entries.  Queue engines
// own slot selection and doorbells; this adapter deliberately accepts only an
// opaque allocation capability and a mapping-relative byte offset.

function automatic rdma_status rdma_xtr_v1_host_mem_release(
    rdma_host_mem_api api,
    rdma_dma_mapping mapping
  );
    if (api == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "host memory adapter is null");
    return api.\release (mapping);
  endfunction

class rdma_xtr_v1_queue_host_mem_target extends uvm_object;
  `uvm_object_utils(rdma_xtr_v1_queue_host_mem_target)

  // The capability is intentionally not an allocation address or a mapping.
  // It is used only by the submitter to find its private ledger entry.
  local string capability;
  local static longint unsigned next_capability;

  function new(string name = "rdma_xtr_v1_queue_host_mem_target");
    super.new(name);
    if (next_capability == 0)
      next_capability = 1;
    capability = $sformatf("queue-target-%0d", next_capability);
    next_capability++;
  endfunction

  // Exposes no mapping or address; callers can only present this opaque token
  // back to a submitter instance.
  function string capability_key();
    return capability;
  endfunction
endclass

class rdma_xtr_v1_queue_host_mem_ledger_entry extends uvm_object;
  `uvm_object_utils(rdma_xtr_v1_queue_host_mem_ledger_entry)

  rdma_dma_mapping mapping;
  rdma_dma_mapping release_authority;
  rdma_dma_request_context request_context;
  rdma_dma_direction_e direction;
  rdma_dma_permission_t permissions;
  bit released;

  function new(string name = "rdma_xtr_v1_queue_host_mem_ledger_entry");
    super.new(name);
    mapping = null;
    release_authority = null;
    request_context = null;
    direction = RDMA_DMA_DEVICE_READ;
    permissions = '0;
    released = 1'b0;
  endfunction
endclass

class rdma_xtr_v1_queue_host_mem_submitter extends uvm_object;
  `uvm_object_utils(rdma_xtr_v1_queue_host_mem_submitter)

  rdma_host_mem_api host_mem;
  rdma_codec_registry registry;

  // The mapping and all authority snapshots are retained only here.  A
  // target contains no public reference to this ledger or to backing memory.
  protected rdma_xtr_v1_queue_host_mem_ledger_entry ledger[string];

  function new(string name = "rdma_xtr_v1_queue_host_mem_submitter");
    super.new(name);
    host_mem = null;
    registry = null;
    ledger.delete();
  endfunction

  protected function rdma_status invalid(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  protected function rdma_status state_error(string message);
    return rdma_status::make(RDMA_SC_INVALID_STATE, message);
  endfunction

  protected function rdma_status codec_error(string message);
    return rdma_status::make(RDMA_SC_CODEC_ERROR, message);
  endfunction

  protected function rdma_status status_or(
    rdma_status status,
    rdma_status_code_e fallback_code,
    string fallback_message
  );
    if (status != null)
      return status;
    return rdma_status::make(fallback_code, fallback_message);
  endfunction

  protected function rdma_status clone_context(
    rdma_dma_request_context source,
    output rdma_dma_request_context result
  );
    uvm_object cloned;

    result = null;
    if (source == null)
      return invalid("DMA request context is null");
    cloned = source.clone();
    if (cloned == null || !$cast(result, cloned))
      return state_error("DMA request context clone failed");
    return rdma_status::success();
  endfunction

  protected function rdma_status mapping_identity_status(
    rdma_dma_mapping mapping,
    rdma_dma_request_context request_ctx,
    int unsigned requested_size,
    int unsigned requested_alignment,
    rdma_dma_direction_e requested_direction
  );
    longint unsigned mapping_last;

    if (mapping == null)
      return invalid("host memory adapter returned a null mapping");
    if (mapping.state != RDMA_MAPPING_ACTIVE)
      return state_error("host memory adapter returned an inactive mapping");
    if (mapping.function_h == null || request_ctx.function_h == null)
      return state_error("DMA mapping or request Function is null");
    if (!mapping.function_h.same_instance(request_ctx.function_h))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                "DMA mapping Function identity mismatch");
    if (mapping.requester_bdf != request_ctx.requester_bdf)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                "DMA mapping requester BDF mismatch");
    if (mapping.pasid_valid != request_ctx.pasid_valid ||
        mapping.pasid != request_ctx.pasid)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                "DMA mapping PASID identity mismatch");
    if (mapping.dma_domain_valid != request_ctx.dma_domain_valid ||
        mapping.dma_domain_id != request_ctx.dma_domain_id)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                "DMA mapping domain identity mismatch");
    if (requested_size == 0 || mapping.size != requested_size)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                "DMA mapping size does not match allocation");
    if (requested_alignment == 0 ||
        (mapping.iova.value & (requested_alignment - 1'b1)) != 0)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                "DMA mapping IOVA does not satisfy alignment");
    if (mapping.direction != requested_direction)
      return rdma_status::make(RDMA_SC_DMA_PERMISSION,
                                "DMA mapping direction does not match allocation");
    if (requested_direction == RDMA_DMA_DEVICE_READ &&
        !mapping.permissions.device_read)
      return rdma_status::make(RDMA_SC_DMA_PERMISSION,
                                "DMA mapping lacks device-read permission");
    if (requested_direction == RDMA_DMA_DEVICE_WRITE &&
        !mapping.permissions.device_write)
      return rdma_status::make(RDMA_SC_DMA_PERMISSION,
                                "DMA mapping lacks device-write permission");
    if (requested_direction == RDMA_DMA_BIDIRECTIONAL &&
        (!mapping.permissions.device_read || !mapping.permissions.device_write))
      return rdma_status::make(RDMA_SC_DMA_PERMISSION,
                                "DMA mapping lacks bidirectional permissions");
    if (mapping.size == 0)
      return state_error("DMA mapping has zero size");
    if (mapping.iova.value >
        (64'hffff_ffff_ffff_ffff - (mapping.size - 1'b1)))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                "DMA mapping range overflows 64 bits");
    mapping_last = mapping.iova.value + mapping.size - 1'b1;
    if (mapping_last < mapping.iova.value)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                "DMA mapping range wraps");
    return rdma_status::success();
  endfunction

  protected function rdma_status lookup_target(
    rdma_xtr_v1_queue_host_mem_target target,
    output rdma_xtr_v1_queue_host_mem_ledger_entry entry
  );
    string key;

    entry = null;
    if (target == null)
      return invalid("queue host-memory target is null");
    key = target.capability_key();
    if (key.len() == 0 || !ledger.exists(key) || ledger[key] == null)
      return invalid("queue host-memory target is foreign or unknown");
    entry = ledger[key];
    if (entry.mapping == null || entry.release_authority == null)
      return state_error("queue host-memory target ledger is malformed");
    return rdma_status::success();
  endfunction

  protected function rdma_status validate_range(
    rdma_xtr_v1_queue_host_mem_ledger_entry entry,
    longint unsigned offset,
    int unsigned length,
    rdma_dma_direction_e requested_direction,
    rdma_dma_permission_t requested_permissions
  );
    rdma_iova_t first_iova;
    rdma_status status;

    if (entry == null || entry.mapping == null || entry.request_context == null)
      return state_error("queue host-memory target entry is invalid");
    if (entry.released || entry.mapping.state != RDMA_MAPPING_ACTIVE)
      return state_error("queue host-memory target is released");
    if (length == 0)
      return invalid("queue host-memory access length is zero");
    if (offset > (64'hffff_ffff_ffff_ffff - (longint'(length) - 1'b1)))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                "queue host-memory access offset overflows");
    if (offset > (64'hffff_ffff_ffff_ffff - entry.mapping.iova.value))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                "queue host-memory IOVA calculation overflows");
    first_iova.value = entry.mapping.iova.value + offset;
    status = entry.mapping.check_access(
      entry.request_context.function_h,
      entry.request_context.requester_bdf,
      entry.request_context.pasid_valid,
      entry.request_context.pasid,
      entry.request_context.dma_domain_valid,
      entry.request_context.dma_domain_id,
      first_iova,
      length,
      requested_direction,
      requested_permissions
    );
    return status_or(status, RDMA_SC_DMA_TRANSLATION,
                     "DMA mapping access check returned null");
  endfunction

  protected function rdma_status lookup_queue_codec(
    rdma_image_kind_e image_kind,
    string object_type,
    string variant,
    output rdma_codec_base codec
  );
    rdma_codec_key key;
    rdma_status status;

    codec = null;
    if (registry == null)
      return state_error("queue codec registry is not configured");
    key.hw_version = "xtr_v1";
    key.image_kind = image_kind;
    key.object_type = object_type;
    key.variant = variant;
    key.opcode = 8'h00;
    status = registry.lookup(key, codec);
    return status_or(status, RDMA_SC_UNSUPPORTED_OPCODE,
                     "queue codec lookup returned null");
  endfunction

  protected function rdma_status image_to_array(
    rdma_hw_image image,
    output byte write_data[]
  );
    write_data = new[0];
    if (image == null || image.length != image.bytes.size() ||
        image.length == 0)
      return codec_error("encoded queue image is malformed");
    write_data = new[image.bytes.size()];
    foreach (write_data[i])
      write_data[i] = image.bytes[i];
    return rdma_status::success();
  endfunction

  protected function rdma_status complete_read_image(
    rdma_xtr_v1_queue_host_mem_ledger_entry entry,
    longint unsigned offset,
    int unsigned image_length,
    rdma_image_kind_e image_kind,
    rdma_codec_base codec,
    output rdma_hw_image image
  );
    byte read_data[];
    byte unsigned image_bytes[];
    rdma_status status;
    rdma_hw_image candidate;

    image = null;
    status = validate_range(entry, offset, image_length,
                            RDMA_DMA_DEVICE_WRITE,
                            '{device_read:1'b0, device_write:1'b1,
                              atomic:1'b0});
    if (!status.ok())
      return status;
    read_data = new[0];
    status = host_mem.read(entry.mapping, offset, image_length, read_data);
    status = status_or(status, RDMA_SC_DMA_TRANSLATION,
                       "host memory read returned null");
    if (!status.ok())
      return status;
    if (read_data.size() != image_length)
      return codec_error("host memory completion read returned a short image");

    candidate = rdma_hw_image::type_id::create("queue_completion_image");
    if (candidate == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "completion image allocation failed");
    candidate.bytes.delete();
    foreach (read_data[i])
      candidate.bytes.push_back(read_data[i]);
    candidate.length = image_length;
    candidate.alignment = image_length;
    candidate.endian = RDMA_ENDIAN_BIG;
    candidate.image_kind = image_kind;
    candidate.hardware_version = XTR_V1_HW_VERSION;
    candidate.function_generation =
      entry.request_context.function_h.generation;
    candidate.write_target_kind = RDMA_HW_TARGET_NONE;
    candidate.backing_target = '0;
    candidate.hmc_target = '0;
    candidate.bar_target = '0;
    image_bytes = new[image_length];
    foreach (image_bytes[i])
      image_bytes[i] = candidate.bytes[i];
    status = codec.validate_image(candidate);
    status = status_or(status, RDMA_SC_CODEC_ERROR,
                       "queue completion image validation returned null");
    if (!status.ok())
      return status;
    image = candidate;
    return rdma_status::success();
  endfunction

  function rdma_status allocate_target(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_xtr_v1_queue_host_mem_target target
  );
    rdma_status status;
    rdma_status release_status;
    rdma_dma_mapping mapping;
    rdma_dma_mapping authority;
    rdma_dma_request_context context_snapshot;
    rdma_xtr_v1_queue_host_mem_target candidate;
    rdma_xtr_v1_queue_host_mem_ledger_entry entry;

    target = null;
    if (host_mem == null)
      return state_error("queue host-memory adapter is not configured");
    if (request_context == null)
      return invalid("DMA request context is null");
    status = request_context.validate();
    if (!status.ok())
      return status;
    if (size == 0 || alignment == 0 ||
        (alignment & (alignment - 1'b1)) != 0)
      return invalid("allocation size/alignment is invalid");
    if (!(direction inside {RDMA_DMA_DEVICE_READ, RDMA_DMA_DEVICE_WRITE,
                            RDMA_DMA_BIDIRECTIONAL}))
      return invalid("allocation DMA direction is invalid");

    mapping = null;
    status = host_mem.allocate(request_context, size, alignment, direction,
                               mapping);
    status = status_or(status, RDMA_SC_DMA_TRANSLATION,
                       "host memory allocation returned null status");
    if (!status.ok())
      return status;
    status = mapping_identity_status(mapping, request_context, size,
                                     alignment, direction);
    if (!status.ok()) begin
      // An adapter may have returned a mapping with malformed identity.  It
      // is still released exactly once before the failed allocation exits.
      release_status = rdma_xtr_v1_host_mem_release(host_mem, mapping);
      if (release_status == null || !release_status.ok())
        return status;
      return status;
    end
    authority = null;
    status = mapping.snapshot_release_authority(authority);
    status = status_or(status, RDMA_SC_INVALID_STATE,
                       "DMA mapping authority snapshot returned null");
    if (status.ok() && authority == null)
      status = state_error("DMA mapping authority snapshot returned null");
    if (!status.ok()) begin
      release_status = rdma_xtr_v1_host_mem_release(host_mem, mapping);
      return status;
    end
    status = clone_context(request_context, context_snapshot);
    if (!status.ok()) begin
      release_status = rdma_xtr_v1_host_mem_release(host_mem, mapping);
      return status;
    end

    candidate = rdma_xtr_v1_queue_host_mem_target::type_id::create(
      "queue_host_mem_target");
    entry = rdma_xtr_v1_queue_host_mem_ledger_entry::type_id::create(
      "queue_host_mem_ledger_entry");
    if (candidate == null || entry == null) begin
      release_status = rdma_xtr_v1_host_mem_release(host_mem, mapping);
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "queue host-memory target creation failed");
    end
    entry.mapping = mapping;
    entry.release_authority = authority;
    entry.request_context = context_snapshot;
    entry.direction = direction;
    entry.permissions.device_read =
      direction inside {RDMA_DMA_DEVICE_READ, RDMA_DMA_BIDIRECTIONAL};
    entry.permissions.device_write =
      direction inside {RDMA_DMA_DEVICE_WRITE, RDMA_DMA_BIDIRECTIONAL};
    entry.permissions.atomic = 1'b0;
    entry.released = 1'b0;
    ledger[candidate.capability_key()] = entry;
    target = candidate;
    return rdma_status::success();
  endfunction

  protected function rdma_status write_queue_entry(
    rdma_xtr_v1_queue_host_mem_target target,
    longint unsigned offset,
    rdma_hw_model model,
    rdma_image_kind_e image_kind,
    string variant,
    int unsigned expected_length,
    output rdma_hw_image image
  );
    rdma_xtr_v1_queue_host_mem_ledger_entry entry;
    rdma_codec_base codec;
    rdma_hw_image candidate;
    rdma_hw_image readback_image;
    rdma_status status;
    byte write_data[];
    byte read_data[];

    image = null;
    status = lookup_target(target, entry);
    if (!status.ok())
      return status;
    status = lookup_queue_codec(image_kind, "sqe", variant, codec);
    if (image_kind == RDMA_IMAGE_RQE)
      status = lookup_queue_codec(image_kind, "rqe", "default", codec);
    if (!status.ok())
      return status;
    candidate = null;
    status = codec.encode(model, candidate);
    status = status_or(status, RDMA_SC_CODEC_ERROR,
                       "queue codec encode returned null status");
    if (!status.ok())
      return status;
    if (candidate == null || candidate.length != expected_length ||
        candidate.bytes.size() != expected_length ||
        candidate.alignment != expected_length ||
        candidate.endian != RDMA_ENDIAN_BIG ||
        candidate.image_kind != image_kind ||
        candidate.hardware_version != XTR_V1_HW_VERSION ||
        candidate.write_target_kind != RDMA_HW_TARGET_NONE ||
        candidate.backing_target.value != 0 ||
        candidate.hmc_target.value != 0 || candidate.bar_target.value != 0 ||
        candidate.function_generation !=
          entry.request_context.function_h.generation)
      return codec_error("queue codec returned an image of the wrong size");
    status = codec.validate_image(candidate);
    status = status_or(status, RDMA_SC_CODEC_ERROR,
                       "queue codec image validation returned null");
    if (!status.ok())
      return status;
    status = validate_range(entry, offset, expected_length,
                            RDMA_DMA_DEVICE_READ,
                            '{device_read:1'b1, device_write:1'b0,
                              atomic:1'b0});
    if (!status.ok())
      return status;
    status = image_to_array(candidate, write_data);
    if (!status.ok())
      return status;
    status = host_mem.write(entry.mapping, offset, write_data);
    status = status_or(status, RDMA_SC_DMA_TRANSLATION,
                       "host memory write returned null status");
    if (!status.ok())
      return status;
    read_data = new[0];
    status = host_mem.read(entry.mapping, offset, expected_length, read_data);
    status = status_or(status, RDMA_SC_DMA_TRANSLATION,
                       "host memory readback returned null status");
    if (!status.ok())
      return status;
    if (read_data.size() != expected_length)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                "queue host-memory readback is short");
    foreach (read_data[i]) begin
      if (read_data[i] !== write_data[i])
        return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                  "queue host-memory readback mismatch");
    end
    // Validate the readback image too.  This catches an adapter that returns
    // bytes with malformed metadata or a codec image that was not detached.
    readback_image = rdma_hw_image::type_id::create("queue_readback_image");
    readback_image.bytes.delete();
    foreach (read_data[i])
      readback_image.bytes.push_back(read_data[i]);
    readback_image.length = expected_length;
    readback_image.alignment = expected_length;
    readback_image.endian = RDMA_ENDIAN_BIG;
    readback_image.image_kind = image_kind;
    readback_image.hardware_version = XTR_V1_HW_VERSION;
    readback_image.function_generation = candidate.function_generation;
    status = codec.validate_image(readback_image);
    if (!status.ok())
      return status;
    image = candidate;
    return rdma_status::success();
  endfunction

  function rdma_status write_sqe(
    rdma_xtr_v1_queue_host_mem_target target,
    longint unsigned offset,
    rdma_xtr_v1_sqe_model model,
    output rdma_hw_image image
  );
    string variant;
    if (model == null)
      begin image = null; return invalid("SQE model is null"); end
    case (model.transport)
      RDMA_TRANSPORT_RC: variant = "rc";
      RDMA_TRANSPORT_UD: variant = "ud";
      RDMA_TRANSPORT_URC: variant = "urc";
      default: begin image = null; return invalid("SQE transport is unsupported"); end
    endcase
    return write_queue_entry(target, offset, model, RDMA_IMAGE_SQE, variant,
                             XTR_V1_WQE_BYTES, image);
  endfunction

  function rdma_status write_rqe(
    rdma_xtr_v1_queue_host_mem_target target,
    longint unsigned offset,
    rdma_xtr_v1_rqe_model model,
    output rdma_hw_image image
  );
    if (model == null)
      begin image = null; return invalid("RQE model is null"); end
    return write_queue_entry(target, offset, model, RDMA_IMAGE_RQE, "default",
                             XTR_V1_RQE_BYTES, image);
  endfunction

  function rdma_status read_cqe(
    rdma_xtr_v1_queue_host_mem_target target,
    longint unsigned offset,
    output rdma_xtr_v1_cqe_model model,
    output rdma_hw_image image
  );
    rdma_xtr_v1_queue_host_mem_ledger_entry entry;
    rdma_codec_base codec;
    rdma_hw_model decoded;
    rdma_status status;
    rdma_hw_image candidate_image;
    model = null; image = null;
    status = lookup_target(target, entry); if (!status.ok()) return status;
    status = lookup_queue_codec(RDMA_IMAGE_CQE, "cqe", "default", codec);
    if (!status.ok()) return status;
    status = complete_read_image(entry, offset, XTR_V1_CQE_BYTES,
                                 RDMA_IMAGE_CQE, codec,
                                 candidate_image);
    if (!status.ok()) return status;
    status = codec.decode(candidate_image, decoded);
    status = status_or(status, RDMA_SC_CODEC_ERROR,
                       "CQE decode returned null status");
    if (!status.ok() || decoded == null || !$cast(model, decoded)) begin
      model = null; image = null;
      return status.ok() ? codec_error("decoded CQE model type mismatch") : status;
    end
    image = candidate_image;
    return rdma_status::success();
  endfunction

  function rdma_status read_ceqe(
    rdma_xtr_v1_queue_host_mem_target target,
    longint unsigned offset,
    output rdma_xtr_v1_ceqe_model model,
    output rdma_hw_image image
  );
    rdma_xtr_v1_queue_host_mem_ledger_entry entry;
    rdma_codec_base codec;
    rdma_hw_model decoded;
    rdma_status status;
    rdma_hw_image candidate_image;
    model = null; image = null;
    status = lookup_target(target, entry); if (!status.ok()) return status;
    status = lookup_queue_codec(RDMA_IMAGE_CEQE, "ceqe", "default", codec);
    if (!status.ok()) return status;
    status = complete_read_image(entry, offset, XTR_V1_CEQE_BYTES,
                                 RDMA_IMAGE_CEQE, codec,
                                 candidate_image);
    if (!status.ok()) return status;
    status = codec.decode(candidate_image, decoded);
    status = status_or(status, RDMA_SC_CODEC_ERROR,
                       "CEQE decode returned null status");
    if (!status.ok() || decoded == null || !$cast(model, decoded)) begin
      model = null; image = null;
      return status.ok() ? codec_error("decoded CEQE model type mismatch") : status;
    end
    image = candidate_image;
    return rdma_status::success();
  endfunction

  function rdma_status read_aeqe(
    rdma_xtr_v1_queue_host_mem_target target,
    longint unsigned offset,
    output rdma_xtr_v1_aeqe_model model,
    output rdma_hw_image image
  );
    rdma_xtr_v1_queue_host_mem_ledger_entry entry;
    rdma_codec_base codec;
    rdma_hw_model decoded;
    rdma_status status;
    rdma_hw_image candidate_image;
    model = null; image = null;
    status = lookup_target(target, entry); if (!status.ok()) return status;
    status = lookup_queue_codec(RDMA_IMAGE_AEQE, "aeqe", "default", codec);
    if (!status.ok()) return status;
    status = complete_read_image(entry, offset, XTR_V1_AEQE_BYTES,
                                 RDMA_IMAGE_AEQE, codec,
                                 candidate_image);
    if (!status.ok()) return status;
    status = codec.decode(candidate_image, decoded);
    status = status_or(status, RDMA_SC_CODEC_ERROR,
                       "AEQE decode returned null status");
    if (!status.ok() || decoded == null || !$cast(model, decoded)) begin
      model = null; image = null;
      return status.ok() ? codec_error("decoded AEQE model type mismatch") : status;
    end
    image = candidate_image;
    return rdma_status::success();
  endfunction

  function rdma_status release_target(
    rdma_xtr_v1_queue_host_mem_target target
  );
    rdma_xtr_v1_queue_host_mem_ledger_entry entry;
    rdma_status status;

    status = lookup_target(target, entry);
    if (!status.ok())
      return status;
    if (entry.released)
      return state_error("queue host-memory target was already released");
    status = entry.mapping.release_authority_status(entry.release_authority);
    status = status_or(status, RDMA_SC_INVALID_STATE,
                       "DMA release authority check returned null");
    if (!status.ok())
      return status;
    status = rdma_xtr_v1_host_mem_release(host_mem, entry.mapping);
    status = status_or(status, RDMA_SC_DMA_TRANSLATION,
                       "host memory release returned null status");
    if (!status.ok())
      return status;
    entry.released = 1'b1;
    return rdma_status::success();
  endfunction
endclass
