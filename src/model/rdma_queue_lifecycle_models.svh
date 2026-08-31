typedef enum bit { RDMA_QUEUE_BACKING_OWNED, RDMA_QUEUE_BACKING_BORROWED }
  rdma_queue_backing_mode_e;

typedef enum bit [4:0] {
  RDMA_QUEUE_ROLE_CQ_RING = 5'd0,
  RDMA_QUEUE_ROLE_SRQ_RING = 5'd1,
  RDMA_QUEUE_ROLE_SRFQ_RING = 5'd2,
  RDMA_QUEUE_ROLE_SRQ_SGB = 5'd3,
  RDMA_QUEUE_ROLE_CEQ_RING = 5'd4,
  RDMA_QUEUE_ROLE_AEQ_RING = 5'd5,
  RDMA_QUEUE_ROLE_CQ_PD = 5'd6,
  RDMA_QUEUE_ROLE_SRQ_PD = 5'd7,
  RDMA_QUEUE_ROLE_SRFQ_PD = 5'd8,
  RDMA_QUEUE_ROLE_CEQ_PD = 5'd9,
  RDMA_QUEUE_ROLE_AEQ_PD = 5'd10,
  RDMA_QUEUE_ROLE_CQC_CONTEXT_SHADOW = 5'd11,
  RDMA_QUEUE_ROLE_SRFQC_CONTEXT_SHADOW = 5'd12,
  RDMA_QUEUE_ROLE_QP_SQ_RING = 5'd13,
  RDMA_QUEUE_ROLE_QP_RQ_RING = 5'd14,
  RDMA_QUEUE_ROLE_QP_SQ_PD = 5'd15,
  RDMA_QUEUE_ROLE_QP_RQ_PD = 5'd16,
  RDMA_QUEUE_ROLE_QP_URC_RSQ = 5'd17,
  RDMA_QUEUE_ROLE_QP_URC_RDSQ = 5'd18,
  RDMA_QUEUE_ROLE_QP_URC_DSQ = 5'd19
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
                      RDMA_QUEUE_ROLE_SRFQ_RING, RDMA_QUEUE_ROLE_SRQ_SGB,
                      RDMA_QUEUE_ROLE_CEQ_RING, RDMA_QUEUE_ROLE_AEQ_RING};
endfunction
function automatic bit rdma_queue_role_is_pd(rdma_queue_backing_role_e role);
  return role inside {RDMA_QUEUE_ROLE_CQ_PD, RDMA_QUEUE_ROLE_SRQ_PD,
                      RDMA_QUEUE_ROLE_SRFQ_PD, RDMA_QUEUE_ROLE_CEQ_PD,
                      RDMA_QUEUE_ROLE_AEQ_PD};
endfunction
// Deliberately distinct from the legacy queue predicates above.  QP backing
// must never become valid input to a legacy queue plan just by widening the
// role enum.
function automatic bit rdma_qp_role_is_payload(rdma_queue_backing_role_e role);
  return role inside {RDMA_QUEUE_ROLE_QP_SQ_RING,
                      RDMA_QUEUE_ROLE_QP_RQ_RING,
                      RDMA_QUEUE_ROLE_QP_URC_RSQ,
                      RDMA_QUEUE_ROLE_QP_URC_RDSQ,
                      RDMA_QUEUE_ROLE_QP_URC_DSQ};
endfunction
function automatic bit rdma_qp_role_is_pd(rdma_queue_backing_role_e role);
  return role inside {RDMA_QUEUE_ROLE_QP_SQ_PD,
                      RDMA_QUEUE_ROLE_QP_RQ_PD};
