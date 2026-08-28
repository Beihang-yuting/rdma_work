class rdma_test_slot_token extends rdma_queue_slot_token_contract;
  `uvm_object_utils(rdma_test_slot_token)

  function new(string name = "rdma_test_slot_token");
    super.new(name);
  endfunction
endclass

class rdma_queue_lifecycle_models_test extends uvm_test;
  `uvm_component_utils(rdma_queue_lifecycle_models_test)

  function new(
    string name = "rdma_queue_lifecycle_models_test",
    uvm_component parent = null
  );
    super.new(name, parent);
  endfunction

  function automatic void expect_status(
    string name,
    rdma_status status,
    rdma_status_code_e expected
  );
    if (status == null || status.code != expected) begin
      `uvm_error(
        name,
        $sformatf(
          "expected %s got %s (%s)",
          expected.name(),
          status == null ? "null" : status.code.name(),
          status == null ? "" : status.message
        )
      )
    end
  endfunction

  function automatic rdma_dma_mapping make_mapping(string name);
    rdma_dma_mapping mapping;
    rdma_function_handle function_h;

    mapping = rdma_dma_mapping::type_id::create(name);
    function_h = rdma_function_handle::type_id::create({name, "_f"});
    function_h.function_uid = 64'h11;
    function_h.object_id = 1;
    function_h.generation = 2;
    mapping.function_h = function_h;
    mapping.iova.value = 64'h0000_1000_0000_0000;
    mapping.backing_addr.value = 64'h0000_2000_0000_0000;
    mapping.size = 64'h10000;
    mapping.state = RDMA_MAPPING_ACTIVE;
    return mapping;
  endfunction

  function automatic rdma_handle make_resource_handle(
    string name,
    rdma_resource_kind_e kind,
    rdma_function_handle owner
  );
    rdma_handle handle;

    handle = rdma_handle::type_id::create(name);
    handle.kind = kind;
    handle.function_uid = owner.function_uid;
    handle.object_id = {kind, 28'h12345};
    handle.generation = owner.generation;
    return handle;
  endfunction

  task run_phase(uvm_phase phase);
    rdma_queue_backing_slice slice, slice_clone, metadata_slice;
    rdma_queue_backing_spec spec, metadata_spec;
    rdma_queue_ring_layout layout, layout2, sgb_layout;
    rdma_queue_ring_layout metadata_ring, malformed_ring;
    rdma_queue_dma_page_ref page;
    rdma_dma_mapping mapping;
    rdma_iova_t iova;
    rdma_backing_addr_t base, old_base;
    rdma_queue_flush_target ft;
    rdma_queue_backing_ref pd, ring_ref, ring_ref2, grouped_ref_clone;
    rdma_queue_backing_ref sgb_ref, pd2, pd3;
    rdma_queue_backing_segment additional_segment;
    rdma_queue_backing_plan plan, srq_plan, eq_plan;
    rdma_context_backing_ref ctx, ctx_clone;
    rdma_hmc_ref hmc;
    rdma_queue_completion_authority authority;
    rdma_queue_opaque_slot_token token, cloned_token;
    rdma_test_slot_token adapter_token;
    rdma_queue_preflight preflight;
    rdma_cq cq, cq_clone;
    rdma_srq srq, srq_clone;
    rdma_ceq ceq, ceq_clone;
    rdma_aeq aeq, aeq_clone;
    uvm_object cloned;

    phase.raise_objection(this);

    if (RDMA_QUEUE_ROLE_CQ_RING != 4'd0 ||
        RDMA_QUEUE_ROLE_SRQ_RING != 4'd1 ||
        RDMA_QUEUE_ROLE_SRFQ_RING != 4'd2 ||
        RDMA_QUEUE_ROLE_SRQ_SGB != 4'd3 ||
        RDMA_QUEUE_ROLE_CEQ_RING != 4'd4 ||
        RDMA_QUEUE_ROLE_AEQ_RING != 4'd5 ||
        RDMA_QUEUE_ROLE_CQ_PD != 4'd6 ||
        RDMA_QUEUE_ROLE_SRQ_PD != 4'd7 ||
        RDMA_QUEUE_ROLE_SRFQ_PD != 4'd8 ||
        RDMA_QUEUE_ROLE_CEQ_PD != 4'd9 ||
        RDMA_QUEUE_ROLE_AEQ_PD != 4'd10 ||
        RDMA_QUEUE_ROLE_CQC_CONTEXT_SHADOW != 4'd11 ||
        RDMA_QUEUE_ROLE_SRFQC_CONTEXT_SHADOW != 4'd12)
      `uvm_error("ROLE_ENUM", "role enum values changed")

    mapping = make_mapping("mapping");
    slice = rdma_queue_backing_slice::type_id::create("slice");
    slice.role = RDMA_QUEUE_ROLE_CQ_RING;
    slice.mapping = mapping;
    slice.length = 8192;
    spec = rdma_queue_backing_spec::type_id::create("spec");
    spec.mode = RDMA_QUEUE_BACKING_BORROWED;
    spec.slices.push_back(slice);
    expect_status("BORROWED_SPEC", spec.validate(), RDMA_SC_OK);

    cloned = spec.clone();
    if (cloned == null || !$cast(spec, cloned) ||
        spec.slices[0] === slice || spec.slices[0].mapping === mapping)
      `uvm_error("DEEP_CLONE", "spec clone aliases source")

    layout = rdma_queue_ring_layout::type_id::create("layout");
    layout.role = RDMA_QUEUE_ROLE_CQ_RING;
    layout.entry_size_bytes = 64;
    layout.depth = 128;
    layout.logical_bytes = 8192;
    layout.storage_bytes = 8192;
    layout.page_count = 2;
    layout.initial_polarity = 1'b1;

    page = rdma_queue_dma_page_ref::type_id::create("page0");
    page.role = RDMA_QUEUE_ROLE_CQ_RING;
    page.mapping = mapping;
    page.mapping_offset = 0;
    page.logical_page_offset = 0;
    page.page_iova.value = mapping.iova.value;
    layout.pages.push_back(page);

    page = rdma_queue_dma_page_ref::type_id::create("page1");
    page.role = RDMA_QUEUE_ROLE_CQ_RING;
    page.mapping = mapping;
    page.mapping_offset = 4096;
    page.logical_page_offset = 4096;
    page.page_iova.value = mapping.iova.value + 4096;
    layout.pages.push_back(page);
    expect_status("RING_LAYOUT", layout.validate(), RDMA_SC_OK);

    layout.pages[1].role = RDMA_QUEUE_ROLE_AEQ_RING;
    expect_status(
      "RING_PAGE_ROLE_MISMATCH",
      layout.validate(),
      RDMA_SC_INVALID_ARGUMENT
    );
    layout.pages[1].role = layout.role;

    mapping.iova.value = 64'h0000_1000_0000_0001;
    expect_status(
      "EFFECTIVE_IOVA_UNALIGNED",
      slice.validate(),
      RDMA_SC_INVALID_ARGUMENT
    );
    mapping.iova.value = 64'h0000_1000_0000_0000;
    slice.mapping_offset = 4096;
    mapping.iova.value = 64'hffff_ffff_ffff_f000;
    expect_status(
      "EFFECTIVE_IOVA_OVERFLOW",
      slice.validate(),
      RDMA_SC_DMA_TRANSLATION
    );
    slice.mapping_offset = 0;
    mapping.iova.value = 64'h0000_1000_0000_0000;

    iova.value = 64'h0000_1234_5678_9000;
    base.value = 64'hdead_beef;
    expect_status(
      "IOVA_PROJECTION",
      rdma_queue_base_from_iova(iova, base),
      RDMA_SC_OK
    );
    if (base.value != iova.value)
      `uvm_error("IOVA_PROJECTION", "queue base changed IOVA bits")
    old_base.value = base.value;
    iova.value = 64'h123;
    expect_status(
      "IOVA_REJECT_PRESERVE",
      rdma_queue_base_from_iova(iova, base),
      RDMA_SC_INVALID_ARGUMENT
    );
    if (base.value != old_base.value)
      `uvm_error("IOVA_REJECT_PRESERVE", "invalid projection mutated output")

    spec.mode = RDMA_QUEUE_BACKING_OWNED;
    spec.slices.push_back(slice);
    expect_status("OWNED_SLICES", spec.validate(), RDMA_SC_INVALID_ARGUMENT);

    slice_clone = rdma_queue_backing_slice::type_id::create("slice_bad");
    slice_clone.role = RDMA_QUEUE_ROLE_CQ_PD;
    slice_clone.mapping = mapping;
    slice_clone.length = 4096;
    spec.mode = RDMA_QUEUE_BACKING_BORROWED;
    spec.slices.delete();
    spec.slices.push_back(slice_clone);
    expect_status("METADATA_ROLE", spec.validate(), RDMA_SC_INVALID_ARGUMENT);
    slice_clone.role = RDMA_QUEUE_ROLE_CQ_RING;
    slice_clone.logical_queue_offset = 64'hffff_ffff_ffff_f000;
    expect_status(
      "LOGICAL_RANGE_OVERFLOW",
      slice_clone.validate(),
      RDMA_SC_INVALID_ARGUMENT
    );

    ring_ref = rdma_queue_backing_ref::type_id::create("ring_ref");
    ring_ref.role = RDMA_QUEUE_ROLE_CQ_RING;
    ring_ref.mapping = mapping;
    ring_ref.length = 8192;
    ring_ref.ownership = RDMA_OWNERSHIP_BORROWED;

    additional_segment = rdma_queue_backing_segment::type_id::create(
      "ring_ref_additional_segment"
    );
    additional_segment.role = RDMA_QUEUE_ROLE_CQ_RING;
    additional_segment.mapping = make_mapping("ring_ref_segment_mapping");
    additional_segment.mapping.iova.value += 64'h0000_0000_0001_0000;
    additional_segment.mapping.backing_addr.value +=
      64'h0000_0000_0002_0000;
    additional_segment.ownership = RDMA_OWNERSHIP_BORROWED;
    additional_segment.mapping_offset = 4096;
    additional_segment.length = 4096;
    additional_segment.logical_queue_offset = 8192;
    ring_ref.additional_segments.push_back(additional_segment);
    expect_status("GROUPED_REF_VALID", ring_ref.validate(), RDMA_SC_OK);

    cloned = ring_ref.clone();
    if (!$cast(grouped_ref_clone, cloned) || grouped_ref_clone == ring_ref ||
        grouped_ref_clone.additional_segments.size() != 1 ||
        grouped_ref_clone.additional_segments[0] == additional_segment ||
        grouped_ref_clone.additional_segments[0].mapping ==
          additional_segment.mapping ||
        grouped_ref_clone.additional_segments[0].role !=
          RDMA_QUEUE_ROLE_CQ_RING ||
        grouped_ref_clone.additional_segments[0].ownership !=
          RDMA_OWNERSHIP_BORROWED ||
        grouped_ref_clone.additional_segments[0].mapping_offset != 4096 ||
        grouped_ref_clone.additional_segments[0].length != 4096 ||
        grouped_ref_clone.additional_segments[0].logical_queue_offset != 8192)
      `uvm_error("GROUPED_REF_DEEP_COPY",
                 "additional backing segment was not deeply copied")
    else begin
      grouped_ref_clone.additional_segments[0].length = 8192;
      if (additional_segment.length != 4096)
        `uvm_error("GROUPED_REF_DEEP_COPY",
                   "additional segment mutation reached source")
    end

    additional_segment.role = RDMA_QUEUE_ROLE_AEQ_RING;
    expect_status("GROUPED_REF_ROLE_MISMATCH", ring_ref.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    additional_segment.role = RDMA_QUEUE_ROLE_CQ_RING;
    additional_segment.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
    expect_status("GROUPED_REF_OWNERSHIP_MISMATCH", ring_ref.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    additional_segment.ownership = RDMA_OWNERSHIP_BORROWED;
    additional_segment.mapping_offset = 1;
    expect_status("GROUPED_REF_SEGMENT_RANGE", ring_ref.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    additional_segment.mapping_offset = 4096;
    additional_segment.logical_queue_offset = 12288;
    expect_status("GROUPED_REF_LOGICAL_HOLE", ring_ref.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    additional_segment.logical_queue_offset = 8192;
    ring_ref.additional_segments.delete();

    pd = rdma_queue_backing_ref::type_id::create("pd");
    pd.role = RDMA_QUEUE_ROLE_CQ_PD;
    pd.mapping = mapping;
    pd.length = 4096;
    pd.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
    pd.additional_segments.push_back(additional_segment);
    expect_status("GROUPED_PD_REJECTED", pd.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    pd.additional_segments.delete();
    ft = rdma_queue_flush_target::type_id::create("ft");
    ft.role = RDMA_QUEUE_ROLE_CQ_PD;
    ft.phase = RDMA_QUEUE_FLUSH_POST_DELETE;
    ft.pd_ref = pd;
    plan = rdma_queue_backing_plan::type_id::create("plan");
    plan.resource_kind = RDMA_RESOURCE_CQ;
    plan.flush_targets.push_back(ft);

    ctx = rdma_context_backing_ref::type_id::create("ctx");
    ctx.owner = mapping.function_h;
    ctx.resource_kind = RDMA_RESOURCE_CQ;
    token = rdma_queue_opaque_slot_token::type_id::create("token");
    authority = rdma_queue_completion_authority::type_id::create("authority");
    token.completion_authority = authority;
    ctx.slot_token = token;
    ctx.hmc_ref = rdma_hmc_ref::type_id::create("hmc");
    ctx.slot_length = 64;
    ctx.shadow_view_offset = 60;
    ctx.shadow_view_length = 8;
    ctx.shadow_pointer_base.value = 64'h4000;
    expect_status(
      "CTX_VIEW_BOUNDS",
      ctx.validate(),
      RDMA_SC_INVALID_ARGUMENT
    );
    ctx.shadow_view_offset = 48;

    hmc = ctx.hmc_ref;
    hmc.owner = ctx.owner;
    hmc.object_kind = RDMA_RESOURCE_MR;
    hmc.size = 4096;
    hmc.first_pbl_index = 1;
    plan.rings.push_back(layout);
    plan.refs.push_back(ring_ref);
    plan.refs.push_back(pd);
    plan.context_ref = ctx;
    expect_status("CTX_VALID", ctx.validate(), RDMA_SC_OK);
    expect_status("AUTHORITY_VALID", authority.validate(), RDMA_SC_OK);

    ctx_clone = rdma_context_backing_ref::type_id::create("ctx_clone");
    ctx_clone.copy(ctx);
    if (ctx_clone.slot_token === ctx.slot_token ||
        ctx_clone.hmc_ref === ctx.hmc_ref)
      `uvm_error("CTX_CLONE", "context clone aliases source")
    if (!$cast(cloned_token, ctx_clone.slot_token) ||
        cloned_token.completion_authority !== authority)
      `uvm_error(
        "CTX_AUTHORITY_SHARED",
        "context clone did not preserve shared completion authority"
      )

    adapter_token = rdma_test_slot_token::type_id::create("adapter_token");
    adapter_token.completion_authority = authority;
    ctx.slot_token = adapter_token;
    expect_status("CTX_CUSTOM_TOKEN", ctx.validate(), RDMA_SC_OK);
    ctx_clone.copy(ctx);
    if (!$cast(adapter_token, ctx_clone.slot_token) ||
        adapter_token.completion_authority !== authority)
      `uvm_error(
        "CTX_CUSTOM_AUTHORITY_SHARED",
        "custom token clone did not preserve shared completion authority"
      )

    cq = rdma_cq::type_id::create("cq_resource_snapshot");
    cq.handle = make_resource_handle("cq_resource_h", RDMA_RESOURCE_CQ,
                                     mapping.function_h);
    cq.owner = mapping.function_h;
    cq.state = RDMA_RESOURCE_ALLOCATED;
    expect_status("CQ_ALLOCATED_RESERVATION", cq.validate(), RDMA_SC_OK);
    cq.depth = 128;
    expect_status("CQ_ALLOCATED_PLAN_REQUIRED", cq.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    cq.queue_plan = plan;
    expect_status("CQ_BORROWED_CONTEXT_HMC", cq.validate(),
                  RDMA_SC_INVALID_STATE);
    cq.queue_plan.context_ref.hmc_ref.ownership =
      RDMA_OWNERSHIP_CONTROL_PLANE;
    expect_status("CQ_ALLOCATED_PLAN", cq.validate(), RDMA_SC_OK);
    cq.queue_plan.resource_kind = RDMA_RESOURCE_AEQ;
    expect_status("CQ_ALLOCATED_PLAN_KIND", cq.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    cq.queue_plan.resource_kind = RDMA_RESOURCE_CQ;
    cq.queue_plan = null;
    cq.state = RDMA_RESOURCE_PROGRAMMED;
    expect_status("CQ_PROGRAMMED_PLAN_REQUIRED", cq.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    cq.cqe_size_bytes = 64;
    cq.ceq_h = make_resource_handle("cq_ceq_h", RDMA_RESOURCE_CEQ,
                                    mapping.function_h);
    cq.queue_plan = plan;
    expect_status("CQ_RESOURCE_PLAN", cq.validate(), RDMA_SC_OK);
    cq.cqe_size_bytes = 48;
    expect_status("CQ_RESOURCE_CQE_SIZE", cq.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    cq.state = RDMA_RESOURCE_QUIESCING;
    expect_status("CQ_QUIESCING_CQE_SIZE", cq.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    cq.state = RDMA_RESOURCE_ERROR;
    expect_status("CQ_ERROR_CQE_SIZE", cq.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    cq.state = RDMA_RESOURCE_PROGRAMMED;
    cq.cqe_size_bytes = 64;
    cq.backing_refs.push_back(null);
    expect_status("CQ_SINGLE_QUEUE_AUTHORITY_BACKING", cq.validate(),
                  RDMA_SC_INVALID_STATE);
    cq.backing_refs.delete();
    cq.hmc_refs.push_back(null);
    expect_status("CQ_SINGLE_QUEUE_AUTHORITY_HMC", cq.validate(),
                  RDMA_SC_INVALID_STATE);
    cq.hmc_refs.delete();
    cloned = cq.clone();
    if (!$cast(cq_clone, cloned) || cq_clone.queue_plan == null ||
        cq_clone.queue_plan == cq.queue_plan ||
        cq_clone.queue_plan.rings[0] == cq.queue_plan.rings[0] ||
        cq_clone.queue_plan.rings[0].pages[0] ==
          cq.queue_plan.rings[0].pages[0] ||
        cq_clone.queue_plan.rings[0].pages[0].mapping ==
          cq.queue_plan.rings[0].pages[0].mapping ||
        cq_clone.queue_plan.context_ref == cq.queue_plan.context_ref ||
        cq_clone.cqe_size_bytes != 64)
      `uvm_error("CQ_RESOURCE_DEEP_COPY",
                 "CQ copy lost metadata or aliased its queue plan")
    else begin
      cq_clone.queue_plan.rings[0].depth = 64;
      if (cq.queue_plan.rings[0].depth != 128)
        `uvm_error("CQ_RESOURCE_DEEP_COPY",
                   "CQ plan mutation reached source")
    end
    cq.queue_plan.resource_kind = RDMA_RESOURCE_AEQ;
    expect_status("CQ_PLAN_KIND", cq.validate(), RDMA_SC_INVALID_ARGUMENT);
    cq.queue_plan.resource_kind = RDMA_RESOURCE_CQ;

    pd.role = RDMA_QUEUE_ROLE_SRFQ_PD;
    ft.pd_ref = pd;
    srq_plan = rdma_queue_backing_plan::type_id::create("srq_plan");
    srq_plan.resource_kind = RDMA_RESOURCE_SRQ;
    layout2 = rdma_queue_ring_layout::type_id::create("srq_ring2");
    layout2.copy(layout);
    layout.role = RDMA_QUEUE_ROLE_SRQ_RING;
    layout2.role = RDMA_QUEUE_ROLE_SRFQ_RING;
    foreach (layout.pages[i])
      layout.pages[i].role = RDMA_QUEUE_ROLE_SRQ_RING;
    foreach (layout2.pages[i])
      layout2.pages[i].role = RDMA_QUEUE_ROLE_SRFQ_RING;
    srq_plan.rings.push_back(layout);
    srq_plan.rings.push_back(layout2);

    ring_ref2 = rdma_queue_backing_ref::type_id::create("ring_ref2");
    ring_ref2.copy(ring_ref);
    ring_ref.role = RDMA_QUEUE_ROLE_SRQ_RING;
    ring_ref2.role = RDMA_QUEUE_ROLE_SRFQ_RING;
    pd2 = rdma_queue_backing_ref::type_id::create("srq_pd");
    pd2.copy(pd);
    pd2.role = RDMA_QUEUE_ROLE_SRQ_PD;
    pd3 = rdma_queue_backing_ref::type_id::create("srfq_pd");
    pd3.copy(pd);
    pd3.role = RDMA_QUEUE_ROLE_SRFQ_PD;
    srq_plan.refs.push_back(ring_ref);
    srq_plan.refs.push_back(ring_ref2);
    srq_plan.refs.push_back(pd2);
    srq_plan.refs.push_back(pd3);
    ctx.resource_kind = RDMA_RESOURCE_SRQ;
    srq_plan.context_ref = ctx;

    ft.role = RDMA_QUEUE_ROLE_SRFQ_PD;
    ft.phase = RDMA_QUEUE_FLUSH_PRE_DELETE;
    srq_plan.flush_targets.push_back(ft);
    ft = rdma_queue_flush_target::type_id::create("srq_ft2");
    ft.role = RDMA_QUEUE_ROLE_SRQ_PD;
    ft.phase = RDMA_QUEUE_FLUSH_PRE_DELETE;
    ft.pd_ref = pd2;
    srq_plan.flush_targets.push_back(ft);
    expect_status("SRQ_PLAN_NO_SGB", srq_plan.validate(), RDMA_SC_OK);

    srq = rdma_srq::type_id::create("srq_resource_snapshot");
    srq.handle = make_resource_handle("srq_resource_h", RDMA_RESOURCE_SRQ,
                                      mapping.function_h);
    srq.owner = mapping.function_h;
    srq.state = RDMA_RESOURCE_PROGRAMMED;
    srq.depth = 128;
    srq.max_sge = 4;
    srq.limit_threshold = 16;
    srq.pd_h = make_resource_handle("srq_pd_h", RDMA_RESOURCE_PD,
                                    mapping.function_h);
    srq.queue_plan = srq_plan;
    srq.queue_plan.context_ref.hmc_ref.ownership = RDMA_OWNERSHIP_BORROWED;
    expect_status("SRQ_BORROWED_CONTEXT_HMC", srq.validate(),
                  RDMA_SC_INVALID_STATE);
    srq.queue_plan.context_ref.hmc_ref.ownership =
      RDMA_OWNERSHIP_CONTROL_PLANE;
    expect_status("SRQ_RESOURCE_PLAN", srq.validate(), RDMA_SC_OK);
    srq.limit_threshold = 18;
    expect_status("SRQ_RESOURCE_LIMIT", srq.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    srq.state = RDMA_RESOURCE_QUIESCING;
    expect_status("SRQ_QUIESCING_LIMIT", srq.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    srq.state = RDMA_RESOURCE_ERROR;
    expect_status("SRQ_ERROR_LIMIT", srq.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    srq.state = RDMA_RESOURCE_PROGRAMMED;
    srq.limit_threshold = 16;
    cloned = srq.clone();
    if (!$cast(srq_clone, cloned) || srq_clone.queue_plan == null ||
        srq_clone.queue_plan == srq.queue_plan ||
        srq_clone.limit_threshold != 16)
      `uvm_error("SRQ_RESOURCE_DEEP_COPY",
                 "SRQ copy lost metadata or aliased its queue plan")

    sgb_ref = rdma_queue_backing_ref::type_id::create("sgb_ref");
    sgb_ref.mapping = mapping;
    sgb_ref.role = RDMA_QUEUE_ROLE_SRQ_SGB;
    sgb_ref.length = 8192;
    sgb_ref.ownership = RDMA_OWNERSHIP_BORROWED;
    sgb_layout = rdma_queue_ring_layout::type_id::create("sgb_layout");
    sgb_layout.copy(layout2);
    sgb_layout.role = RDMA_QUEUE_ROLE_SRQ_SGB;
    sgb_layout.pages.delete();
    srq_plan.refs.push_back(sgb_ref);
    srq_plan.rings.push_back(sgb_layout);
    expect_status("SRQ_PLAN_SGB", srq_plan.validate(), RDMA_SC_OK);

    sgb_layout.entry_size_bytes = 512;
    sgb_layout.depth = 8192;
    sgb_layout.logical_bytes = 64'h0040_0000;
    sgb_layout.storage_bytes = 64'h0040_0000;
    sgb_layout.page_count = 1024;
    expect_status("SGB_ABOVE_PD_CEILING", sgb_layout.validate(), RDMA_SC_OK);
    sgb_layout.entry_size_bytes = layout2.entry_size_bytes;
    sgb_layout.depth = layout2.depth;
    sgb_layout.logical_bytes = layout2.logical_bytes;
    sgb_layout.storage_bytes = layout2.storage_bytes;
    sgb_layout.page_count = layout2.page_count;

    sgb_layout.copy(layout2);
    sgb_layout.role = RDMA_QUEUE_ROLE_CQ_RING;
    foreach (sgb_layout.pages[i])
      sgb_layout.pages[i].role = RDMA_QUEUE_ROLE_CQ_RING;
    expect_status(
      "SRQ_SGB_ROLE_MISMATCH",
      srq_plan.validate(),
      RDMA_SC_INVALID_STATE
    );

    eq_plan = rdma_queue_backing_plan::type_id::create("ceq_plan");
    eq_plan.resource_kind = RDMA_RESOURCE_CEQ;
    layout.role = RDMA_QUEUE_ROLE_CEQ_RING;
    foreach (layout.pages[i])
      layout.pages[i].role = RDMA_QUEUE_ROLE_CEQ_RING;
    eq_plan.rings.push_back(layout);
    ring_ref.role = RDMA_QUEUE_ROLE_CEQ_RING;
    pd.role = RDMA_QUEUE_ROLE_CEQ_PD;
    eq_plan.refs.push_back(ring_ref);
    eq_plan.refs.push_back(pd);
    expect_status("CEQ_PLAN", eq_plan.validate(), RDMA_SC_OK);

    ceq = rdma_ceq::type_id::create("ceq_resource_snapshot");
    ceq.handle = make_resource_handle("ceq_resource_h", RDMA_RESOURCE_CEQ,
                                      mapping.function_h);
    ceq.owner = mapping.function_h;
    ceq.state = RDMA_RESOURCE_PROGRAMMED;
    ceq.depth = 128;
    ceq.function_local_vector = 3;
    ceq.hardware_vector = 17;
    ceq.msix_table_index = 5;
    ceq.queue_plan = eq_plan;
    expect_status("CEQ_RESOURCE_PLAN", ceq.validate(), RDMA_SC_OK);
    cloned = ceq.clone();
    if (!$cast(ceq_clone, cloned) || ceq_clone.queue_plan == ceq.queue_plan ||
        ceq_clone.function_local_vector != 3 ||
        ceq_clone.hardware_vector != 17 || ceq_clone.msix_table_index != 5)
      `uvm_error("CEQ_RESOURCE_DEEP_COPY",
                 "CEQ copy lost vector metadata or aliased its plan")

    eq_plan.resource_kind = RDMA_RESOURCE_AEQ;
    layout.role = RDMA_QUEUE_ROLE_AEQ_RING;
    foreach (layout.pages[i])
      layout.pages[i].role = RDMA_QUEUE_ROLE_AEQ_RING;
    ring_ref.role = RDMA_QUEUE_ROLE_AEQ_RING;
    pd.role = RDMA_QUEUE_ROLE_AEQ_PD;
    eq_plan.rings[0] = layout;
    eq_plan.refs[0] = ring_ref;
    eq_plan.refs[1] = pd;
    expect_status("AEQ_PLAN", eq_plan.validate(), RDMA_SC_OK);
    aeq = rdma_aeq::type_id::create("aeq_resource_snapshot");
    aeq.handle = make_resource_handle("aeq_resource_h", RDMA_RESOURCE_AEQ,
                                      mapping.function_h);
    aeq.owner = mapping.function_h;
    aeq.state = RDMA_RESOURCE_PROGRAMMED;
    aeq.depth = 128;
    aeq.function_local_vector = 3;
    aeq.hardware_vector = 17;
    aeq.msix_table_index = 5;
    aeq.queue_plan = eq_plan;
    expect_status("AEQ_RESOURCE_PLAN", aeq.validate(), RDMA_SC_OK);
    cloned = aeq.clone();
    if (!$cast(aeq_clone, cloned) || aeq_clone.queue_plan == aeq.queue_plan ||
        aeq_clone.function_local_vector != 3 ||
        aeq_clone.hardware_vector != 17 || aeq_clone.msix_table_index != 5)
      `uvm_error("AEQ_RESOURCE_DEEP_COPY",
                 "AEQ copy lost vector metadata or aliased its plan")
    eq_plan.refs.push_back(pd2);
    expect_status(
      "AEQ_EXTRA_ROLE",
      eq_plan.validate(),
      RDMA_SC_INVALID_STATE
    );

    plan.resource_kind = RDMA_RESOURCE_SRQ;
    expect_status(
      "SRQ_WRONG_ROLE_SET",
      plan.validate(),
      RDMA_SC_INVALID_ARGUMENT
    );
    plan.resource_kind = RDMA_RESOURCE_CEQ;
    expect_status(
      "CEQ_WRONG_ROLE_SET",
      plan.validate(),
      RDMA_SC_INVALID_ARGUMENT
    );
    plan.resource_kind = RDMA_RESOURCE_AEQ;
    expect_status(
      "AEQ_WRONG_ROLE_SET",
      plan.validate(),
      RDMA_SC_INVALID_ARGUMENT
    );

    preflight = rdma_queue_preflight::type_id::create("preflight");
    preflight.resource_kind = RDMA_RESOURCE_CQ;
    preflight.depth = 128;
    preflight.cqe_size_bytes = 64;
    metadata_spec = rdma_queue_backing_spec::type_id::create("metadata_spec");
    metadata_spec.mode = RDMA_QUEUE_BACKING_BORROWED;
    metadata_slice =
      rdma_queue_backing_slice::type_id::create("metadata_slice");
    metadata_slice.role = RDMA_QUEUE_ROLE_CQ_RING;
    metadata_slice.mapping = mapping;
    metadata_slice.length = 8192;
    metadata_spec.slices.push_back(metadata_slice);
    preflight.backing_spec = metadata_spec;

    metadata_ring = rdma_queue_ring_layout::type_id::create("metadata_ring");
    metadata_ring.copy(layout);
    metadata_ring.pages.delete();
    preflight.required_rings.push_back(metadata_ring);
    expect_status(
      "PREFLIGHT_METADATA_ONLY",
      preflight.validate(),
      RDMA_SC_OK
    );

    malformed_ring =
      rdma_queue_ring_layout::type_id::create("malformed_ring");
    malformed_ring.copy(layout);
    malformed_ring.pages[0].role = RDMA_QUEUE_ROLE_CEQ_RING;
    preflight.required_rings.delete();
    preflight.required_rings.push_back(malformed_ring);
    expect_status(
      "PREFLIGHT_MATERIALIZED_BAD_PAGE",
      preflight.validate(),
      RDMA_SC_INVALID_ARGUMENT
    );

    phase.drop_objection(this);
  endtask
endclass
