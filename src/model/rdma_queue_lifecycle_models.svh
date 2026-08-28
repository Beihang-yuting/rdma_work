typedef enum bit { RDMA_QUEUE_BACKING_OWNED, RDMA_QUEUE_BACKING_BORROWED }
  rdma_queue_backing_mode_e;

typedef enum bit [3:0] {
  RDMA_QUEUE_ROLE_CQ_RING = 4'd0,
  RDMA_QUEUE_ROLE_SRQ_RING = 4'd1,
  RDMA_QUEUE_ROLE_SRFQ_RING = 4'd2,
  RDMA_QUEUE_ROLE_SRQ_SGB = 4'd3,
  RDMA_QUEUE_ROLE_CEQ_RING = 4'd4,
  RDMA_QUEUE_ROLE_AEQ_RING = 4'd5,
  RDMA_QUEUE_ROLE_CQ_PD = 4'd6,
  RDMA_QUEUE_ROLE_SRQ_PD = 4'd7,
  RDMA_QUEUE_ROLE_SRFQ_PD = 4'd8,
  RDMA_QUEUE_ROLE_CEQ_PD = 4'd9,
  RDMA_QUEUE_ROLE_AEQ_PD = 4'd10,
  RDMA_QUEUE_ROLE_CQC_CONTEXT_SHADOW = 4'd11,
  RDMA_QUEUE_ROLE_SRFQC_CONTEXT_SHADOW = 4'd12
} rdma_queue_backing_role_e;

typedef enum bit { RDMA_QUEUE_FLUSH_PRE_DELETE, RDMA_QUEUE_FLUSH_POST_DELETE }
  rdma_queue_flush_phase_e;

typedef enum bit { RDMA_QUEUE_RECOVER_CREATE_ROLLBACK,
                   RDMA_QUEUE_RECOVER_NORMAL_DESTROY }
  rdma_queue_recovery_intent_e;

typedef enum bit [1:0] { RDMA_QUEUE_AMBIG_NONE,
                         RDMA_QUEUE_AMBIG_CREATE,
                         RDMA_QUEUE_AMBIG_DELETE,
                         RDMA_QUEUE_AMBIG_OCC_FLUSH }
  rdma_queue_ambiguous_operation_e;

function automatic bit rdma_queue_role_is_payload(rdma_queue_backing_role_e role);
  return role inside {RDMA_QUEUE_ROLE_CQ_RING, RDMA_QUEUE_ROLE_SRQ_RING,
                      RDMA_QUEUE_ROLE_SRFQ_RING, RDMA_QUEUE_ROLE_SRQ_SGB,
                      RDMA_QUEUE_ROLE_CEQ_RING, RDMA_QUEUE_ROLE_AEQ_RING};
endfunction
function automatic bit rdma_queue_role_is_ring(rdma_queue_backing_role_e role);
  return role inside {RDMA_QUEUE_ROLE_CQ_RING, RDMA_QUEUE_ROLE_SRQ_RING,
                      RDMA_QUEUE_ROLE_SRFQ_RING, RDMA_QUEUE_ROLE_CEQ_RING,
                      RDMA_QUEUE_ROLE_AEQ_RING};
endfunction
function automatic bit rdma_queue_role_is_pd(rdma_queue_backing_role_e role);
  return role inside {RDMA_QUEUE_ROLE_CQ_PD, RDMA_QUEUE_ROLE_SRQ_PD,
                      RDMA_QUEUE_ROLE_SRFQ_PD, RDMA_QUEUE_ROLE_CEQ_PD,
                      RDMA_QUEUE_ROLE_AEQ_PD};