endfunction
function automatic bit rdma_queue_add_ok(longint unsigned offset,
                                          longint unsigned length);
  return length != 0 && offset <= (64'hffff_ffff_ffff_ffff - length);
endfunction
function automatic bit rdma_queue_aligned(longint unsigned value,
                                           longint unsigned alignment);
  return (value % alignment) == 0;
endfunction
function automatic bit rdma_qp_power_of_two(int unsigned value);
  return value != 0 && (value & (value - 1'b1)) == 0;
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
  if (!rdma_queue_aligned(mapping.iova.value + offset, alignment))
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             "effective queue IOVA is unaligned");
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

class rdma_queue_slot_token_contract extends uvm_object;
  `uvm_object_utils(rdma_queue_slot_token_contract)
  rdma_queue_completion_authority completion_authority;

  function new(string name = "rdma_queue_slot_token_contract");
    super.new(name);
    completion_authority = null;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_queue_slot_token_contract r;

    super.do_copy(rhs);
    if (!$cast(r, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "slot token contract copy mismatch");
    completion_authority = r.completion_authority;
  endfunction

  virtual function rdma_status validate();
    if (completion_authority == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "slot token authority missing");
    return completion_authority.validate();
  endfunction
endclass

class rdma_queue_opaque_slot_token extends rdma_queue_slot_token_contract;
  `uvm_object_utils(rdma_queue_opaque_slot_token)

  function new(string name = "rdma_queue_opaque_slot_token");
    super.new(name);
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
    if (!rdma_queue_role_is_payload(role) && !rdma_qp_role_is_payload(role))
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

  virtual function rdma_status validate_metadata();
    longint unsigned expected;

    if (!rdma_queue_role_is_ring(role) || entry_size_bytes == 0 || depth == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "ring metadata invalid");
    if (depth > 64'hffff_ffff_ffff_ffff / entry_size_bytes)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "ring size overflows");
    expected = depth * entry_size_bytes;
    if (logical_bytes != expected || storage_bytes < 4096 ||
        storage_bytes % 4096 != 0 || storage_bytes < logical_bytes)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "ring layout size invalid");
    if (role == RDMA_QUEUE_ROLE_SRQ_SGB) begin
      if (storage_bytes > 32'hffff_ffff)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "SGB storage exceeds API width");
    end else if (storage_bytes > 2 * 1024 * 1024) begin
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "PD-backed ring storage exceeds ceiling");
    end
    if (page_count == 0 ||
        (role != RDMA_QUEUE_ROLE_SRQ_SGB && page_count > 512) ||
        page_count != storage_bytes / 4096)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "ring page count invalid");
    return rdma_status::success();
  endfunction

  virtual function rdma_status validate();
    rdma_status s;

    s = validate_metadata();
    if (!s.ok())
      return s;
    if (role == RDMA_QUEUE_ROLE_SRQ_SGB && pages.size() == 0)
      return rdma_status::success();
    if (pages.size() != page_count)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "ring materialized page count invalid");
    foreach (pages[i]) begin
      if (pages[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "null page");
      if (pages[i].role != role)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "page role does not match ring role");
      s = pages[i].validate();
      if (!s.ok())
        return s;
    end
    return rdma_status::success();
  endfunction
endclass

