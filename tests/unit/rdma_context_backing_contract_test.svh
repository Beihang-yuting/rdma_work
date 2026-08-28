class rdma_context_backing_contract_test extends uvm_test;
  `uvm_component_utils(rdma_context_backing_contract_test)

  function new(
    string name = "rdma_context_backing_contract_test",
    uvm_component parent = null
  );
    super.new(name, parent);
  endfunction

  function automatic void expect_status(
    string check_name,
    rdma_status status,
    rdma_status_code_e expected
  );
    if (status == null || status.code != expected)
      `uvm_error(
        check_name,
        $sformatf(
          "expected %s got %s (%s)",
          expected.name(),
          status == null ? "null" : status.code.name(),
          status == null ? "" : status.message
        )
      )
  endfunction

  function automatic rdma_function_binding make_binding(string name);
    rdma_function_binding binding;

    binding = rdma_function_binding::type_id::create(name);
    binding.function_uid = 64'h1234_5678_9abc_def0;
    binding.global_function_id = 32'h1020_3040;
    binding.generation = 32'd17;
    binding.owner_h = binding.make_handle();
    return binding;
  endfunction

  task run_phase(uvm_phase phase);
    rdma_mock_context_backing context_api;
    rdma_function_binding binding;
    rdma_context_backing_ref cq_ref, cq_clone, neighbor_ref, srq_ref;
    rdma_context_backing_ref bad_ref;
    rdma_queue_slot_token_contract cq_token, clone_token;
    uvm_object cloned;
    byte bytes[];
    byte observed;
    bit complete;

    phase.raise_objection(this);
    context_api = rdma_mock_context_backing::type_id::create("context_api");
    binding = make_binding("binding");

    expect_status(
      "CQC_ACQUIRE",
      context_api.acquire(binding, RDMA_RESOURCE_CQ, 21, cq_ref),
      RDMA_SC_OK
    );
    if (cq_ref == null || cq_ref.slot_length != 64 ||
        cq_ref.shadow_view_offset != 48 ||
        cq_ref.shadow_view_length != 8 ||
        (cq_ref.shadow_pointer_base.value & 63) != 0)
      `uvm_error("CQC_REF", "CQC slot/view geometry is incorrect")
    if (!$cast(cq_token, cq_ref.slot_token) ||
        cq_token.completion_authority == null)
      `uvm_error("CQC_TOKEN", "CQC token does not implement the contract")

    cloned = cq_ref.clone();
    if (cloned == null || !$cast(cq_clone, cloned) || cq_clone === cq_ref ||
        !$cast(clone_token, cq_clone.slot_token) ||
        clone_token === cq_token ||
        clone_token.completion_authority !== cq_token.completion_authority)
      `uvm_error("CQC_CLONE", "CQC clone lost shared completion authority")

    bytes = new[8];
    foreach (bytes[i]) bytes[i] = byte'(8'ha0 + i);
    expect_status(
      "CQC_SHADOW_WRITE",
      context_api.write(cq_ref, 48, bytes),
      RDMA_SC_OK
    );
    bytes = new[9];
    foreach (bytes[i]) bytes[i] = 8'h5a;
    expect_status(
      "CQC_BOUNDS",
      context_api.write(cq_ref, 48, bytes),
      RDMA_SC_DMA_TRANSLATION
    );
    expect_status(
      "CQC_ATOMIC_READ",
      context_api.read_slot_byte(cq_ref, 48, observed),
      RDMA_SC_OK
    );
    if (observed != 8'ha0)
      `uvm_error("CQC_ATOMIC", "failed write partially changed the slot")

    expect_status(
      "CQC_NEIGHBOR_ACQUIRE",
      context_api.acquire(binding, RDMA_RESOURCE_CQ, 22, neighbor_ref),
      RDMA_SC_OK
    );
    bytes = new[1];
    bytes[0] = 8'hc7;
    expect_status(
      "CQC_NEIGHBOR_SEED",
      context_api.write(neighbor_ref, 0, bytes),
      RDMA_SC_OK
    );
    expect_status(
      "CQC_QUEUE_FAILURE",
      context_api.fail_next(
        "write",
        rdma_status::make(RDMA_SC_TIMEOUT, "injected write failure")
      ),
      RDMA_SC_OK
    );
    bytes[0] = 8'h3c;
    expect_status(
      "CQC_INJECTED_WRITE",
      context_api.write(neighbor_ref, 0, bytes),
      RDMA_SC_TIMEOUT
    );
    expect_status(
      "CQC_INJECTED_ATOMIC_READ",
      context_api.read_slot_byte(neighbor_ref, 0, observed),
      RDMA_SC_OK
    );
    if (observed != 8'hc7)
      `uvm_error("CQC_INJECTED_ATOMIC", "failed call changed slot data")
    bytes = new[2];
    bytes[0] = 8'h11;
    bytes[1] = 8'h22;
    expect_status(
      "CQC_CROSS_SLOT",
      context_api.write(cq_ref, 63, bytes),
      RDMA_SC_DMA_TRANSLATION
    );
    expect_status(
      "CQC_NEIGHBOR_READ",
      context_api.read_slot_byte(neighbor_ref, 0, observed),
      RDMA_SC_OK
    );
    if (observed != 8'hc7)
      `uvm_error("CQC_NEIGHBOR", "cross-slot write corrupted neighbor")

    cloned = cq_ref.clone();
    void'($cast(bad_ref, cloned));
    bad_ref.local_id++;
    bytes = new[1];
    expect_status(
      "CQC_LOCAL_ID_AUTHORITY",
      context_api.write(bad_ref, 0, bytes),
      RDMA_SC_INVALID_ARGUMENT
    );
    cloned = cq_ref.clone();
    void'($cast(bad_ref, cloned));
    bad_ref.resource_kind = RDMA_RESOURCE_SRQ;
    expect_status(
      "CQC_KIND_AUTHORITY",
      context_api.write(bad_ref, 0, bytes),
      RDMA_SC_INVALID_ARGUMENT
    );
    cloned = cq_ref.clone();
    void'($cast(bad_ref, cloned));
    bad_ref.owner.function_uid++;
    expect_status(
      "CQC_OWNER_AUTHORITY",
      context_api.write(bad_ref, 0, bytes),
      RDMA_SC_INVALID_ARGUMENT
    );
    cloned = cq_ref.clone();
    void'($cast(bad_ref, cloned));
    bad_ref.slot_token = rdma_queue_opaque_slot_token::type_id::create(
      "unrecognized_token"
    );
    expect_status(
      "CQC_TOKEN_AUTHORITY",
      context_api.write(bad_ref, 0, bytes),
      RDMA_SC_INVALID_ARGUMENT
    );

    expect_status(
      "CQC_RELEASE",
      context_api.\release (cq_ref),
      RDMA_SC_OK
    );
    expect_status(
      "CQC_QUERY_CLONE",
      context_api.query_release_completion(cq_clone, complete),
      RDMA_SC_OK
    );
    if (!complete || context_api.release_call_count != 1)
      `uvm_error("CQC_RELEASE", "release completion is not exactly-once")
    expect_status(
      "CQC_RELEASE_TWICE",
      context_api.\release (cq_clone),
      RDMA_SC_INVALID_STATE
    );
    if (context_api.release_call_count != 1)
      `uvm_error("CQC_RELEASE_COUNT", "duplicate release reached backing")

    expect_status(
      "SRQC_ACQUIRE",
      context_api.acquire(binding, RDMA_RESOURCE_SRQ, 7, srq_ref),
      RDMA_SC_OK
    );
    if (srq_ref == null || srq_ref.slot_length < 32 ||
        srq_ref.shadow_view_offset != 28 ||
        srq_ref.shadow_view_length != 4 ||
        (srq_ref.shadow_pointer_base.value & 4095) != 0)
      `uvm_error("SRQC_REF", "SRQC slot/view geometry is incorrect")
    bytes = new[32];
    foreach (bytes[i]) bytes[i] = byte'(i);
    expect_status(
      "SRQC_FULL_SLOT_WRITE",
      context_api.write(srq_ref, 0, bytes),
      RDMA_SC_OK
    );

    if (context_api.call_trace.size() < 10)
      `uvm_error("CALL_TRACE", "context backing call trace is incomplete")

    phase.drop_objection(this);
  endtask
endclass