endfunction
function automatic bit rdma_queue_add_ok(longint unsigned offset,
                                          longint unsigned length);
  return length != 0 && offset <= (64'hffff_ffff_ffff_ffff - length);
endfunction
function automatic bit rdma_queue_aligned(longint unsigned value,
                                           longint unsigned alignment);
  return (value % alignment) == 0;
endfunction
function automatic rdma_status rdma_queue_queue_range_status(
    rdma_dma_mapping mapping, longint unsigned offset, longint unsigned length,
    longint unsigned alignment);
  if (mapping == null)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "mapping is null");
  if (mapping.state != RDMA_MAPPING_ACTIVE)
    return rdma_status::make(RDMA_SC_INVALID_STATE, "mapping is not active");
  if (length > 64'hffff_ffff_ffff_ffff ||
      !rdma_queue_add_ok(offset, length) || offset > mapping.size ||
      length > mapping.size - offset)
    return rdma_status::make(RDMA_SC_DMA_TRANSLATION, "mapping range overflows");
  if (!rdma_queue_aligned(offset, alignment) || !rdma_queue_aligned(length, alignment))
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "queue range is unaligned");
  if (mapping.iova.value > 64'hffff_ffff_ffff_ffff - offset)
    return rdma_status::make(RDMA_SC_DMA_TRANSLATION, "IOVA offset overflows");
  return rdma_status::success();
endfunction

function automatic rdma_status rdma_queue_base_from_iova(
    rdma_iova_t iova, inout rdma_backing_addr_t base);
  if (!rdma_queue_aligned(iova.value, 4096))
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "queue IOVA is not 4 KiB aligned");
  base.value = iova.value;
  return rdma_status::success();
endfunction

class rdma_queue_completion_authority extends uvm_object;
  `uvm_object_utils(rdma_queue_completion_authority)
  bit complete;

  function new(string name = "rdma_queue_completion_authority");
    super.new(name);
    complete = 1'b0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_queue_completion_authority r;
    super.do_copy(rhs);
    if (!$cast(r, rhs)) `uvm_fatal("RDMA_COPY_TYPE", "completion authority copy mismatch");
    complete = r.complete;
  endfunction
  virtual function rdma_status validate();
    if (!(complete inside {1'b0, 1'b1}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "completion authority invalid");
    return rdma_status::success();
  endfunction
endclass

class rdma_queue_opaque_slot_token extends uvm_object;
  `uvm_object_utils(rdma_queue_opaque_slot_token)
  rdma_queue_completion_authority completion_authority;

  function new(string name = "rdma_queue_opaque_slot_token");
    super.new(name);
    completion_authority = null;
  endfunction
  virtual function void do_copy(uvm_object rhs);
    rdma_queue_opaque_slot_token r;
    super.do_copy(rhs);
    if (!$cast(r, rhs)) `uvm_fatal("RDMA_COPY_TYPE", "slot token copy mismatch");
    completion_authority = r.completion_authority;
  endfunction
  virtual function rdma_status validate();
    if (completion_authority == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "slot token authority missing");
    return completion_authority.validate();
  endfunction
endclass

class rdma_queue_backing_slice extends uvm_object;
  `uvm_object_utils(rdma_queue_backing_slice)
  rdma_queue_backing_role_e role;
  rdma_dma_mapping mapping;
  longint unsigned mapping_offset, length, logical_queue_offset;

  function new(string name = "rdma_queue_backing_slice");
    super.new(name);
    role = RDMA_QUEUE_ROLE_CQ_RING;
    mapping = null;
    mapping_offset = 0;
    length = 0;
    logical_queue_offset = 0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_queue_backing_slice r;
    uvm_object c;
    rdma_dma_mapping m;

    super.do_copy(rhs);
    if (!$cast(r, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "slice copy mismatch");
    role = r.role;
    mapping_offset = r.mapping_offset;
    length = r.length;
    logical_queue_offset = r.logical_queue_offset;
    if (r.mapping == null) begin
      mapping = null;
    end else begin
      c = r.mapping.clone();
      if (c == null || !$cast(m, c) || m == r.mapping)
        `uvm_fatal("RDMA_COPY_TYPE", "slice mapping clone failure");
      mapping = m;
    end
  endfunction

  virtual function rdma_status validate();
    if (!rdma_queue_role_is_payload(role))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "slice role is not payload");
    if (!rdma_queue_aligned(logical_queue_offset,
                            role == RDMA_QUEUE_ROLE_SRQ_SGB ? 512 : 4096))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "logical offset is unaligned");
    if (!rdma_queue_add_ok(logical_queue_offset, length))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "logical range overflows");
    return rdma_queue_queue_range_status(mapping, mapping_offset, length,
      role == RDMA_QUEUE_ROLE_SRQ_SGB ? 512 : 4096);
  endfunction
