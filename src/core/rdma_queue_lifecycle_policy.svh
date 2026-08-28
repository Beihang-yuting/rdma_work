virtual class rdma_queue_lifecycle_policy extends uvm_object;
  function new(string name = "rdma_queue_lifecycle_policy");
    super.new(name);
  endfunction

  pure virtual function rdma_resource_kind_e resource_kind();
  pure virtual function rdma_status preflight(
    rdma_function_binding binding, rdma_semantic_request request,
    rdma_resource_manager manager, output rdma_queue_preflight result);
  pure virtual function rdma_status reserve_resource(
    rdma_resource_manager manager, rdma_function_binding binding,
    rdma_semantic_request request, output rdma_queue_resource resource);
  pure virtual function rdma_status build_create_context(
    rdma_queue_resource resource, rdma_queue_backing_plan plan,
    output rdma_hw_model context_model,
    output byte unsigned context_slot_image[],
    output byte unsigned context_shadow_image[]);
  pure virtual function rdma_status build_create_command(
    rdma_function_handle owner, rdma_queue_resource resource,
    rdma_hw_model context_model, time timeout,
    output rdma_cmq_command_desc command);
  pure virtual function rdma_status build_object_command(
    bit [7:0] opcode, rdma_function_handle owner,
    rdma_queue_resource resource, time timeout,
    output rdma_cmq_command_desc command);
  pure virtual function rdma_status build_flush_command(
    rdma_function_handle owner, rdma_queue_flush_target target,
    time timeout, output rdma_cmq_command_desc command);
  // Classify a terminal QUERY completion as trustworthy hardware-presence
  // evidence.  A successful status alone is deliberately insufficient: the
  // response payload must authenticate to the profile's typed context codec
  // and identify this queue's local object ID.  Inconclusive responses leave
  // the outputs at UNKNOWN/0 and return a status suitable for continued
  // recovery.
  pure virtual function rdma_status classify_query_completion(
    rdma_queue_resource resource,
    rdma_cmq_completion completion,
    output rdma_hw_presence_e presence,
    output bit conclusive);
  pure virtual function void hardware_cleanup_roles(
    output rdma_queue_backing_role_e flush_roles[$],
    output rdma_queue_flush_phase_e flush_phases[$],
    output bit delete_before_flush);
  pure virtual function void local_cleanup_roles(
    output rdma_queue_backing_role_e roles[$],
    output bit release_context_first);

  protected function rdma_status invalid_argument(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  protected function rdma_status invalid_state(string message);
    return rdma_status::make(RDMA_SC_INVALID_STATE, message);
  endfunction

  protected function rdma_status unsupported(string message);
    return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE, message);
  endfunction

  protected function bit same_function(
    rdma_function_handle lhs,
    rdma_function_handle rhs
  );
    if (lhs == null || rhs == null)
      return 1'b0;
    return lhs.kind == RDMA_RESOURCE_FUNCTION &&
           rhs.kind == RDMA_RESOURCE_FUNCTION &&
           lhs.function_uid == rhs.function_uid &&
           lhs.object_id == rhs.object_id &&
           lhs.generation == rhs.generation;
  endfunction

  protected function rdma_status queue_resource_owner_status(
    rdma_queue_resource resource,
    rdma_resource_kind_e expected_kind
  );
    rdma_status status;

    if (resource == null || resource.owner == null || resource.handle == null)
      return invalid_argument("typed queue resource identity is incomplete");
    if (resource.resource_kind() != expected_kind ||
        resource.handle.kind != expected_kind)
      return invalid_argument("typed queue resource kind is invalid");
    status = rdma_cmq_function_status(resource.owner,
                                      "typed queue resource");
    if (!status.ok())
      return status;
    return rdma_handle_owner_status(resource.handle, resource.owner);
  endfunction

  protected function rdma_status command_resource_owner_status(
    rdma_function_handle owner,
    rdma_queue_resource resource,
    rdma_resource_kind_e expected_kind
  );
    rdma_status status;

    status = queue_resource_owner_status(resource, expected_kind);
    if (!status.ok())
      return status;
    if (!same_function(owner, resource.owner))
      return invalid_argument("queue command owner does not match resource");
    return rdma_status::success();
  endfunction

  protected function rdma_status command_owner_status(
    rdma_function_handle owner,
    rdma_queue_resource resource,
    rdma_handle context_h,
    rdma_resource_kind_e expected_kind
  );
    rdma_status status;

    status = command_resource_owner_status(owner, resource, expected_kind);
    if (!status.ok())
      return status;
    if (context_h == null || context_h.kind != expected_kind)
      return invalid_argument("queue command context handle is invalid");
    return rdma_handle_owner_status(context_h, owner);
  endfunction

  protected function rdma_status backing_owner_status(
    rdma_queue_backing_ref ref_value,
    rdma_function_handle owner
  );
    if (ref_value == null || ref_value.mapping == null ||
        ref_value.mapping.function_h == null)
      return invalid_argument("queue backing Function is missing");
    if (!same_function(ref_value.mapping.function_h, owner))
      return invalid_argument("queue backing belongs to another Function");
    return rdma_status::success();
  endfunction

  protected function rdma_status common_preflight_status(
    rdma_function_binding binding,
    rdma_semantic_request request,
    rdma_resource_manager manager,
    output rdma_function_handle owner
  );
    rdma_status status;
    rdma_function_handle binding_owner;

    owner = null;
    if (binding == null || request == null || manager == null)
      return invalid_argument("queue policy preflight input is null");
    status = binding.validate();
    if (!status.ok())
      return status;
    if (binding.state != RDMA_BIND_ACTIVE || binding.owner_h == null ||
        !$cast(binding_owner, binding.owner_h))
      return invalid_state("queue policy requires an ACTIVE Function binding");
    if (request.owner == null || !same_function(binding_owner,
                                                 request.owner))
      return invalid_argument("queue request owner does not match binding");
    status = request.validate();
    if (!status.ok())
      return status;
    owner = binding_owner;
    return rdma_status::success();
  endfunction

  protected function rdma_status dependency_status(
    rdma_resource_manager manager,
    rdma_function_handle owner,
    rdma_handle dependency,
    rdma_resource_kind_e expected_kind,
    bit allow_null
  );
    rdma_resource dependency_resource;
    rdma_status status;

    if (dependency == null) begin
      if (allow_null)
        return rdma_status::success();
      return invalid_argument("required queue dependency is null");
    end
    if (dependency.kind != expected_kind)
      return invalid_argument("queue dependency kind is invalid");
    status = manager.lookup(dependency, dependency_resource);
    if (!status.ok())
      return status;
    if (dependency_resource == null || dependency_resource.owner == null)
      return invalid_state("queue dependency lookup returned no owner");
    if (!dependency_resource.owner.same_instance(owner))
      return invalid_argument("queue dependency belongs to another Function");
    if (dependency_resource.state inside {RDMA_RESOURCE_QUIESCING,
                                          RDMA_RESOURCE_ERROR})
      return invalid_state("closing queue dependency cannot admit create");
    return rdma_status::success();
  endfunction

  protected function int unsigned backing_role_count(
    rdma_queue_backing_spec spec,
    rdma_queue_backing_role_e role
  );
    int unsigned count;
    count = 0;
    if (spec == null)
      return 0;
    foreach (spec.slices[i]) begin
      if (spec.slices[i] != null && spec.slices[i].role == role)
        count++;
    end
    return count;
  endfunction

  protected function rdma_status clone_backing_spec(
    rdma_queue_backing_spec source,
    output rdma_queue_backing_spec result
  );
    uvm_object cloned_object;

    result = null;
    if (source == null)
      return invalid_argument("queue backing specification is null");
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(result, cloned_object) ||
        result == source) begin
      result = null;
      return invalid_state("queue backing specification clone failed");
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status checked_ring_layout(
    string name,
    rdma_queue_backing_role_e role,
    int unsigned depth,
    int unsigned entry_size_bytes,
    bit initial_polarity,
    longint unsigned capability_limit,
    output rdma_queue_ring_layout layout
  );
    longint unsigned logical_bytes;
    longint unsigned storage_bytes;
    rdma_queue_ring_layout candidate;
    rdma_status status;

    layout = null;
    if (depth == 0 || entry_size_bytes == 0)
      return invalid_argument("queue ring depth or entry size is zero");
    if ({32'b0, depth} >
        64'hffff_ffff_ffff_ffff / entry_size_bytes)
      return invalid_argument("queue ring logical size overflows");
    logical_bytes = longint'(depth) * entry_size_bytes;
    if (logical_bytes > 64'hffff_ffff_ffff_f000)
      return invalid_argument("queue ring alignment overflows");
    storage_bytes = (logical_bytes + 4095) & 64'hffff_ffff_ffff_f000;
    if (storage_bytes > capability_limit)
      return invalid_argument("queue ring exceeds Function capability");
    if (role == RDMA_QUEUE_ROLE_SRQ_SGB) begin
      if (storage_bytes > 32'hffff_ffff)
        return invalid_argument("queue SGB exceeds host allocation width");
    end else if (storage_bytes > 64'h0020_0000) begin
      return invalid_argument("queue ring exceeds one page directory");
    end

    candidate = rdma_queue_ring_layout::type_id::create(name);
    candidate.role = role;
    candidate.entry_size_bytes = entry_size_bytes;
    candidate.depth = depth;
    candidate.logical_bytes = logical_bytes;
    candidate.storage_bytes = storage_bytes;
    candidate.page_count = storage_bytes / 4096;
    candidate.initial_polarity = initial_polarity;
    status = candidate.validate_metadata();
    if (!status.ok())
      return status;
    layout = candidate;
    return rdma_status::success();
  endfunction

  protected function rdma_status publish_preflight(
    rdma_queue_preflight candidate,
    output rdma_queue_preflight result
  );
    rdma_status status;
    result = null;
    if (candidate == null)
      return invalid_state("queue preflight candidate is null");
    status = candidate.validate();
    if (!status.ok())
      return status;
    result = candidate;
    return rdma_status::success();
  endfunction

  protected function rdma_status projected_handle(
    string name,
    rdma_handle lifecycle_source,
    rdma_resource_kind_e kind,
    int unsigned local_id,
    int unsigned width,
    output rdma_handle handle
  );
    longint unsigned limit;
    rdma_handle candidate;

    handle = null;
    if (lifecycle_source == null || lifecycle_source.kind != kind)
      return invalid_argument("typed queue resource handle is invalid");
    limit = 64'h1 << width;
    if ({32'b0, local_id} >= limit)
      return invalid_argument("queue local ID exceeds context field width");
    candidate = rdma_handle::type_id::create(name);
    candidate.kind = kind;
    candidate.function_uid = lifecycle_source.function_uid;
    candidate.generation = lifecycle_source.generation;
    candidate.object_id = local_id;
    handle = candidate;
    return rdma_status::success();
  endfunction

  protected function rdma_status projected_dependency_status(
    rdma_handle dependency,
    rdma_handle lifecycle_source,
    rdma_resource_kind_e expected_kind,
    int unsigned width,
    bit allow_null
  );
    longint unsigned limit;
    if (dependency == null && allow_null)
      return rdma_status::success();
    if (dependency == null || dependency.kind != expected_kind)
      return invalid_argument("projected context dependency is invalid");
    if (lifecycle_source == null ||
        dependency.function_uid != lifecycle_source.function_uid)
      return invalid_argument("projected dependency Function does not match");
    if (dependency.generation != lifecycle_source.generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "projected dependency generation does not match"
      );
    limit = 64'h1 << width;
    if ({32'b0, dependency.object_id} >= limit)
      return invalid_argument("projected dependency ID exceeds field width");
    return rdma_status::success();
  endfunction

  protected function rdma_status find_ring(
    rdma_queue_backing_plan plan,
    rdma_queue_backing_role_e role,
    output rdma_queue_ring_layout ring
  );
    rdma_status status;
    ring = null;
    if (plan == null)
      return invalid_argument("queue backing plan is null");
    foreach (plan.rings[i]) begin
      if (plan.rings[i] != null && plan.rings[i].role == role) begin
        if (ring != null)
          return invalid_state("queue backing plan repeats a ring role");
        ring = plan.rings[i];
      end
    end
    if (ring == null)
      return invalid_state("queue backing plan omits a ring role");
    status = ring.validate_metadata();
    if (!status.ok()) begin
      ring = null;
      return status;
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status find_backing_ref(
    rdma_queue_backing_plan plan,
    rdma_queue_backing_role_e role,
    output rdma_queue_backing_ref ref_value
  );
    rdma_status status;
    ref_value = null;
    if (plan == null)
      return invalid_argument("queue backing plan is null");
    foreach (plan.refs[i]) begin
      if (plan.refs[i] != null && plan.refs[i].role == role) begin
        if (ref_value != null)
          return invalid_state("queue backing plan repeats a backing role");
        ref_value = plan.refs[i];
      end
    end
    if (ref_value == null)
      return invalid_state("queue backing plan omits a backing role");
    status = ref_value.validate();
    if (!status.ok()) begin
      ref_value = null;
      return status;
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status backing_iova(
    rdma_queue_backing_ref ref_value,
    output rdma_backing_addr_t address
  );
    address = '0;
    if (ref_value == null || ref_value.mapping == null)
      return invalid_argument("queue backing IOVA source is null");
    if (ref_value.mapping.iova.value >
        64'hffff_ffff_ffff_ffff - ref_value.mapping_offset)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "queue backing IOVA projection overflows");
    address.value = ref_value.mapping.iova.value + ref_value.mapping_offset;
    if ((address.value & 64'hfff) != 0) begin
      address = '0;
      return invalid_argument("queue backing IOVA is not page aligned");
    end
    return rdma_status::success();
  endfunction

  protected function rdma_status context_ref_status(
    rdma_queue_backing_plan plan,
    rdma_function_handle owner,
    rdma_resource_kind_e kind,
    int unsigned local_id,
    longint unsigned view_offset,
    longint unsigned view_length,
    output rdma_backing_addr_t shadow_base
  );
    rdma_context_backing_ref context_ref;

    shadow_base = '0;
    if (plan == null || plan.context_ref == null)
      return invalid_state("queue context backing reference is missing");
    context_ref = plan.context_ref;
    if (!same_function(context_ref.owner, owner))
      return invalid_argument("queue context belongs to another Function");
    if (context_ref.resource_kind != kind ||
        context_ref.local_id != local_id ||
        context_ref.slot_length != (kind == RDMA_RESOURCE_SRQ ? 32 : 64) ||
        context_ref.shadow_view_offset != view_offset ||
        context_ref.shadow_view_length != view_length ||
        context_ref.shadow_pointer_base.value == 0 ||
        (context_ref.shadow_pointer_base.value & 64'hfff) != 0)
      return invalid_state("queue context backing geometry is invalid");
    shadow_base = context_ref.shadow_pointer_base;
    return rdma_status::success();
  endfunction

  protected function void set_indirect_layout(
    rdma_page_table_layout layout,
    rdma_backing_addr_t pd_address
  );
    layout.mode = RDMA_OBJECT_INDIRECT_4K;
    layout.sd_base = '0;
    layout.current_base = pd_address;
    layout.current_valid = 1'b1;
    layout.next_base = pd_address;
    layout.next_valid = 1'b1;
  endfunction

  protected function rdma_status encode_context(
    rdma_hw_model model,
    rdma_image_kind_e image_kind,
    string object_type,
    bit [7:0] opcode,
    output byte unsigned bytes[]
  );
    rdma_codec_registry registry;
    rdma_codec_key key;
    rdma_codec_base codec;
    rdma_hw_image image;
    rdma_status status;
    byte unsigned candidate[];

    bytes = new[0];
    if (model == null)
      return invalid_argument("queue context model is null");
    registry = rdma_codec_registry::type_id::create(
      "queue_policy_context_registry");
    status = rdma_xtr_v1_register_context_body_codecs(registry);
    if (!status.ok())
      return status;
    key.hw_version = "xtr_v1";
    key.image_kind = image_kind;
    key.object_type = object_type;
    key.variant = "create";
    key.opcode = opcode;
    status = registry.lookup(key, codec);
    if (!status.ok())
      return status;
    status = codec.encode(model, image);
    if (!status.ok())
      return status;
    if (image == null || image.bytes.size() != 64 || image.length != 64)
      return invalid_state("context codec did not publish a canonical image");
    candidate = new[image.bytes.size()];
    foreach (candidate[i])
      candidate[i] = image.bytes[i];
    bytes = candidate;
    return rdma_status::success();
  endfunction

  protected function rdma_status build_command_desc(
    rdma_function_handle owner,
    bit [7:0] opcode,
    string variant,
    rdma_hw_model body,
    time timeout,
    output rdma_cmq_command_desc command
  );
    rdma_cmq_command_desc candidate;
    rdma_cmq_opcode_key key;
    rdma_status status;

    command = null;
    status = rdma_cmq_function_status(owner, "queue policy command");
    if (!status.ok())
      return status;
    if (body == null || timeout == 0)
      return invalid_argument("queue command body or timeout is invalid");
    key = rdma_cmq_opcode_key::type_id::create("queue_policy_opcode_key");
    key.profile_name = "xtr_v1";
    key.opcode = opcode;
    key.variant = variant;
    candidate = rdma_cmq_command_desc::type_id::create(
      "queue_policy_command");
    candidate.function_h = rdma_clone_function_handle_value(
      owner, "queue policy command");
    candidate.opcode_key = key;
    candidate.body = rdma_cmq_clone_hw_model_value(body,
                                                    "queue policy command");
    candidate.timeout = timeout;
    status = candidate.validate();
    if (!status.ok())
      return status;
    command = candidate;
    return rdma_status::success();
  endfunction

  protected function rdma_status build_object_desc(
    bit [7:0] opcode,
    bit [7:0] delete_opcode,
    bit [7:0] query_opcode,
    rdma_function_handle owner,
    rdma_handle lifecycle_handle,
    rdma_resource_kind_e kind,
    int unsigned local_id,
    int unsigned width,
    time timeout,
    output rdma_cmq_command_desc command
  );
    rdma_xtr_v1_object_id_command_body body;
    rdma_handle object_h;
    rdma_status status;
    string variant;

    command = null;
    if (opcode == delete_opcode)
      variant = "delete";
    else if (opcode == query_opcode)
      variant = "query";
    else
      return unsupported("queue object command opcode is not supported");
    status = projected_handle("queue_object_projection", lifecycle_handle,
                              kind, local_id, width, object_h);
    if (!status.ok())
      return status;
    status = rdma_handle_owner_status(object_h, owner);
    if (!status.ok())
      return status;
    body = rdma_xtr_v1_object_id_command_body::type_id::create(
      "queue_object_command_body");
    body.object_h = object_h;
    return build_command_desc(owner, opcode, variant, body, timeout, command);
  endfunction

  protected function rdma_status build_pd_flush_desc(
    rdma_function_handle owner,
    rdma_queue_flush_target target,
    time timeout,
    output rdma_cmq_command_desc command
  );
    rdma_xtr_v1_occ_flush_body body;
    rdma_backing_addr_t pd_address;
    rdma_status status;

    command = null;
    if (target == null)
      return invalid_argument("queue flush target is null");
    status = target.validate();
    if (!status.ok())
      return status;
    status = backing_owner_status(target.pd_ref, owner);
    if (!status.ok())
      return status;
    status = backing_iova(target.pd_ref, pd_address);
    if (!status.ok())
      return status;
    body = rdma_xtr_v1_occ_flush_body::type_id::create(
      "queue_pd_occ_flush_body");
    body.pd = 1'b1;
    body.qpn = '0;
    body.pd_backing = pd_address;
    return build_command_desc(owner, XTR_V1_OP_OCC_FLUSH, "occ_flush",
                              body, timeout, command);
  endfunction

  // Build a context image suitable for QUERY decoding.  The returned query
  // slices contain all object-identifying fields, while a few create-context
  // builders require dependency handles that are not part of the queue's
  // authoritative local-ID projection (for example a CQ's CEQ handle or an
  // SRQ's PD handle).  Use harmless in-range placeholders for those fields;
  // the query payload is overlaid below before decoding, so no placeholder
  // can become presence evidence.
  protected function rdma_status query_builder_view(
    rdma_queue_resource resource,
    output rdma_queue_resource builder_resource
  );
    uvm_object cloned_object;
    rdma_cq cq;
    rdma_srq srq;
    rdma_handle placeholder;

    builder_resource = null;
    if (resource == null)
      return invalid_argument("query resource is null");
    cloned_object = resource.clone();
    if (cloned_object == null || !$cast(builder_resource, cloned_object) ||
        builder_resource == resource)
      return invalid_state("query builder resource clone failed");
    case (resource.resource_kind())
      RDMA_RESOURCE_CQ: begin
        if (!$cast(cq, builder_resource))
          return invalid_state("query CQ builder projection failed");
        // CQC's CEQN is in the returned payload.  A null dependency is
        // explicitly supported by the CQC builder and avoids confusing the
        // opaque registry incarnation ID with the 12-bit local CEQ ID.
        cq.ceq_h = null;
      end
      RDMA_RESOURCE_SRQ: begin
        if (!$cast(srq, builder_resource) || srq.pd_h == null)
          return invalid_state("query SRQ builder projection failed");
        placeholder = rdma_handle::type_id::create("query_pd_placeholder");
        placeholder.kind = RDMA_RESOURCE_PD;
        placeholder.function_uid = srq.handle.function_uid;
        placeholder.generation = srq.handle.generation;
        placeholder.object_id = 0;
        srq.pd_h = placeholder;
      end
      default: begin
      end
    endcase
    return rdma_status::success();
  endfunction

  protected function rdma_status classify_query_common(
    rdma_queue_resource resource,
    rdma_cmq_completion completion,
    bit [7:0] expected_query_opcode,
    bit [7:0] expected_create_opcode,
    rdma_image_kind_e image_kind,
    string object_type,
    int unsigned payload_offset,
    int unsigned payload_length,
    bit [7:0] absent_ecode,
    output rdma_hw_presence_e presence,
    output bit conclusive
  );
    rdma_xtr_v1_cmq_completion payload;
    rdma_queue_resource builder_resource;
    rdma_queue_backing_plan plan;
    rdma_hw_model canonical_model;
    byte unsigned canonical_bytes[];
    byte unsigned ignored_shadow[];
    rdma_hw_image query_image;
    rdma_codec_registry registry;
    rdma_codec_key key;
    rdma_codec_base codec;
    rdma_hw_model decoded_model;
    rdma_status status;
    bit typed_match;

    presence = RDMA_HW_PRESENCE_UNKNOWN;
    conclusive = 1'b0;

    if (resource == null || resource.handle == null || resource.owner == null)
      return invalid_argument("query classification resource identity is incomplete");
    if (resource.resource_kind() == RDMA_RESOURCE_CQ &&
        image_kind != RDMA_IMAGE_CQC)
      return invalid_state("query CQC image kind is inconsistent");
    if (resource.resource_kind() == RDMA_RESOURCE_SRQ &&
        image_kind != RDMA_IMAGE_SRQC)
      return invalid_state("query SRQC image kind is inconsistent");
    if (resource.resource_kind() == RDMA_RESOURCE_CEQ &&
        image_kind != RDMA_IMAGE_CEQC)
      return invalid_state("query CEQC image kind is inconsistent");
    if (resource.resource_kind() == RDMA_RESOURCE_AEQ &&
        image_kind != RDMA_IMAGE_AEQC)
      return invalid_state("query AEQC image kind is inconsistent");

    if (completion == null || completion.ticket == null ||
        completion.ticket.opcode_key == null || completion.status == null)
      return rdma_status::success();
    if (!completion.status.ok() &&
        completion.status.code inside {RDMA_SC_TIMEOUT,
                                      RDMA_SC_RESET_CANCELLED})
      return rdma_status::success();
    if (completion.ticket.opcode_key.opcode != expected_query_opcode)
      return rdma_status::success();
    if (!$cast(payload, completion.decoded_response) || payload == null)
      return rdma_status::success();
    if (payload.opcode != expected_query_opcode ||
        payload.opcode != completion.ticket.opcode_key.opcode)
      return rdma_status::success();

    // Error ecodes are meaningful only when authenticated to this exact
    // query opcode.  Query errors commonly carry no object bytes, so apply
    // the absent whitelist before the success-payload length check.
    if (payload.command_ecode == absent_ecode) begin
      presence = RDMA_HW_PRESENCE_ABSENT;
      conclusive = 1'b1;
      return rdma_status::success();
    end
    if (!completion.status.ok() || payload.object_payload.size() !=
        payload_length)
      return rdma_status::success();
    if (payload_offset + payload_length > 64)
      return invalid_state("query payload bounds exceed context image");

    plan = resource.queue_plan;
    if (plan == null || plan.resource_kind != resource.resource_kind())
      return rdma_status::success();
    status = query_builder_view(resource, builder_resource);
    if (!status.ok())
      return status;
    status = build_create_context(builder_resource, plan, canonical_model,
                                  canonical_bytes, ignored_shadow);
    if (!status.ok() || canonical_model == null ||
        canonical_bytes.size() != 64)
      return status.ok() ? rdma_status::success() : status;

    query_image = rdma_hw_image::type_id::create("query_context_image");
    if (query_image == null)
      return invalid_state("query context image allocation failed");
    foreach (canonical_bytes[i]) query_image.bytes.push_back(canonical_bytes[i]);
    foreach (payload.object_payload[i])
      query_image.bytes[payload_offset + i] = payload.object_payload[i];
    query_image.length = 64;
    query_image.alignment = 64;
    query_image.endian = RDMA_ENDIAN_BIG;
    query_image.image_kind = image_kind;
    query_image.hardware_version = XTR_V1_HW_VERSION;
    query_image.function_generation = resource.owner.generation;
    query_image.write_target_kind = RDMA_HW_TARGET_NONE;
    query_image.backing_target = '0;
    query_image.hmc_target = '0;
    query_image.bar_target = '0;

    registry = rdma_codec_registry::type_id::create("query_context_registry");
    status = rdma_xtr_v1_register_context_body_codecs(registry);
    if (!status.ok()) return status;
    key.hw_version = "xtr_v1";
    key.image_kind = image_kind;
    key.object_type = object_type;
    key.variant = "create";
    key.opcode = expected_create_opcode;
    status = registry.lookup(key, codec);
    if (!status.ok()) return status;
    status = codec.decode(query_image, decoded_model);
    if (!status.ok() || decoded_model == null)
      return rdma_status::success();

    typed_match = 1'b0;
    case (resource.resource_kind())
      RDMA_RESOURCE_CQ: begin
        rdma_cq cq;
        rdma_cqc_model cqc;
        typed_match = $cast(cq, resource) && $cast(cqc, decoded_model) &&
                      cqc.cq_h != null && cqc.cq_h.kind == RDMA_RESOURCE_CQ &&
                      cqc.cq_h.object_id == cq.local_cq_id;
      end
      RDMA_RESOURCE_SRQ: begin
        rdma_srq srq;
        rdma_srqc_model srqc;
        typed_match = $cast(srq, resource) && $cast(srqc, decoded_model) &&
                      srqc.srq_h != null && srqc.srq_h.kind == RDMA_RESOURCE_SRQ &&
                      srqc.srq_h.object_id == srq.local_srq_id;
      end
      RDMA_RESOURCE_CEQ: begin
        rdma_ceq ceq;
        rdma_ceqc_model ceqc;
        typed_match = $cast(ceq, resource) && $cast(ceqc, decoded_model) &&
                      ceqc.ceq_h != null && ceqc.ceq_h.kind == RDMA_RESOURCE_CEQ &&
                      ceqc.ceq_h.object_id == ceq.local_ceq_id;
      end
      RDMA_RESOURCE_AEQ: begin
        rdma_aeq aeq;
        rdma_aeqc_model aeqc;
        typed_match = $cast(aeq, resource) && $cast(aeqc, decoded_model) &&
                      aeqc.aeq_h != null && aeqc.aeq_h.kind == RDMA_RESOURCE_AEQ &&
                      aeqc.aeq_h.object_id == aeq.local_aeq_id;
      end
      default: typed_match = 1'b0;
    endcase
    if (typed_match) begin
      presence = RDMA_HW_PRESENCE_PRESENT;
      conclusive = 1'b1;
    end
    return rdma_status::success();
  endfunction
endclass

class rdma_cq_lifecycle_policy extends rdma_queue_lifecycle_policy;
  `uvm_object_utils(rdma_cq_lifecycle_policy)

  function new(string name = "rdma_cq_lifecycle_policy");
    super.new(name);
  endfunction

  virtual function rdma_resource_kind_e resource_kind();
    return RDMA_RESOURCE_CQ;
  endfunction

  virtual function rdma_status reserve_resource(
    rdma_resource_manager manager, rdma_function_binding binding,
    rdma_semantic_request request, output rdma_queue_resource resource);
    rdma_create_cq_req cq_request;
    rdma_cq cq;

    resource = null;
    if (manager == null || binding == null ||
        !$cast(cq_request, request))
      return invalid_argument("CQ reservation input is invalid");
    begin
      rdma_status status;
      status = manager.create_cq(binding, cq_request.ceq_h, cq);
      if (status != null && status.ok())
        resource = cq;
      return status;
    end
  endfunction

  virtual function rdma_status preflight(
    rdma_function_binding binding, rdma_semantic_request request,
    rdma_resource_manager manager, output rdma_queue_preflight result);
    rdma_create_cq_req cq_request;
    rdma_function_handle owner;
    rdma_queue_preflight candidate;
    rdma_queue_ring_layout ring;
    rdma_status status;

    result = null;
    if (!$cast(cq_request, request))
      return invalid_argument("CQ policy requires rdma_create_cq_req");
    status = common_preflight_status(binding, cq_request, manager, owner);
    if (!status.ok())
      return status;
    if (cq_request.depth < binding.queue_caps.min_cq_depth ||
        cq_request.depth > binding.queue_caps.max_cq_depth)
      return invalid_argument("CQ depth exceeds Function capability");
    status = dependency_status(manager, owner, cq_request.ceq_h,
                               RDMA_RESOURCE_CEQ, 1'b1);
    if (!status.ok())
      return status;
    if (cq_request.ring_backing.mode == RDMA_QUEUE_BACKING_BORROWED) begin
      foreach (cq_request.ring_backing.slices[i]) begin
        if (cq_request.ring_backing.slices[i] == null ||
            cq_request.ring_backing.slices[i].role !=
              RDMA_QUEUE_ROLE_CQ_RING)
          return invalid_argument("CQ borrowed backing has an invalid role");
      end
      if (backing_role_count(cq_request.ring_backing,
                             RDMA_QUEUE_ROLE_CQ_RING) == 0)
        return invalid_argument("CQ borrowed backing omits CQ_RING");
    end
    status = checked_ring_layout("cq_preflight_ring",
      RDMA_QUEUE_ROLE_CQ_RING, cq_request.depth, cq_request.cqe_size_bytes,
      1'b1, binding.queue_caps.max_queue_ring_bytes, ring);
    if (!status.ok())
      return status;
    candidate = rdma_queue_preflight::type_id::create("cq_preflight");
    candidate.resource_kind = RDMA_RESOURCE_CQ;
    candidate.depth = cq_request.depth;
    candidate.cqe_size_bytes = cq_request.cqe_size_bytes;
    status = clone_backing_spec(cq_request.ring_backing,
                                candidate.backing_spec);
    if (!status.ok())
      return status;
    candidate.required_rings.push_back(ring);
    return publish_preflight(candidate, result);
  endfunction

  virtual function rdma_status build_create_context(
    rdma_queue_resource resource, rdma_queue_backing_plan plan,
    output rdma_hw_model context_model,
    output byte unsigned context_slot_image[],
    output byte unsigned context_shadow_image[]);
    rdma_cq cq;
    rdma_queue_ring_layout ring;
    rdma_queue_backing_ref pd_ref;
    rdma_backing_addr_t pd_address;
    rdma_backing_addr_t shadow_base;
    rdma_handle cq_h;
    rdma_cqc_model candidate;
    byte unsigned slot_candidate[];
    byte unsigned shadow_candidate[];
    rdma_status status;

    context_model = null;
    context_slot_image = new[0];
    context_shadow_image = new[0];
    if (!$cast(cq, resource))
      return invalid_argument("CQ context builder requires rdma_cq");
    if (plan == null || plan.resource_kind != RDMA_RESOURCE_CQ)
      return invalid_argument("CQ context builder received the wrong plan");
    status = queue_resource_owner_status(cq, RDMA_RESOURCE_CQ);
    if (!status.ok()) return status;
    status = projected_handle("cqc_cq", cq.handle, RDMA_RESOURCE_CQ,
                              cq.local_cq_id, 21, cq_h);
    if (!status.ok()) return status;
    status = projected_dependency_status(cq.ceq_h, cq.handle,
                                         RDMA_RESOURCE_CEQ, 12, 1'b1);
    if (!status.ok()) return status;
    status = find_ring(plan, RDMA_QUEUE_ROLE_CQ_RING, ring);
    if (!status.ok()) return status;
    status = find_backing_ref(plan, RDMA_QUEUE_ROLE_CQ_PD, pd_ref);
    if (!status.ok()) return status;
    status = backing_owner_status(pd_ref, cq.owner);
    if (!status.ok()) return status;
    status = backing_iova(pd_ref, pd_address);
    if (!status.ok()) return status;
    status = context_ref_status(plan, cq.owner, RDMA_RESOURCE_CQ,
                                cq.local_cq_id,
                                48, 8, shadow_base);
    if (!status.ok()) return status;
    if (ring.depth != cq.depth || ring.entry_size_bytes != cq.cqe_size_bytes)
      return invalid_state("CQ resource and backing plan disagree");

    candidate = rdma_cqc_model::type_id::create("canonical_cqc");
    candidate.cq_h = cq_h;
    candidate.ceq_h = rdma_clone_handle_value(cq.ceq_h,
                                               "CQC projected CEQ");
    candidate.state = RDMA_CONTEXT_VALID;
    candidate.depth = cq.depth;
    candidate.cqe_size_bytes = cq.cqe_size_bytes;
    candidate.threshold = 2;
    set_indirect_layout(candidate.page_layout, pd_address);
    candidate.producer.index = 0;
    candidate.producer.wrap = 1'b0;
    candidate.consumer.index = 0;
    candidate.consumer.wrap = 1'b0;
    candidate.urc_enable = 1'b0;
    candidate.load_ci_done = 1'b1;
    candidate.last_arm_sequence = 1;
    candidate.arm_sequence = 0;
    candidate.arm_state = 0;
    candidate.shadow_backing = shadow_base;
    status = encode_context(candidate, RDMA_IMAGE_CQC, "cqc",
                            XTR_V1_OP_CQC_CREATE, slot_candidate);
    if (!status.ok()) return status;
    shadow_candidate = new[8];
    foreach (shadow_candidate[i]) shadow_candidate[i] = 0;
    context_model = candidate;
    context_slot_image = slot_candidate;
    context_shadow_image = shadow_candidate;
    return rdma_status::success();
  endfunction

  virtual function rdma_status build_create_command(
    rdma_function_handle owner, rdma_queue_resource resource,
    rdma_hw_model context_model, time timeout,
    output rdma_cmq_command_desc command);
    rdma_cq cq;
    rdma_cqc_model cqc;
    rdma_status status;
    command = null;
    if (!$cast(cq, resource) || !$cast(cqc, context_model))
      return invalid_argument("CQ create command requires CQ/CQC types");
    if (cqc.cq_h == null || cqc.cq_h.object_id != cq.local_cq_id)
      return invalid_argument("CQC model does not match CQ local ID");
    status = command_owner_status(owner, cq, cqc.cq_h, RDMA_RESOURCE_CQ);
    if (!status.ok()) return status;
    return build_command_desc(owner, XTR_V1_OP_CQC_CREATE, "create", cqc,
                              timeout, command);
  endfunction

  virtual function rdma_status build_object_command(
    bit [7:0] opcode, rdma_function_handle owner,
    rdma_queue_resource resource, time timeout,
    output rdma_cmq_command_desc command);
    rdma_cq cq;
    rdma_status status;
    command = null;
    if (!$cast(cq, resource))
      return invalid_argument("CQ object command requires rdma_cq");
    status = command_resource_owner_status(owner, cq, RDMA_RESOURCE_CQ);
    if (!status.ok()) return status;
    return build_object_desc(opcode, XTR_V1_OP_CQC_DELETE,
      XTR_V1_OP_CQC_QUERY, owner, cq.handle, RDMA_RESOURCE_CQ,
      cq.local_cq_id, 21, timeout, command);
  endfunction

  virtual function rdma_status build_flush_command(
    rdma_function_handle owner, rdma_queue_flush_target target,
    time timeout, output rdma_cmq_command_desc command);
    command = null;
    if (target == null || target.role != RDMA_QUEUE_ROLE_CQ_PD ||
        target.phase != RDMA_QUEUE_FLUSH_POST_DELETE)
      return invalid_argument("CQ flush target is not CQ_PD/POST_DELETE");
    return build_pd_flush_desc(owner, target, timeout, command);
  endfunction
  virtual function rdma_status classify_query_completion(
    rdma_queue_resource resource,
    rdma_cmq_completion completion,
    output rdma_hw_presence_e presence,
    output bit conclusive
  );
    return classify_query_common(resource, completion, XTR_V1_OP_CQC_QUERY,
      XTR_V1_OP_CQC_CREATE, RDMA_IMAGE_CQC, "cqc", 8, 56,
      XTR_V1_ECODE_EC_RCE_CQC_INVLD, presence, conclusive);
  endfunction
  virtual function void hardware_cleanup_roles(output rdma_queue_backing_role_e flush_roles[$], output rdma_queue_flush_phase_e flush_phases[$], output bit delete_before_flush); flush_roles.delete(); flush_phases.delete(); delete_before_flush=1'b1; flush_roles.push_back(RDMA_QUEUE_ROLE_CQ_PD); flush_phases.push_back(RDMA_QUEUE_FLUSH_POST_DELETE); endfunction
  virtual function void local_cleanup_roles(output rdma_queue_backing_role_e roles[$], output bit release_context_first); roles.delete(); release_context_first=1'b1; roles.push_back(RDMA_QUEUE_ROLE_CQ_PD); roles.push_back(RDMA_QUEUE_ROLE_CQ_RING); endfunction
endclass

class rdma_srq_lifecycle_policy extends rdma_queue_lifecycle_policy;
  `uvm_object_utils(rdma_srq_lifecycle_policy)

  function new(string name = "rdma_srq_lifecycle_policy");
    super.new(name);
  endfunction

  virtual function rdma_resource_kind_e resource_kind();
    return RDMA_RESOURCE_SRQ;
  endfunction

  virtual function rdma_status reserve_resource(
    rdma_resource_manager manager, rdma_function_binding binding,
    rdma_semantic_request request, output rdma_queue_resource resource);
    rdma_create_srq_req srq_request;
    rdma_srq srq;

    resource = null;
    if (manager == null || binding == null ||
        !$cast(srq_request, request))
      return invalid_argument("SRQ reservation input is invalid");
    begin
      rdma_status status;
      status = manager.create_srq(binding, srq_request.pd_h, srq);
      if (status != null && status.ok())
        resource = srq;
      return status;
    end
  endfunction

  virtual function rdma_status preflight(
    rdma_function_binding binding, rdma_semantic_request request,
    rdma_resource_manager manager, output rdma_queue_preflight result);
    rdma_create_srq_req srq_request;
    rdma_function_handle owner;
    rdma_queue_preflight candidate;
    rdma_queue_ring_layout ring;
    rdma_status status;
    bit need_sgb;

    result = null;
    if (!$cast(srq_request, request))
      return invalid_argument("SRQ policy requires rdma_create_srq_req");
    status = common_preflight_status(binding, srq_request, manager, owner);
    if (!status.ok()) return status;
    if (srq_request.depth < binding.queue_caps.min_srq_depth ||
        srq_request.depth > binding.queue_caps.max_srq_depth)
      return invalid_argument("SRQ depth exceeds Function capability");
    if (srq_request.max_sge == 0 ||
        srq_request.max_sge > binding.queue_caps.max_wq_sge)
      return invalid_argument("SRQ maximum SGE exceeds Function capability");
    if (srq_request.limit_threshold / 4 > 14'h3fff)
      return invalid_argument("SRQ encoded limit exceeds 14 bits");
    status = dependency_status(manager, owner, srq_request.pd_h,
                               RDMA_RESOURCE_PD, 1'b0);
    if (!status.ok()) return status;
    need_sgb = srq_request.max_sge > 2;
    if (srq_request.payload_backing.mode == RDMA_QUEUE_BACKING_BORROWED) begin
      foreach (srq_request.payload_backing.slices[i]) begin
        if (srq_request.payload_backing.slices[i] == null ||
            !(srq_request.payload_backing.slices[i].role inside {
              RDMA_QUEUE_ROLE_SRQ_RING, RDMA_QUEUE_ROLE_SRFQ_RING,
              RDMA_QUEUE_ROLE_SRQ_SGB}))
          return invalid_argument("SRQ borrowed backing has an invalid role");
        if (!need_sgb && srq_request.payload_backing.slices[i].role ==
                         RDMA_QUEUE_ROLE_SRQ_SGB)
          return invalid_argument("SRQ borrowed backing has an extra SGB");
      end
      if (backing_role_count(srq_request.payload_backing,
                             RDMA_QUEUE_ROLE_SRQ_RING) == 0 ||
          backing_role_count(srq_request.payload_backing,
                             RDMA_QUEUE_ROLE_SRFQ_RING) == 0 ||
          (need_sgb &&
           backing_role_count(srq_request.payload_backing,
                              RDMA_QUEUE_ROLE_SRQ_SGB) == 0))
        return invalid_argument("SRQ borrowed backing omits a required role");
    end
    candidate = rdma_queue_preflight::type_id::create("srq_preflight");
    candidate.resource_kind = RDMA_RESOURCE_SRQ;
    candidate.depth = srq_request.depth;
    candidate.max_sge = srq_request.max_sge;
    candidate.limit_threshold = srq_request.limit_threshold;
    status = clone_backing_spec(srq_request.payload_backing,
                                candidate.backing_spec);
    if (!status.ok()) return status;
    status = checked_ring_layout("srq_preflight_ring",
      RDMA_QUEUE_ROLE_SRQ_RING, srq_request.depth, 64, 1'b0,
      binding.queue_caps.max_queue_ring_bytes, ring);
    if (!status.ok()) return status;
    candidate.required_rings.push_back(ring);
    status = checked_ring_layout("srfq_preflight_ring",
      RDMA_QUEUE_ROLE_SRFQ_RING, srq_request.depth, 64, 1'b0,
      binding.queue_caps.max_queue_ring_bytes, ring);
    if (!status.ok()) return status;
    candidate.required_rings.push_back(ring);
    if (need_sgb) begin
      status = checked_ring_layout("srq_sgb_preflight",
        RDMA_QUEUE_ROLE_SRQ_SGB, srq_request.depth, 512, 1'b0,
        binding.queue_caps.max_sgb_bytes, ring);
      if (!status.ok()) return status;
      candidate.required_rings.push_back(ring);
    end
    return publish_preflight(candidate, result);
  endfunction

  virtual function rdma_status build_create_context(
    rdma_queue_resource resource, rdma_queue_backing_plan plan,
    output rdma_hw_model context_model,
    output byte unsigned context_slot_image[],
    output byte unsigned context_shadow_image[]);
    rdma_srq srq;
    rdma_queue_ring_layout ring;
    rdma_queue_backing_ref pd_ref;
    rdma_backing_addr_t pd_address;
    rdma_backing_addr_t shadow_base;
    rdma_handle srq_h;
    rdma_srqc_model candidate;
    byte unsigned slot_candidate[];
    byte unsigned shadow_candidate[];
    int unsigned encoded_limit;
    rdma_status status;

    context_model = null;
    context_slot_image = new[0];
    context_shadow_image = new[0];
    if (!$cast(srq, resource))
      return invalid_argument("SRQ context builder requires rdma_srq");
    if (plan == null || plan.resource_kind != RDMA_RESOURCE_SRQ)
      return invalid_argument("SRQ context builder received the wrong plan");
    status = queue_resource_owner_status(srq, RDMA_RESOURCE_SRQ);
    if (!status.ok()) return status;
    if (srq.limit_threshold < 16 || srq.limit_threshold > srq.depth ||
        srq.limit_threshold % 4 != 0)
      return invalid_argument("SRQ limit threshold is invalid");
    encoded_limit = srq.limit_threshold / 4;
    if (encoded_limit > 14'h3fff)
      return invalid_argument("SRQ encoded limit exceeds 14 bits");
    status = projected_handle("srqc_srq", srq.handle, RDMA_RESOURCE_SRQ,
                              srq.local_srq_id, 16, srq_h);
    if (!status.ok()) return status;
    status = projected_dependency_status(srq.pd_h, srq.handle,
                                         RDMA_RESOURCE_PD, 16, 1'b0);
    if (!status.ok()) return status;
    status = find_ring(plan, RDMA_QUEUE_ROLE_SRFQ_RING, ring);
    if (!status.ok()) return status;
    status = find_backing_ref(plan, RDMA_QUEUE_ROLE_SRFQ_PD, pd_ref);
    if (!status.ok()) return status;
    status = backing_owner_status(pd_ref, srq.owner);
    if (!status.ok()) return status;
    status = backing_iova(pd_ref, pd_address);
    if (!status.ok()) return status;
    status = context_ref_status(plan, srq.owner, RDMA_RESOURCE_SRQ,
                                srq.local_srq_id,
                                28, 4, shadow_base);
    if (!status.ok()) return status;
    if (ring.depth != srq.depth || ring.entry_size_bytes != 64)
      return invalid_state("SRQ resource and backing plan disagree");

    candidate = rdma_srqc_model::type_id::create("canonical_srqc");
    candidate.srq_h = srq_h;
    candidate.pd_h = rdma_clone_handle_value(srq.pd_h,
                                              "SRQC projected PD");
    candidate.state = RDMA_CONTEXT_VALID;
    candidate.depth = srq.depth;
    candidate.load_pi_threshold = 8;
    candidate.limit_threshold = encoded_limit;
    candidate.object_mode = RDMA_OBJECT_INDIRECT_4K;
    candidate.srfq_backing = pd_address;
    candidate.shadow_backing = shadow_base;
    candidate.producer.index = 0;
    candidate.producer.wrap = 1'b0;
    candidate.arm_sequence = 0;
    status = encode_context(candidate, RDMA_IMAGE_SRQC, "srqc",
                            XTR_V1_OP_SRFQC_CREATE, slot_candidate);
    if (!status.ok()) return status;
    shadow_candidate = new[4];
    shadow_candidate[0] = 8'h00;
    shadow_candidate[1] = 8'h00;
    shadow_candidate[2] = byte'((encoded_limit << 2) >> 8);
    shadow_candidate[3] = byte'(encoded_limit << 2);
    context_model = candidate;
    context_slot_image = slot_candidate;
    context_shadow_image = shadow_candidate;
    return rdma_status::success();
  endfunction

  virtual function rdma_status build_create_command(
    rdma_function_handle owner, rdma_queue_resource resource,
    rdma_hw_model context_model, time timeout,
    output rdma_cmq_command_desc command);
    rdma_srq srq;
    rdma_srqc_model srqc;
    rdma_status status;
    command = null;
    if (!$cast(srq, resource) || !$cast(srqc, context_model))
      return invalid_argument("SRQ create command requires SRQ/SRQC types");
    if (srqc.srq_h == null || srqc.srq_h.object_id != srq.local_srq_id)
      return invalid_argument("SRQC model does not match SRQ local ID");
    status = command_owner_status(owner, srq, srqc.srq_h,
                                  RDMA_RESOURCE_SRQ);
    if (!status.ok()) return status;
    return build_command_desc(owner, XTR_V1_OP_SRFQC_CREATE, "create", srqc,
                              timeout, command);
  endfunction

  virtual function rdma_status build_object_command(
    bit [7:0] opcode, rdma_function_handle owner,
    rdma_queue_resource resource, time timeout,
    output rdma_cmq_command_desc command);
    rdma_srq srq;
    rdma_status status;
    command = null;
    if (!$cast(srq, resource))
      return invalid_argument("SRQ object command requires rdma_srq");
    status = command_resource_owner_status(owner, srq, RDMA_RESOURCE_SRQ);
    if (!status.ok()) return status;
    return build_object_desc(opcode, XTR_V1_OP_SRFQC_DELETE,
      XTR_V1_OP_SRFQC_QUERY, owner, srq.handle, RDMA_RESOURCE_SRQ,
      srq.local_srq_id, 16, timeout, command);
  endfunction

  virtual function rdma_status build_flush_command(
    rdma_function_handle owner, rdma_queue_flush_target target,
    time timeout, output rdma_cmq_command_desc command);
    command = null;
    if (target == null ||
        !(target.role inside {RDMA_QUEUE_ROLE_SRFQ_PD,
                              RDMA_QUEUE_ROLE_SRQ_PD}) ||
        target.phase != RDMA_QUEUE_FLUSH_PRE_DELETE)
      return invalid_argument("SRQ flush target is not a pre-delete PD");
    return build_pd_flush_desc(owner, target, timeout, command);
  endfunction
  virtual function rdma_status classify_query_completion(
    rdma_queue_resource resource,
    rdma_cmq_completion completion,
    output rdma_hw_presence_e presence,
    output bit conclusive
  );
    return classify_query_common(resource, completion, XTR_V1_OP_SRFQC_QUERY,
      XTR_V1_OP_SRFQC_CREATE, RDMA_IMAGE_SRQC, "srqc", 16, 32,
      8'hff, presence, conclusive);
  endfunction
  virtual function void hardware_cleanup_roles(output rdma_queue_backing_role_e flush_roles[$], output rdma_queue_flush_phase_e flush_phases[$], output bit delete_before_flush); flush_roles.delete(); flush_phases.delete(); delete_before_flush=1'b0; flush_roles.push_back(RDMA_QUEUE_ROLE_SRFQ_PD); flush_phases.push_back(RDMA_QUEUE_FLUSH_PRE_DELETE); flush_roles.push_back(RDMA_QUEUE_ROLE_SRQ_PD); flush_phases.push_back(RDMA_QUEUE_FLUSH_PRE_DELETE); endfunction
  virtual function void local_cleanup_roles(output rdma_queue_backing_role_e roles[$], output bit release_context_first); roles.delete(); release_context_first=1'b1; roles.push_back(RDMA_QUEUE_ROLE_SRFQ_PD); roles.push_back(RDMA_QUEUE_ROLE_SRQ_PD); roles.push_back(RDMA_QUEUE_ROLE_SRQ_SGB); roles.push_back(RDMA_QUEUE_ROLE_SRFQ_RING); roles.push_back(RDMA_QUEUE_ROLE_SRQ_RING); endfunction
endclass

class rdma_ceq_lifecycle_policy extends rdma_queue_lifecycle_policy;
  `uvm_object_utils(rdma_ceq_lifecycle_policy)

  function new(string name = "rdma_ceq_lifecycle_policy");
    super.new(name);
  endfunction

  virtual function rdma_resource_kind_e resource_kind();
    return RDMA_RESOURCE_CEQ;
  endfunction

  virtual function rdma_status reserve_resource(
    rdma_resource_manager manager, rdma_function_binding binding,
    rdma_semantic_request request, output rdma_queue_resource resource);
    rdma_create_ceq_req ceq_request;
    rdma_ceq ceq;

    resource = null;
    if (manager == null || binding == null ||
        !$cast(ceq_request, request))
      return invalid_argument("CEQ reservation input is invalid");
    begin
      rdma_status status;
      status = manager.create_ceq(binding, ceq);
      if (status != null && status.ok())
        resource = ceq;
      return status;
    end
  endfunction

  virtual function rdma_status preflight(
    rdma_function_binding binding, rdma_semantic_request request,
    rdma_resource_manager manager, output rdma_queue_preflight result);
    rdma_create_ceq_req ceq_request;
    rdma_function_handle owner;
    rdma_queue_preflight candidate;
    rdma_queue_ring_layout ring;
    rdma_status status;
    bit found_vector;
    rdma_interrupt_vector_binding vector;

    result = null;
    if (!$cast(ceq_request, request))
      return invalid_argument("CEQ policy requires rdma_create_ceq_req");
    status = common_preflight_status(binding, ceq_request, manager, owner);
    if (!status.ok()) return status;
    if (ceq_request.depth > binding.queue_caps.max_ceq_depth)
      return invalid_argument("CEQ depth exceeds Function capability");
    found_vector = 1'b0;
    foreach (binding.interrupt_vectors[i]) begin
      if (binding.interrupt_vectors[i].function_local_vector ==
          ceq_request.vector_id) begin
        found_vector = 1'b1;
        vector = binding.interrupt_vectors[i];
      end
    end
    if (!found_vector)
      return invalid_argument("CEQ Function-local vector is not mapped");
    if (!vector.enabled)
      return invalid_state("CEQ interrupt vector is disabled");
    if (vector.hardware_eq_vector > 16'hffff)
      return invalid_argument("CEQ hardware vector exceeds 16 bits");
    if (ceq_request.ring_backing.mode == RDMA_QUEUE_BACKING_BORROWED) begin
      foreach (ceq_request.ring_backing.slices[i]) begin
        if (ceq_request.ring_backing.slices[i] == null ||
            ceq_request.ring_backing.slices[i].role !=
              RDMA_QUEUE_ROLE_CEQ_RING)
          return invalid_argument("CEQ borrowed backing has an invalid role");
      end
      if (backing_role_count(ceq_request.ring_backing,
                             RDMA_QUEUE_ROLE_CEQ_RING) == 0)
        return invalid_argument("CEQ borrowed backing omits CEQ_RING");
    end
    status = checked_ring_layout("ceq_preflight_ring",
      RDMA_QUEUE_ROLE_CEQ_RING, ceq_request.depth, 16, 1'b1,
      binding.queue_caps.max_queue_ring_bytes, ring);
    if (!status.ok()) return status;
    candidate = rdma_queue_preflight::type_id::create("ceq_preflight");
    candidate.resource_kind = RDMA_RESOURCE_CEQ;
    candidate.depth = ceq_request.depth;
    candidate.local_vector = ceq_request.vector_id;
    candidate.hardware_vector = vector.hardware_eq_vector;
    candidate.msix_table_index = vector.msix_table_index;
    status = clone_backing_spec(ceq_request.ring_backing,
                                candidate.backing_spec);
    if (!status.ok()) return status;
    candidate.required_rings.push_back(ring);
    return publish_preflight(candidate, result);
  endfunction

  virtual function rdma_status build_create_context(
    rdma_queue_resource resource, rdma_queue_backing_plan plan,
    output rdma_hw_model context_model,
    output byte unsigned context_slot_image[],
    output byte unsigned context_shadow_image[]);
    rdma_ceq ceq;
    rdma_queue_ring_layout ring;
    rdma_queue_backing_ref pd_ref;
    rdma_backing_addr_t pd_address;
    rdma_handle ceq_h;
    rdma_ceqc_model candidate;
    byte unsigned slot_candidate[];
    rdma_status status;

    context_model = null;
    context_slot_image = new[0];
    context_shadow_image = new[0];
    if (!$cast(ceq, resource))
      return invalid_argument("CEQ context builder requires rdma_ceq");
    if (plan == null || plan.resource_kind != RDMA_RESOURCE_CEQ)
      return invalid_argument("CEQ context builder received the wrong plan");
    status = queue_resource_owner_status(ceq, RDMA_RESOURCE_CEQ);
    if (!status.ok()) return status;
    if (ceq.hardware_vector > 16'hffff)
      return invalid_argument("CEQ hardware vector exceeds 16 bits");
    status = projected_handle("ceqc_ceq", ceq.handle, RDMA_RESOURCE_CEQ,
                              ceq.local_ceq_id, 12, ceq_h);
    if (!status.ok()) return status;
    status = find_ring(plan, RDMA_QUEUE_ROLE_CEQ_RING, ring);
    if (!status.ok()) return status;
    status = find_backing_ref(plan, RDMA_QUEUE_ROLE_CEQ_PD, pd_ref);
    if (!status.ok()) return status;
    status = backing_owner_status(pd_ref, ceq.owner);
    if (!status.ok()) return status;
    status = backing_iova(pd_ref, pd_address);
    if (!status.ok()) return status;
    if (ring.depth != ceq.depth || ring.entry_size_bytes != 16)
      return invalid_state("CEQ resource and backing plan disagree");
    candidate = rdma_ceqc_model::type_id::create("canonical_ceqc");
    candidate.ceq_h = ceq_h;
    candidate.state = RDMA_CONTEXT_VALID;
    candidate.depth = ceq.depth;
    candidate.vector_id = ceq.hardware_vector;
    set_indirect_layout(candidate.page_layout, pd_address);
    candidate.producer.index = 0;
    candidate.producer.wrap = 1'b0;
    candidate.consumer.index = 0;
    candidate.consumer.wrap = 1'b0;
    status = encode_context(candidate, RDMA_IMAGE_CEQC, "ceqc",
                            XTR_V1_OP_CEQC_CREATE, slot_candidate);
    if (!status.ok()) return status;
    context_model = candidate;
    context_slot_image = slot_candidate;
    return rdma_status::success();
  endfunction

  virtual function rdma_status build_create_command(
    rdma_function_handle owner, rdma_queue_resource resource,
    rdma_hw_model context_model, time timeout,
    output rdma_cmq_command_desc command);
    rdma_ceq ceq;
    rdma_ceqc_model ceqc;
    rdma_status status;
    command = null;
    if (!$cast(ceq, resource) || !$cast(ceqc, context_model))
      return invalid_argument("CEQ create command requires CEQ/CEQC types");
    if (ceqc.ceq_h == null || ceqc.ceq_h.object_id != ceq.local_ceq_id)
      return invalid_argument("CEQC model does not match CEQ local ID");
    status = command_owner_status(owner, ceq, ceqc.ceq_h,
                                  RDMA_RESOURCE_CEQ);
    if (!status.ok()) return status;
    return build_command_desc(owner, XTR_V1_OP_CEQC_CREATE, "create", ceqc,
                              timeout, command);
  endfunction

  virtual function rdma_status build_object_command(
    bit [7:0] opcode, rdma_function_handle owner,
    rdma_queue_resource resource, time timeout,
    output rdma_cmq_command_desc command);
    rdma_ceq ceq;
    rdma_status status;
    command = null;
    if (!$cast(ceq, resource))
      return invalid_argument("CEQ object command requires rdma_ceq");
    status = command_resource_owner_status(owner, ceq, RDMA_RESOURCE_CEQ);
    if (!status.ok()) return status;
    return build_object_desc(opcode, XTR_V1_OP_CEQC_DELETE,
      XTR_V1_OP_CEQC_QUERY, owner, ceq.handle, RDMA_RESOURCE_CEQ,
      ceq.local_ceq_id, 12, timeout, command);
  endfunction

  virtual function rdma_status build_flush_command(
    rdma_function_handle owner, rdma_queue_flush_target target,
    time timeout, output rdma_cmq_command_desc command);
    command = null;
    return unsupported("CEQ lifecycle has no OCC flush command");
  endfunction
  virtual function rdma_status classify_query_completion(
    rdma_queue_resource resource,
    rdma_cmq_completion completion,
    output rdma_hw_presence_e presence,
    output bit conclusive
  );
    return classify_query_common(resource, completion, XTR_V1_OP_CEQC_QUERY,
      XTR_V1_OP_CEQC_CREATE, RDMA_IMAGE_CEQC, "ceqc", 16, 32,
      XTR_V1_ECODE_EC_RCE_CEQC_INVLD, presence, conclusive);
  endfunction
  virtual function void hardware_cleanup_roles(output rdma_queue_backing_role_e flush_roles[$], output rdma_queue_flush_phase_e flush_phases[$], output bit delete_before_flush); flush_roles.delete(); flush_phases.delete(); delete_before_flush=1'b1; endfunction
  virtual function void local_cleanup_roles(output rdma_queue_backing_role_e roles[$], output bit release_context_first); roles.delete(); release_context_first=1'b0; roles.push_back(RDMA_QUEUE_ROLE_CEQ_PD); roles.push_back(RDMA_QUEUE_ROLE_CEQ_RING); endfunction
endclass

class rdma_aeq_lifecycle_policy extends rdma_queue_lifecycle_policy;
  `uvm_object_utils(rdma_aeq_lifecycle_policy)

  function new(string name = "rdma_aeq_lifecycle_policy");
    super.new(name);
  endfunction

  virtual function rdma_resource_kind_e resource_kind();
    return RDMA_RESOURCE_AEQ;
  endfunction

  virtual function rdma_status reserve_resource(
    rdma_resource_manager manager, rdma_function_binding binding,
    rdma_semantic_request request, output rdma_queue_resource resource);
    rdma_create_aeq_req aeq_request;
    rdma_aeq aeq;

    resource = null;
    if (manager == null || binding == null ||
        !$cast(aeq_request, request))
      return invalid_argument("AEQ reservation input is invalid");
    begin
      rdma_status status;
      status = manager.create_aeq(binding, aeq);
      if (status != null && status.ok())
        resource = aeq;
      return status;
    end
  endfunction

  virtual function rdma_status preflight(
    rdma_function_binding binding, rdma_semantic_request request,
    rdma_resource_manager manager, output rdma_queue_preflight result);
    rdma_create_aeq_req aeq_request;
    rdma_function_handle owner;
    rdma_queue_preflight candidate;
    rdma_queue_ring_layout ring;
    rdma_status status;
    bit found_vector;
    rdma_interrupt_vector_binding vector;

    result = null;
    if (!$cast(aeq_request, request))
      return invalid_argument("AEQ policy requires rdma_create_aeq_req");
    status = common_preflight_status(binding, aeq_request, manager, owner);
    if (!status.ok()) return status;
    if (aeq_request.depth > binding.queue_caps.max_aeq_depth)
      return invalid_argument("AEQ depth exceeds Function capability");
    found_vector = 1'b0;
    foreach (binding.interrupt_vectors[i]) begin
      if (binding.interrupt_vectors[i].function_local_vector ==
          aeq_request.vector_id) begin
        found_vector = 1'b1;
        vector = binding.interrupt_vectors[i];
      end
    end
    if (!found_vector)
      return invalid_argument("AEQ Function-local vector is not mapped");
    if (!vector.enabled)
      return invalid_state("AEQ interrupt vector is disabled");
    if (vector.hardware_eq_vector > 16'hffff)
      return invalid_argument("AEQ hardware vector exceeds 16 bits");
    if (aeq_request.ring_backing.mode == RDMA_QUEUE_BACKING_BORROWED) begin
      foreach (aeq_request.ring_backing.slices[i]) begin
        if (aeq_request.ring_backing.slices[i] == null ||
            aeq_request.ring_backing.slices[i].role !=
              RDMA_QUEUE_ROLE_AEQ_RING)
          return invalid_argument("AEQ borrowed backing has an invalid role");
      end
      if (backing_role_count(aeq_request.ring_backing,
                             RDMA_QUEUE_ROLE_AEQ_RING) == 0)
        return invalid_argument("AEQ borrowed backing omits AEQ_RING");
    end
    status = checked_ring_layout("aeq_preflight_ring",
      RDMA_QUEUE_ROLE_AEQ_RING, aeq_request.depth, 16, 1'b1,
      binding.queue_caps.max_queue_ring_bytes, ring);
    if (!status.ok()) return status;
    candidate = rdma_queue_preflight::type_id::create("aeq_preflight");
    candidate.resource_kind = RDMA_RESOURCE_AEQ;
    candidate.depth = aeq_request.depth;
    candidate.local_vector = aeq_request.vector_id;
    candidate.hardware_vector = vector.hardware_eq_vector;
    candidate.msix_table_index = vector.msix_table_index;
    status = clone_backing_spec(aeq_request.ring_backing,
                                candidate.backing_spec);
    if (!status.ok()) return status;
    candidate.required_rings.push_back(ring);
    return publish_preflight(candidate, result);
  endfunction

  virtual function rdma_status build_create_context(
    rdma_queue_resource resource, rdma_queue_backing_plan plan,
    output rdma_hw_model context_model,
    output byte unsigned context_slot_image[],
    output byte unsigned context_shadow_image[]);
    rdma_aeq aeq;
    rdma_queue_ring_layout ring;
    rdma_queue_backing_ref pd_ref;
    rdma_backing_addr_t pd_address;
    rdma_handle aeq_h;
    rdma_aeqc_model candidate;
    byte unsigned slot_candidate[];
    rdma_status status;

    context_model = null;
    context_slot_image = new[0];
    context_shadow_image = new[0];
    if (!$cast(aeq, resource))
      return invalid_argument("AEQ context builder requires rdma_aeq");
    if (plan == null || plan.resource_kind != RDMA_RESOURCE_AEQ)
      return invalid_argument("AEQ context builder received the wrong plan");
    status = queue_resource_owner_status(aeq, RDMA_RESOURCE_AEQ);
    if (!status.ok()) return status;
    if (aeq.hardware_vector > 16'hffff)
      return invalid_argument("AEQ hardware vector exceeds 16 bits");
    status = projected_handle("aeqc_aeq", aeq.handle, RDMA_RESOURCE_AEQ,
                              aeq.local_aeq_id, 12, aeq_h);
    if (!status.ok()) return status;
    status = find_ring(plan, RDMA_QUEUE_ROLE_AEQ_RING, ring);
    if (!status.ok()) return status;
    status = find_backing_ref(plan, RDMA_QUEUE_ROLE_AEQ_PD, pd_ref);
    if (!status.ok()) return status;
    status = backing_owner_status(pd_ref, aeq.owner);
    if (!status.ok()) return status;
    status = backing_iova(pd_ref, pd_address);
    if (!status.ok()) return status;
    if (ring.depth != aeq.depth || ring.entry_size_bytes != 16)
      return invalid_state("AEQ resource and backing plan disagree");
    candidate = rdma_aeqc_model::type_id::create("canonical_aeqc");
    candidate.aeq_h = aeq_h;
    candidate.state = RDMA_CONTEXT_VALID;
    candidate.depth = aeq.depth;
    candidate.vector_id = aeq.hardware_vector;
    set_indirect_layout(candidate.page_layout, pd_address);
    candidate.producer.index = 0;
    candidate.producer.wrap = 1'b0;
    candidate.consumer.index = 0;
    candidate.consumer.wrap = 1'b0;
    status = encode_context(candidate, RDMA_IMAGE_AEQC, "aeqc",
                            XTR_V1_OP_AEQC_CREATE, slot_candidate);
    if (!status.ok()) return status;
    context_model = candidate;
    context_slot_image = slot_candidate;
    return rdma_status::success();
  endfunction

  virtual function rdma_status build_create_command(
    rdma_function_handle owner, rdma_queue_resource resource,
    rdma_hw_model context_model, time timeout,
    output rdma_cmq_command_desc command);
    rdma_aeq aeq;
    rdma_aeqc_model aeqc;
    rdma_status status;
    command = null;
    if (!$cast(aeq, resource) || !$cast(aeqc, context_model))
      return invalid_argument("AEQ create command requires AEQ/AEQC types");
    if (aeqc.aeq_h == null || aeqc.aeq_h.object_id != aeq.local_aeq_id)
      return invalid_argument("AEQC model does not match AEQ local ID");
    status = command_owner_status(owner, aeq, aeqc.aeq_h,
                                  RDMA_RESOURCE_AEQ);
    if (!status.ok()) return status;
    return build_command_desc(owner, XTR_V1_OP_AEQC_CREATE, "create", aeqc,
                              timeout, command);
  endfunction

  virtual function rdma_status build_object_command(
    bit [7:0] opcode, rdma_function_handle owner,
    rdma_queue_resource resource, time timeout,
    output rdma_cmq_command_desc command);
    rdma_aeq aeq;
    rdma_status status;
    command = null;
    if (!$cast(aeq, resource))
      return invalid_argument("AEQ object command requires rdma_aeq");
    status = command_resource_owner_status(owner, aeq, RDMA_RESOURCE_AEQ);
    if (!status.ok()) return status;
    return build_object_desc(opcode, XTR_V1_OP_AEQC_DELETE,
      XTR_V1_OP_AEQC_QUERY, owner, aeq.handle, RDMA_RESOURCE_AEQ,
      aeq.local_aeq_id, 12, timeout, command);
  endfunction

  virtual function rdma_status build_flush_command(
    rdma_function_handle owner, rdma_queue_flush_target target,
    time timeout, output rdma_cmq_command_desc command);
    command = null;
    return unsupported("AEQ lifecycle has no OCC flush command");
  endfunction
  virtual function rdma_status classify_query_completion(
    rdma_queue_resource resource,
    rdma_cmq_completion completion,
    output rdma_hw_presence_e presence,
    output bit conclusive
  );
    return classify_query_common(resource, completion, XTR_V1_OP_AEQC_QUERY,
      XTR_V1_OP_AEQC_CREATE, RDMA_IMAGE_AEQC, "aeqc", 16, 32,
      XTR_V1_ECODE_EC_RCE_AEQC_INVLD, presence, conclusive);
  endfunction
  virtual function void hardware_cleanup_roles(output rdma_queue_backing_role_e flush_roles[$], output rdma_queue_flush_phase_e flush_phases[$], output bit delete_before_flush); flush_roles.delete(); flush_phases.delete(); delete_before_flush=1'b1; endfunction
  virtual function void local_cleanup_roles(output rdma_queue_backing_role_e roles[$], output bit release_context_first); roles.delete(); release_context_first=1'b0; roles.push_back(RDMA_QUEUE_ROLE_AEQ_PD); roles.push_back(RDMA_QUEUE_ROLE_AEQ_RING); endfunction
endclass