class rdma_queue_backing_segment extends uvm_object;
  `uvm_object_utils(rdma_queue_backing_segment)
  rdma_queue_backing_role_e role;
  rdma_dma_mapping mapping;
  rdma_resource_ownership_e ownership;
  longint unsigned mapping_offset;
  longint unsigned length;
  longint unsigned logical_queue_offset;

  function new(string name = "rdma_queue_backing_segment");
    super.new(name);
    role = RDMA_QUEUE_ROLE_CQ_RING;
    mapping = null;
    ownership = RDMA_OWNERSHIP_BORROWED;
    mapping_offset = 0;
    length = 0;
    logical_queue_offset = 0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_queue_backing_segment r;
    uvm_object cloned_object;
    rdma_dma_mapping cloned_mapping;

    super.do_copy(rhs);
    if (!$cast(r, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "backing segment copy mismatch");
    role = r.role;
    ownership = r.ownership;
    mapping_offset = r.mapping_offset;
    length = r.length;
    logical_queue_offset = r.logical_queue_offset;
    if (r.mapping == null) begin
      mapping = null;
    end else begin
      cloned_object = r.mapping.clone();
      if (cloned_object == null ||
          !$cast(cloned_mapping, cloned_object) ||
          cloned_mapping == r.mapping)
        `uvm_fatal("RDMA_COPY_TYPE", "backing segment mapping clone failure");
      mapping = cloned_mapping;
    end
  endfunction

  virtual function rdma_status validate();
    longint unsigned alignment;

    if (!rdma_queue_role_is_payload(role) && !rdma_qp_role_is_payload(role))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "backing segment role is not payload");
    if (!(ownership inside {RDMA_OWNERSHIP_BORROWED,
                            RDMA_OWNERSHIP_CONTROL_PLANE}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "backing segment ownership invalid");
    alignment = (role == RDMA_QUEUE_ROLE_SRQ_SGB) ? 512 : 4096;
    if (!rdma_queue_aligned(logical_queue_offset, alignment))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "backing segment logical offset unaligned");
    if (!rdma_queue_add_ok(logical_queue_offset, length))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "backing segment logical range overflows");
    return rdma_queue_queue_range_status(mapping, mapping_offset, length,
                                         alignment);
  endfunction
endclass