endclass

class rdma_queue_backing_spec extends uvm_object;
  `uvm_object_utils(rdma_queue_backing_spec)
  rdma_queue_backing_mode_e mode;
  rdma_queue_backing_slice slices[$];

  function new(string name = "rdma_queue_backing_spec");
    super.new(name);
    mode = RDMA_QUEUE_BACKING_OWNED;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_queue_backing_spec r;
    uvm_object c;
    rdma_queue_backing_slice s;

    super.do_copy(rhs);
    if (!$cast(r, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "spec copy mismatch");
    mode = r.mode;
    slices.delete();
    foreach (r.slices[i]) begin
      c = r.slices[i].clone();
      if (c == null || !$cast(s, c) || s == r.slices[i])
        `uvm_fatal("RDMA_COPY_TYPE", "slice clone failure");
      slices.push_back(s);
    end
  endfunction

  virtual function rdma_status validate();
    rdma_status s;

    if (!(mode inside {RDMA_QUEUE_BACKING_OWNED,
                       RDMA_QUEUE_BACKING_BORROWED}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "backing mode invalid");
    if (mode == RDMA_QUEUE_BACKING_OWNED) begin
      if (slices.size() != 0)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "owned spec contains slices");
      return rdma_status::success();
    end
    if (slices.size() == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "borrowed spec has no slices");
    foreach (slices[i]) begin
      if (slices[i] == null || !rdma_queue_role_is_payload(slices[i].role))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "invalid borrowed payload role");
      s = slices[i].validate();
      if (!s.ok())
        return s;
    end
    return rdma_status::success();
  endfunction
endclass

class rdma_queue_dma_page_ref extends uvm_object;
  `uvm_object_utils(rdma_queue_dma_page_ref)
  rdma_queue_backing_role_e role;
  rdma_dma_mapping mapping;
  longint unsigned mapping_offset;
  longint unsigned logical_page_offset;
  rdma_iova_t page_iova;

  function new(string name = "rdma_queue_dma_page_ref");
    super.new(name);
    role = RDMA_QUEUE_ROLE_CQ_RING;
    mapping = null;
    mapping_offset = 0;
    logical_page_offset = 0;
    page_iova = '0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_queue_dma_page_ref r;
    uvm_object c;
    rdma_dma_mapping m;

    super.do_copy(rhs);
    if (!$cast(r, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "page copy mismatch");
    role = r.role;
    mapping_offset = r.mapping_offset;
    logical_page_offset = r.logical_page_offset;
    page_iova = r.page_iova;
    if (r.mapping == null) begin
      mapping = null;
    end else begin
      c = r.mapping.clone();
      if (c == null || !$cast(m, c) || m == r.mapping)
        `uvm_fatal("RDMA_COPY_TYPE", "page mapping clone failure");
      // Preserve mapping value fields explicitly; some simulators leave
      // fields at constructor defaults on repeated object clones.
      m.requester_bdf = r.mapping.requester_bdf;
      m.pasid_valid = r.mapping.pasid_valid;
      m.pasid = r.mapping.pasid;
      m.dma_domain_valid = r.mapping.dma_domain_valid;
      m.dma_domain_id = r.mapping.dma_domain_id;
      m.backing_addr = r.mapping.backing_addr;
      m.iova = r.mapping.iova;
      m.size = r.mapping.size;
      m.direction = r.mapping.direction;
      m.permissions = r.mapping.permissions;
      m.state = r.mapping.state;
      mapping = m;
    end
  endfunction

  virtual function rdma_status validate();
    rdma_status s;

    if (!rdma_queue_role_is_ring(role))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "page role is not ring");
    s = rdma_queue_queue_range_status(mapping, mapping_offset, 4096, 4096);
    if (!s.ok())
      return s;
    if (!rdma_queue_aligned(logical_page_offset, 4096) ||
        !rdma_queue_aligned(page_iova.value, 4096))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "page is unaligned");
    if (mapping.iova.value + mapping_offset != page_iova.value)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION, "page IOVA mismatch");
    return rdma_status::success();
  endfunction
endclass

class rdma_queue_ring_layout extends uvm_object;
  `uvm_object_utils(rdma_queue_ring_layout)
  rdma_queue_backing_role_e role;
  int unsigned entry_size_bytes, depth;
  longint unsigned logical_bytes, storage_bytes;
  int unsigned page_count;
  bit initial_polarity;
  rdma_queue_dma_page_ref pages[$];

  function new(string name="rdma_queue_ring_layout");
    super.new(name);
    role = RDMA_QUEUE_ROLE_CQ_RING;
    entry_size_bytes = 0;
    depth = 0;
    logical_bytes = 0;
    storage_bytes = 0;
    page_count = 0;
    initial_polarity = 0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_queue_ring_layout r;
    uvm_object c;
    rdma_queue_dma_page_ref p;

    super.do_copy(rhs);
    if (!$cast(r, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "ring copy mismatch");
    role = r.role;
    entry_size_bytes = r.entry_size_bytes;
    depth = r.depth;
    logical_bytes = r.logical_bytes;
    storage_bytes = r.storage_bytes;
    page_count = r.page_count;
    initial_polarity = r.initial_polarity;
    pages.delete();
    foreach (r.pages[i]) begin
      c = r.pages[i].clone();
      if (c == null || !$cast(p, c) || p == r.pages[i])
        `uvm_fatal("RDMA_COPY_TYPE", "page clone failure");
      pages.push_back(p);
    end
  endfunction

  virtual function rdma_status validate();
    longint unsigned expected;
    rdma_status s;

    if (!rdma_queue_role_is_ring(role) || entry_size_bytes == 0 || depth == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "ring metadata invalid");
    if (depth > 64'hffff_ffff_ffff_ffff / entry_size_bytes)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "ring size overflows");
    expected = depth * entry_size_bytes;
    if (logical_bytes != expected || storage_bytes < 4096 ||
        storage_bytes > 2 * 1024 * 1024 || storage_bytes % 4096 != 0 ||
        storage_bytes < logical_bytes)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "ring layout size invalid");
    if (page_count == 0 || page_count > 512 ||
        page_count != storage_bytes / 4096 || pages.size() != page_count)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "ring page count invalid");
    foreach (pages[i]) begin
      if (pages[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "null page");
      s = pages[i].validate();
      if (!s.ok())
        return s;
    end
    return rdma_status::success();
  endfunction
endclass

class rdma_queue_backing_ref extends uvm_object;
  `uvm_object_utils(rdma_queue_backing_ref)
  rdma_queue_backing_role_e role;
  rdma_dma_mapping mapping;
  rdma_resource_ownership_e ownership;
  longint unsigned mapping_offset, length, logical_queue_offset;
  bit cleanup_complete;
  function new(string name="rdma_queue_backing_ref");
    super.new(name);
    role = RDMA_QUEUE_ROLE_CQ_RING;
    mapping = null;
    ownership = RDMA_OWNERSHIP_BORROWED;
    mapping_offset = 0;
    length = 0;
    logical_queue_offset = 0;
    cleanup_complete = 0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_queue_backing_ref r;
    uvm_object c;
    rdma_dma_mapping m;

    super.do_copy(rhs);
    if (!$cast(r, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "backing ref copy mismatch");
    role = r.role;
    ownership = r.ownership;
    mapping_offset = r.mapping_offset;
    length = r.length;
    logical_queue_offset = r.logical_queue_offset;
    cleanup_complete = r.cleanup_complete;
    if (r.mapping == null) begin
      mapping = null;
    end else begin
      c = r.mapping.clone();
      if (c == null || !$cast(m, c) || m == r.mapping)
        `uvm_fatal("RDMA_COPY_TYPE", "backing mapping clone failure");
      mapping = m;
    end
  endfunction

  virtual function rdma_status validate();
    rdma_status s;
    longint unsigned align;

    if (!(ownership inside {RDMA_OWNERSHIP_BORROWED,
                            RDMA_OWNERSHIP_CONTROL_PLANE}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "ownership invalid");
    if (!rdma_queue_role_is_payload(role) && !rdma_queue_role_is_pd(role))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "backing role invalid");
    if (rdma_queue_role_is_pd(role) &&
        ownership != RDMA_OWNERSHIP_CONTROL_PLANE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "PD backing must be control-plane owned");
    align = (role == RDMA_QUEUE_ROLE_SRQ_SGB) ? 512 : 4096;
    s = rdma_queue_queue_range_status(mapping, mapping_offset, length, align);
    if (!s.ok())
      return s;
    if (!rdma_queue_aligned(logical_queue_offset, align))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "logical offset unaligned");
    if (!rdma_queue_add_ok(logical_queue_offset, length))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "logical range overflows");
    if (cleanup_complete && ownership == RDMA_OWNERSHIP_BORROWED)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "borrowed backing cleaned");
    return rdma_status::success();
  endfunction