class rdma_queue_backing_ref extends uvm_object;
  `uvm_object_utils(rdma_queue_backing_ref)
  rdma_queue_backing_role_e role;
  rdma_dma_mapping mapping;
  rdma_resource_ownership_e ownership;
  longint unsigned mapping_offset, length, logical_queue_offset;
  rdma_queue_backing_segment additional_segments[$];
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
    rdma_queue_backing_segment segment;

    super.do_copy(rhs);
    if (!$cast(r, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "backing ref copy mismatch");
    role = r.role;
    ownership = r.ownership;
    mapping_offset = r.mapping_offset;
    length = r.length;
    logical_queue_offset = r.logical_queue_offset;
    cleanup_complete = r.cleanup_complete;
    additional_segments.delete();
    if (r.mapping == null) begin
      mapping = null;
    end else begin
      c = r.mapping.clone();
      if (c == null || !$cast(m, c) || m == r.mapping)
        `uvm_fatal("RDMA_COPY_TYPE", "backing mapping clone failure");
      mapping = m;
    end
    foreach (r.additional_segments[i]) begin
      if (r.additional_segments[i] == null)
        `uvm_fatal("RDMA_COPY_TYPE", "null additional backing segment");
      c = r.additional_segments[i].clone();
      if (c == null || !$cast(segment, c) ||
          segment == r.additional_segments[i])
        `uvm_fatal("RDMA_COPY_TYPE", "additional backing segment clone failure");
      additional_segments.push_back(segment);
    end
  endfunction

  virtual function rdma_status validate();
    rdma_status s;
    longint unsigned align;
    longint unsigned next_logical_offset;

    if (!(ownership inside {RDMA_OWNERSHIP_BORROWED,
                            RDMA_OWNERSHIP_CONTROL_PLANE}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "ownership invalid");
    if (!rdma_queue_role_is_payload(role) && !rdma_queue_role_is_pd(role))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "backing role invalid");
    if (rdma_queue_role_is_pd(role) &&
        ownership != RDMA_OWNERSHIP_CONTROL_PLANE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "PD backing must be control-plane owned");
    if (rdma_queue_role_is_pd(role) && additional_segments.size() != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "PD backing cannot contain additional segments");
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
    next_logical_offset = logical_queue_offset + length;
    foreach (additional_segments[i]) begin
      if (additional_segments[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "additional backing segment is null");
      if (additional_segments[i].role != role)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "additional backing segment role mismatch");
      if (additional_segments[i].ownership != ownership)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "additional backing segment ownership mismatch"
        );
      s = additional_segments[i].validate();
      if (!s.ok())
        return s;
      if (additional_segments[i].logical_queue_offset != next_logical_offset)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "additional backing segments are not logically contiguous"
        );
      next_logical_offset = additional_segments[i].logical_queue_offset +
                            additional_segments[i].length;
    end
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
    rdma_queue_slot_token_contract source_token;
    rdma_queue_slot_token_contract cloned_token;

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
      if (!$cast(source_token, r.slot_token))
        `uvm_fatal("RDMA_COPY_TYPE", "source slot token contract invalid");
      c = r.slot_token.clone();
      if (c == null || c == r.slot_token || !$cast(cloned_token, c) ||
          cloned_token.completion_authority == null ||
          cloned_token.completion_authority !==
            source_token.completion_authority)
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
    rdma_queue_slot_token_contract token;

    if (owner == null || owner.kind != RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "context owner invalid");
    if (!(resource_kind inside {RDMA_RESOURCE_CQ, RDMA_RESOURCE_SRQ,
                                RDMA_RESOURCE_QP}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "context resource invalid");
    if (slot_token == null || hmc_ref == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "context authority missing");
    if (!$cast(token, slot_token))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "slot token contract invalid");
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
    if (resource_kind == RDMA_RESOURCE_QP &&
        (slot_length != 512 || shadow_view_offset != 0 ||
         shadow_view_length != 512 || hmc_ref.size != 512))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP context geometry must be 512 bytes");
    if (!rdma_queue_aligned(shadow_pointer_base.value,
                            resource_kind == RDMA_RESOURCE_QP ? 512 : 4096))
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

class rdma_qp_ring_layout extends uvm_object;
  `uvm_object_utils(rdma_qp_ring_layout)
  rdma_queue_backing_role_e role;
  int unsigned entry_size_bytes;
  int unsigned depth;
  longint unsigned logical_bytes;
  longint unsigned storage_bytes;
  rdma_object_mode_e object_mode;

  function new(string name = "rdma_qp_ring_layout");
    super.new(name);
    role = RDMA_QUEUE_ROLE_QP_SQ_RING;
    entry_size_bytes = 64;
    depth = 0;
    logical_bytes = 0;
    storage_bytes = 0;
    object_mode = RDMA_OBJECT_INDIRECT_4K;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_qp_ring_layout r;
    super.do_copy(rhs);
    if (!$cast(r, rhs)) `uvm_fatal("RDMA_COPY_TYPE", "QP ring copy mismatch")
    role = r.role;
    entry_size_bytes = r.entry_size_bytes;
    depth = r.depth;
    logical_bytes = r.logical_bytes;
    storage_bytes = r.storage_bytes;
    object_mode = r.object_mode;
  endfunction

  virtual function rdma_status validate();
    longint unsigned expected_logical;
    longint unsigned expected_storage;

    if (!(role inside {RDMA_QUEUE_ROLE_QP_SQ_RING,
                       RDMA_QUEUE_ROLE_QP_RQ_RING}) ||
        entry_size_bytes != 64 || !rdma_qp_power_of_two(depth))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP ring role or WQE geometry is invalid");
    expected_logical = longint'(depth) * 64;
    if (logical_bytes != expected_logical ||
        expected_logical > 64'hffff_ffff_ffff_efff)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP ring logical bytes are invalid");
    expected_storage = ((expected_logical + 4095) / 4096) * 4096;
    if (storage_bytes != expected_storage || storage_bytes > 2 * 1024 * 1024)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP ring storage geometry is invalid");
    if (object_mode != RDMA_OBJECT_INDIRECT_4K)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP ring mode must be indirect 4 KiB");
    return rdma_status::success();
  endfunction
endclass

class rdma_qp_backing_ref extends uvm_object;
  `uvm_object_utils(rdma_qp_backing_ref)
  rdma_queue_backing_role_e role;
  rdma_dma_mapping mapping;
  rdma_resource_ownership_e ownership;
  longint unsigned mapping_offset;
  longint unsigned length;
  rdma_queue_backing_segment additional_segments[$];
  bit cleanup_complete;

  function new(string name = "rdma_qp_backing_ref");
    super.new(name);
    role = RDMA_QUEUE_ROLE_QP_SQ_RING;
    mapping = null;
    ownership = RDMA_OWNERSHIP_BORROWED;
    mapping_offset = 0;
    length = 0;
    cleanup_complete = 0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_qp_backing_ref r;
    uvm_object c;

    super.do_copy(rhs);
    if (!$cast(r, rhs)) `uvm_fatal("RDMA_COPY_TYPE", "QP backing copy mismatch")
    role = r.role;
    ownership = r.ownership;
    mapping_offset = r.mapping_offset;
    length = r.length;
    cleanup_complete = r.cleanup_complete;
    if (r.mapping == null) mapping = null;
    else begin
      c = r.mapping.clone();
      if (c == null || !$cast(mapping, c) || mapping == r.mapping)
        `uvm_fatal("RDMA_COPY_TYPE", "QP backing mapping clone failure")
    end
    additional_segments.delete();
    foreach (r.additional_segments[i]) begin
      rdma_queue_backing_segment segment;
      c = r.additional_segments[i].clone();
      if (c == null || !$cast(segment, c) || segment == r.additional_segments[i])
        `uvm_fatal("RDMA_COPY_TYPE", "QP additional backing segment clone failure")
      additional_segments.push_back(segment);
    end
  endfunction

  virtual function rdma_status validate();
    rdma_status status;

    if (!rdma_qp_role_is_payload(role) && !rdma_qp_role_is_pd(role))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "QP backing role invalid");
    if (!(ownership inside {RDMA_OWNERSHIP_BORROWED,
                            RDMA_OWNERSHIP_CONTROL_PLANE}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "QP ownership invalid");
    if ((rdma_qp_role_is_pd(role) ||
         role inside {RDMA_QUEUE_ROLE_QP_URC_RSQ,
                      RDMA_QUEUE_ROLE_QP_URC_RDSQ,
                      RDMA_QUEUE_ROLE_QP_URC_DSQ}) &&
        ownership != RDMA_OWNERSHIP_CONTROL_PLANE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "QP internal backing must be control-plane owned");
    if (cleanup_complete && ownership == RDMA_OWNERSHIP_BORROWED)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "borrowed QP backing cleaned");
    status = rdma_queue_queue_range_status(mapping, mapping_offset, length, 4096);
    if (!status.ok()) return status;
    if (rdma_qp_role_is_pd(role) && additional_segments.size() != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP PD backing cannot have segments");
    begin
      longint unsigned next_logical_offset;
      next_logical_offset = length;
      foreach (additional_segments[i]) begin
        if (additional_segments[i] == null ||
            additional_segments[i].role != role ||
            additional_segments[i].ownership != ownership ||
            additional_segments[i].logical_queue_offset != next_logical_offset)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "QP backing segments are not contiguous");
        status = additional_segments[i].validate();
        if (!status.ok()) return status;
        next_logical_offset += additional_segments[i].length;
      end
    end
    if ((role inside {RDMA_QUEUE_ROLE_QP_URC_RSQ,
                      RDMA_QUEUE_ROLE_QP_URC_RDSQ}) && length != 4096 ||
        role == RDMA_QUEUE_ROLE_QP_URC_DSQ && length != 8192)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "URC internal backing geometry is invalid");
    return rdma_status::success();
  endfunction
endclass

class rdma_qp_backing_plan extends uvm_object;
  `uvm_object_utils(rdma_qp_backing_plan)
  rdma_transport_e transport;
  int unsigned sq_depth;
  int unsigned rq_depth;
  rdma_qp_ring_layout sq_ring;
  rdma_qp_ring_layout rq_ring;
  rdma_qp_backing_ref sq_ref;
  rdma_qp_backing_ref rq_ref;
  rdma_qp_backing_ref sq_pd_ref;
  rdma_qp_backing_ref rq_pd_ref;
  rdma_handle rq_source_h;
  rdma_qp_backing_ref urc_refs[$];
  rdma_context_backing_ref context_ref;
  bit sq_pd_flush_complete;
  bit rq_pd_flush_complete;
  bit cleanup_complete;

  function new(string name = "rdma_qp_backing_plan");
    super.new(name);
    transport = RDMA_TRANSPORT_RC;
    sq_depth = 0;
    rq_depth = 0;
    sq_ring = null;
    rq_ring = null;
    sq_ref = null;
    rq_ref = null;
    sq_pd_ref = null;
    rq_pd_ref = null;
    rq_source_h = null;
    context_ref = null;
    sq_pd_flush_complete = 0;
    rq_pd_flush_complete = 0;
    cleanup_complete = 0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_qp_backing_plan r;
    uvm_object c;
    rdma_qp_backing_ref cloned_ref;

    super.do_copy(rhs);
    if (!$cast(r, rhs)) `uvm_fatal("RDMA_COPY_TYPE", "QP plan copy mismatch")
    transport = r.transport;
    sq_depth = r.sq_depth;
    rq_depth = r.rq_depth;
    sq_pd_flush_complete = r.sq_pd_flush_complete;
    rq_pd_flush_complete = r.rq_pd_flush_complete;
    cleanup_complete = r.cleanup_complete;
    sq_ring = null; rq_ring = null; sq_ref = null; rq_ref = null;
    sq_pd_ref = null; rq_pd_ref = null; context_ref = null;
    if (r.sq_ring != null) begin c = r.sq_ring.clone(); if (!$cast(sq_ring, c)) `uvm_fatal("RDMA_COPY_TYPE", "QP SQ ring clone failure") end
    if (r.rq_ring != null) begin c = r.rq_ring.clone(); if (!$cast(rq_ring, c)) `uvm_fatal("RDMA_COPY_TYPE", "QP RQ ring clone failure") end
    if (r.sq_ref != null) begin c = r.sq_ref.clone(); if (!$cast(sq_ref, c)) `uvm_fatal("RDMA_COPY_TYPE", "QP SQ ref clone failure") end
    if (r.rq_ref != null) begin c = r.rq_ref.clone(); if (!$cast(rq_ref, c)) `uvm_fatal("RDMA_COPY_TYPE", "QP RQ ref clone failure") end
    if (r.sq_pd_ref != null) begin c = r.sq_pd_ref.clone(); if (!$cast(sq_pd_ref, c)) `uvm_fatal("RDMA_COPY_TYPE", "QP SQ PD clone failure") end
    if (r.rq_pd_ref != null) begin c = r.rq_pd_ref.clone(); if (!$cast(rq_pd_ref, c)) `uvm_fatal("RDMA_COPY_TYPE", "QP RQ PD clone failure") end
    if (r.rq_source_h == null) rq_source_h = null;
    else begin
      c = r.rq_source_h.clone();
      if (c == null || !$cast(rq_source_h, c) || rq_source_h == r.rq_source_h)
        `uvm_fatal("RDMA_COPY_TYPE", "QP RQ source clone failure")
    end
    urc_refs.delete();
    foreach (r.urc_refs[i]) begin
      if (r.urc_refs[i] == null) urc_refs.push_back(null);
      else begin
        c = r.urc_refs[i].clone();
        if (c == null || !$cast(cloned_ref, c) || cloned_ref == r.urc_refs[i])
          `uvm_fatal("RDMA_COPY_TYPE", "URC ref clone failure")
        urc_refs.push_back(cloned_ref);
      end
    end
    if (r.context_ref != null) begin c = r.context_ref.clone(); if (!$cast(context_ref, c)) `uvm_fatal("RDMA_COPY_TYPE", "QP context clone failure") end
  endfunction

  virtual function rdma_status validate();
    rdma_status status;
    bit seen_urc[3];

    foreach (seen_urc[i]) seen_urc[i] = 0;
    if (!(transport inside {RDMA_TRANSPORT_RC, RDMA_TRANSPORT_UD,
                            RDMA_TRANSPORT_URC}) ||
        !rdma_qp_power_of_two(sq_depth) || !rdma_qp_power_of_two(rq_depth))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "QP plan transport/depth invalid");
    if (sq_ring == null || sq_ref == null || sq_pd_ref == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "QP SQ authority missing");
    status = sq_ring.validate(); if (!status.ok()) return status;
    if (sq_ring.role != RDMA_QUEUE_ROLE_QP_SQ_RING || sq_ring.depth != sq_depth)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "QP SQ ring does not match plan");
    status = sq_ref.validate(); if (!status.ok()) return status;
    status = sq_pd_ref.validate(); if (!status.ok()) return status;
    if (sq_ref.role != RDMA_QUEUE_ROLE_QP_SQ_RING ||
        (sq_ref.length + (sq_ref.additional_segments.size() == 0 ? 0 :
          sq_ref.additional_segments[sq_ref.additional_segments.size()-1].logical_queue_offset +
          sq_ref.additional_segments[sq_ref.additional_segments.size()-1].length - sq_ref.length)) != sq_ring.storage_bytes ||
        sq_pd_ref.role != RDMA_QUEUE_ROLE_QP_SQ_PD ||
        sq_pd_ref.length != 4096)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "QP SQ references do not match ring");
    if (rq_source_h == null) begin
      if (rq_ring == null || rq_ref == null || rq_pd_ref == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE, "QP private RQ authority missing");
      status = rq_ring.validate(); if (!status.ok()) return status;
      status = rq_ref.validate(); if (!status.ok()) return status;
      status = rq_pd_ref.validate(); if (!status.ok()) return status;
      if (rq_ring.role != RDMA_QUEUE_ROLE_QP_RQ_RING || rq_ring.depth != rq_depth ||
          rq_ref.role != RDMA_QUEUE_ROLE_QP_RQ_RING ||
          (rq_ref.length + (rq_ref.additional_segments.size() == 0 ? 0 :
            rq_ref.additional_segments[rq_ref.additional_segments.size()-1].logical_queue_offset +
            rq_ref.additional_segments[rq_ref.additional_segments.size()-1].length - rq_ref.length)) != rq_ring.storage_bytes ||
          rq_pd_ref.role != RDMA_QUEUE_ROLE_QP_RQ_PD ||
          rq_pd_ref.length != 4096)
        return rdma_status::make(RDMA_SC_INVALID_STATE, "QP private RQ references invalid");
    end
    else if (transport != RDMA_TRANSPORT_RC || rq_source_h.kind != RDMA_RESOURCE_SRQ ||
             rq_ring != null || rq_ref != null || rq_pd_ref != null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "QP SRQ RQ authority invalid");
    if (context_ref == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "QP context authority missing");
    status = context_ref.validate(); if (!status.ok()) return status;
    if (context_ref.resource_kind != RDMA_RESOURCE_QP ||
        context_ref.hmc_ref.ownership != RDMA_OWNERSHIP_CONTROL_PLANE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "QP context authority is invalid");
    foreach (urc_refs[i]) begin
      if (urc_refs[i] == null) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "null URC ref");
      status = urc_refs[i].validate(); if (!status.ok()) return status;
      case (urc_refs[i].role)
        RDMA_QUEUE_ROLE_QP_URC_RSQ: seen_urc[0] = 1;
        RDMA_QUEUE_ROLE_QP_URC_RDSQ: seen_urc[1] = 1;
        RDMA_QUEUE_ROLE_QP_URC_DSQ: seen_urc[2] = 1;
        default: return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "invalid URC role");
      endcase
    end
    if ((transport == RDMA_TRANSPORT_URC &&
         (urc_refs.size() != 3 || !seen_urc[0] || !seen_urc[1] || !seen_urc[2])) ||
        (transport != RDMA_TRANSPORT_URC && urc_refs.size() != 0))
      return rdma_status::make(RDMA_SC_INVALID_STATE, "QP URC backing roles invalid");
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
      if (required_rings[i].pages.size() == 0)
        s = required_rings[i].validate_metadata();
      else
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