endclass

class rdma_context_backing_ref extends uvm_object;
  `uvm_object_utils(rdma_context_backing_ref)
  rdma_function_handle owner;
  rdma_resource_kind_e resource_kind;
  int unsigned local_id;
  uvm_object slot_token;
  rdma_hmc_ref hmc_ref;
  rdma_backing_addr_t shadow_pointer_base;
  longint unsigned slot_length;
  longint unsigned shadow_view_offset;
  longint unsigned shadow_view_length;
  bit release_complete;

  function new(string name = "rdma_context_backing_ref");
    super.new(name);
    owner = null;
    resource_kind = RDMA_RESOURCE_CQ;
    local_id = 0;
    slot_token = null;
    hmc_ref = null;
    shadow_pointer_base = '0;
    slot_length = 0;
    shadow_view_offset = 0;
    shadow_view_length = 0;
    release_complete = 0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_context_backing_ref r;
    uvm_object c;
    rdma_function_handle f;
    rdma_hmc_ref h;

    super.do_copy(rhs);
    if (!$cast(r, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "context copy mismatch");
    resource_kind = r.resource_kind;
    local_id = r.local_id;
    shadow_pointer_base = r.shadow_pointer_base;
    slot_length = r.slot_length;
    shadow_view_offset = r.shadow_view_offset;
    shadow_view_length = r.shadow_view_length;
    release_complete = r.release_complete;
    if (r.owner == null) begin
      owner = null;
    end else begin
      c = r.owner.clone();
      if (c == null || !$cast(f, c) || f == r.owner)
        `uvm_fatal("RDMA_COPY_TYPE", "owner clone failure");
      owner = f;
    end
    if (r.slot_token == null) begin
      slot_token = null;
    end else begin
      c = r.slot_token.clone();
      if (c == null || c == r.slot_token)
        `uvm_fatal("RDMA_COPY_TYPE", "opaque token clone failure");
      slot_token = c;
    end
    if (r.hmc_ref == null) begin
      hmc_ref = null;
    end else begin
      c = r.hmc_ref.clone();
      if (c == null || !$cast(h, c) || h == r.hmc_ref)
        `uvm_fatal("RDMA_COPY_TYPE", "HMC clone failure");
      hmc_ref = h;
    end
  endfunction

  virtual function rdma_status validate();
    rdma_status s;
    rdma_queue_opaque_slot_token token;

    if (owner == null || owner.kind != RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "context owner invalid");
    if (!(resource_kind inside {RDMA_RESOURCE_CQ, RDMA_RESOURCE_SRQ}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "context resource invalid");
    if (slot_token == null || hmc_ref == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "context authority missing");
    if (!$cast(token, slot_token))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "slot token type invalid");
    s = token.validate();
    if (!s.ok())
      return s;
    s = hmc_ref.validate();
    if (!s.ok())
      return s;
    if (slot_length == 0 || shadow_view_length == 0 ||
        shadow_view_length > slot_length ||
        shadow_view_offset > slot_length - shadow_view_length)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "context view out of bounds");
    if (!rdma_queue_aligned(shadow_pointer_base.value, 4096))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "shadow pointer unaligned");
    return rdma_status::success();
  endfunction
endclass

class rdma_queue_flush_target extends uvm_object;
  `uvm_object_utils(rdma_queue_flush_target)
  rdma_queue_backing_role_e role;
  rdma_queue_flush_phase_e phase;
  rdma_queue_backing_ref pd_ref;
  bit flush_complete;

  function new(string name = "rdma_queue_flush_target");
    super.new(name);
    role = RDMA_QUEUE_ROLE_CQ_PD;
    phase = RDMA_QUEUE_FLUSH_PRE_DELETE;
    pd_ref = null;
    flush_complete = 0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_queue_flush_target r;
    uvm_object c;
    rdma_queue_backing_ref p;

    super.do_copy(rhs);
    if (!$cast(r, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "flush copy mismatch");
    role = r.role;
    phase = r.phase;
    flush_complete = r.flush_complete;
    if (r.pd_ref == null) begin
      pd_ref = null;
    end else begin
      c = r.pd_ref.clone();
      if (c == null || !$cast(p, c) || p == r.pd_ref)
        `uvm_fatal("RDMA_COPY_TYPE", "flush ref clone failure");
      pd_ref = p;
    end
  endfunction

  virtual function rdma_status validate();
    rdma_status s;

    if (!rdma_queue_role_is_pd(role) || pd_ref == null ||
        pd_ref.role != role)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "flush PD invalid");
    s = pd_ref.validate();
    if (!s.ok())
      return s;
    if (!(phase inside {RDMA_QUEUE_FLUSH_PRE_DELETE,
                        RDMA_QUEUE_FLUSH_POST_DELETE}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "flush phase invalid");
    return rdma_status::success();
  endfunction
endclass

class rdma_queue_backing_plan extends uvm_object;
  `uvm_object_utils(rdma_queue_backing_plan)
  rdma_resource_kind_e resource_kind;
  rdma_queue_ring_layout rings[$];
  rdma_queue_backing_ref refs[$];
  rdma_context_backing_ref context_ref;
  rdma_queue_flush_target flush_targets[$];

  function new(string name = "rdma_queue_backing_plan");
    super.new(name);
    resource_kind = RDMA_RESOURCE_CQ;
    context_ref = null;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_queue_backing_plan r;
    uvm_object c;
    rdma_queue_ring_layout l;
    rdma_queue_backing_ref b;
    rdma_context_backing_ref x;
    rdma_queue_flush_target f;

    super.do_copy(rhs);
    if (!$cast(r, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "plan copy mismatch");
    resource_kind = r.resource_kind;
    rings.delete();
    refs.delete();
    flush_targets.delete();
    foreach (r.rings[i]) begin
      c = r.rings[i].clone();
      if (c == null || !$cast(l, c))
        `uvm_fatal("RDMA_COPY_TYPE", "ring clone failure");
      rings.push_back(l);
    end
    foreach (r.refs[i]) begin
      c = r.refs[i].clone();
      if (c == null || !$cast(b, c))
        `uvm_fatal("RDMA_COPY_TYPE", "ref clone failure");
      refs.push_back(b);
    end
    foreach (r.flush_targets[i]) begin
      c = r.flush_targets[i].clone();
      if (c == null || !$cast(f, c))
        `uvm_fatal("RDMA_COPY_TYPE", "flush clone failure");
      flush_targets.push_back(f);
    end
    if (r.context_ref == null) begin
      context_ref = null;
    end else begin
      c = r.context_ref.clone();
      if (c == null || !$cast(x, c))
        `uvm_fatal("RDMA_COPY_TYPE", "context clone failure");
      context_ref = x;
    end
  endfunction
  virtual function rdma_status validate();
    rdma_status s; bit seen[13]; bit ref_seen[13]; int unsigned i;
    foreach (seen[i]) seen[i] = 1'b0;
    foreach (ref_seen[i]) ref_seen[i] = 1'b0;
    if (!(resource_kind inside {RDMA_RESOURCE_CQ, RDMA_RESOURCE_SRQ,
                                RDMA_RESOURCE_CEQ, RDMA_RESOURCE_AEQ}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "plan kind invalid");
    foreach (rings[i]) begin
      if (rings[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "null ring");
      s = rings[i].validate();
      if (!s.ok())
        return s;
      if (!rdma_queue_role_is_ring(rings[i].role) ||
          seen[rings[i].role])
        return rdma_status::make(RDMA_SC_INVALID_STATE, "duplicate or invalid ring role");
      seen[rings[i].role] = 1'b1;
    end
    foreach (refs[i]) begin
      if (refs[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "null backing ref");
      s = refs[i].validate();
      if (!s.ok())
        return s;
      if (ref_seen[refs[i].role])
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "duplicate backing role");
      ref_seen[refs[i].role] = 1'b1;
    end
    foreach (flush_targets[i]) begin
      if (flush_targets[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "null flush target");
      s = flush_targets[i].validate();
      if (!s.ok())
        return s;
    end
    case (resource_kind)
      RDMA_RESOURCE_CQ: begin
        if (rings.size() != 1 || !seen[RDMA_QUEUE_ROLE_CQ_RING] ||
            refs.size() != 2 || !ref_seen[RDMA_QUEUE_ROLE_CQ_RING] ||
            !ref_seen[RDMA_QUEUE_ROLE_CQ_PD] || context_ref == null ||
            context_ref.resource_kind != RDMA_RESOURCE_CQ ||
            flush_targets.size() != 1 ||
            flush_targets[0].role != RDMA_QUEUE_ROLE_CQ_PD ||
            flush_targets[0].phase != RDMA_QUEUE_FLUSH_POST_DELETE)
          return rdma_status::make(RDMA_SC_INVALID_STATE, "CQ plan roles invalid");
      end
      RDMA_RESOURCE_SRQ: begin
        if (rings.size() < 2 || rings.size() > 3 || refs.size() < 4 ||
            refs.size() > 5 ||
            !seen[RDMA_QUEUE_ROLE_SRQ_RING] || !seen[RDMA_QUEUE_ROLE_SRFQ_RING] ||
            !ref_seen[RDMA_QUEUE_ROLE_SRQ_RING] || !ref_seen[RDMA_QUEUE_ROLE_SRFQ_RING] ||
            !ref_seen[RDMA_QUEUE_ROLE_SRQ_PD] || !ref_seen[RDMA_QUEUE_ROLE_SRFQ_PD] ||
            ((rings.size() == 3) != seen[RDMA_QUEUE_ROLE_SRQ_SGB]) ||
            ((refs.size() == 5) != ref_seen[RDMA_QUEUE_ROLE_SRQ_SGB]) ||
            context_ref == null || context_ref.resource_kind != RDMA_RESOURCE_SRQ ||
            flush_targets.size() != 2 ||
            flush_targets[0].role != RDMA_QUEUE_ROLE_SRFQ_PD ||
            flush_targets[1].role != RDMA_QUEUE_ROLE_SRQ_PD ||
            flush_targets[0].phase != RDMA_QUEUE_FLUSH_PRE_DELETE ||
            flush_targets[1].phase != RDMA_QUEUE_FLUSH_PRE_DELETE)
          return rdma_status::make(RDMA_SC_INVALID_STATE, "SRQ plan roles invalid");
      end
      RDMA_RESOURCE_CEQ: begin
        if (rings.size() != 1 || !seen[RDMA_QUEUE_ROLE_CEQ_RING] ||
            refs.size() != 2 || !ref_seen[RDMA_QUEUE_ROLE_CEQ_RING] ||
            !ref_seen[RDMA_QUEUE_ROLE_CEQ_PD] || context_ref != null ||
            flush_targets.size() != 0)
          return rdma_status::make(RDMA_SC_INVALID_STATE, "CEQ plan roles invalid");
      end
      RDMA_RESOURCE_AEQ: begin
        if (rings.size() != 1 || !seen[RDMA_QUEUE_ROLE_AEQ_RING] ||
            refs.size() != 2 || !ref_seen[RDMA_QUEUE_ROLE_AEQ_RING] ||
            !ref_seen[RDMA_QUEUE_ROLE_AEQ_PD] || context_ref != null ||
            flush_targets.size() != 0)
          return rdma_status::make(RDMA_SC_INVALID_STATE, "AEQ plan roles invalid");
      end
    endcase
    if (context_ref != null) begin
      s = context_ref.validate();
      if (!s.ok())
        return s;
    end
    return rdma_status::success();
  endfunction
endclass

class rdma_queue_preflight extends uvm_object;
  `uvm_object_utils(rdma_queue_preflight)
  rdma_resource_kind_e resource_kind;
  int unsigned depth;
  int unsigned cqe_size_bytes;
  int unsigned max_sge;
  int unsigned limit_threshold;
  int unsigned local_vector;
  int unsigned hardware_vector;
  int unsigned msix_table_index;
  rdma_queue_backing_spec backing_spec;
  rdma_queue_ring_layout required_rings[$];

  function new(string name = "rdma_queue_preflight");
    super.new(name);
    resource_kind = RDMA_RESOURCE_CQ;
    depth = 0;
    cqe_size_bytes = 0;
    max_sge = 0;
    limit_threshold = 0;
    local_vector = 0;
    hardware_vector = 0;
    msix_table_index = 0;
    backing_spec = null;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_queue_preflight r;
    uvm_object c;
    rdma_queue_backing_spec b;
    rdma_queue_ring_layout l;

    super.do_copy(rhs);
    if (!$cast(r, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "preflight copy mismatch");
    resource_kind = r.resource_kind;
    depth = r.depth;
    cqe_size_bytes = r.cqe_size_bytes;
    max_sge = r.max_sge;
    limit_threshold = r.limit_threshold;
    local_vector = r.local_vector;
    hardware_vector = r.hardware_vector;
    msix_table_index = r.msix_table_index;
    required_rings.delete();
    foreach (r.required_rings[i]) begin
      c = r.required_rings[i].clone();
      if (c == null || !$cast(l, c))
        `uvm_fatal("RDMA_COPY_TYPE", "required ring clone failure");
      required_rings.push_back(l);
    end
    if (r.backing_spec == null) begin
      backing_spec = null;
    end else begin
      c = r.backing_spec.clone();
      if (c == null || !$cast(b, c))
        `uvm_fatal("RDMA_COPY_TYPE", "spec clone failure");
      backing_spec = b;
    end
  endfunction

  virtual function rdma_status validate();
    rdma_status s;

    if (!(resource_kind inside {RDMA_RESOURCE_CQ, RDMA_RESOURCE_SRQ,
                                RDMA_RESOURCE_CEQ, RDMA_RESOURCE_AEQ}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "preflight kind invalid");
    if (depth == 0 || backing_spec == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "preflight fields missing");
    s = backing_spec.validate();
    if (!s.ok())
      return s;
    foreach (required_rings[i]) begin
      if (required_rings[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "null required ring");
      s = required_rings[i].validate();
      if (!s.ok())
        return s;
    end
    if (resource_kind == RDMA_RESOURCE_CQ &&
        !(cqe_size_bytes inside {32, 64, 128}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "CQE size invalid");
    return rdma_status::success();
  endfunction
endclass
