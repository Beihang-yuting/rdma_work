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

  function automatic bit bytes_equal(
    byte unsigned lhs[],
    byte unsigned rhs[]
  );
    if (lhs.size() != rhs.size())
      return 1'b0;
    foreach (lhs[i]) begin
      if (lhs[i] != rhs[i])
        return 1'b0;
    end
    return 1'b1;
  endfunction

  function automatic void snapshot_slot(
    string check_name,
    rdma_mock_context_backing context_api,
    rdma_context_backing_ref context_ref,
    output byte unsigned snapshot[]
  );
    rdma_status status;

    snapshot = new[context_ref.slot_length];
    foreach (snapshot[i]) begin
      status = context_api.read_slot_byte(context_ref, i, snapshot[i]);
      if (status == null || !status.ok())
        `uvm_error(
          check_name,
          $sformatf("failed reading slot byte %0d", i)
        )
    end
  endfunction

  function automatic void expect_slots_unchanged(
    string check_name,
    rdma_mock_context_backing context_api,
    rdma_context_backing_ref first_ref,
    byte unsigned first_before[],
    rdma_context_backing_ref second_ref,
    byte unsigned second_before[]
  );
    byte unsigned first_after[];
    byte unsigned second_after[];

    snapshot_slot({check_name, "_FIRST_READ"}, context_api, first_ref,
                  first_after);
    snapshot_slot({check_name, "_SECOND_READ"}, context_api, second_ref,
                  second_after);
    if (!bytes_equal(first_before, first_after))
      `uvm_error(check_name, "failed operation changed target slot")
    if (!bytes_equal(second_before, second_after))
      `uvm_error(check_name, "failed operation changed adjacent slot")
  endfunction

  function automatic void expect_trace(
    rdma_mock_context_backing context_api,
    string expected[$]
  );
    if (context_api.call_trace.size() != expected.size()) begin
      `uvm_error(
        "CALL_TRACE_SIZE",
        $sformatf("expected %0d calls got %0d",
                  expected.size(), context_api.call_trace.size())
      )
      return;
    end
    foreach (expected[i]) begin
      if (context_api.call_trace[i] != expected[i])
        `uvm_error(
          "CALL_TRACE_ORDER",
          $sformatf("call %0d expected %s got %s", i, expected[i],
                    context_api.call_trace[i])
        )
    end
  endfunction

  task run_phase(uvm_phase phase);
    rdma_mock_context_backing context_api;
    rdma_function_binding binding;
    rdma_context_backing_ref failed_ref, cq_ref, cq_clone;
    rdma_context_backing_ref neighbor_ref, srq_ref, qp_ref, qp_clone, bad_ref;
    rdma_queue_slot_token_contract cq_token, clone_token;
    rdma_queue_slot_token_contract neighbor_token, srq_token, qp_token;
    rdma_queue_slot_token_contract qp_clone_token;
    uvm_object cloned;
    byte unsigned bytes[];
    byte unsigned cq_snapshot[];
    byte unsigned neighbor_snapshot[];
    byte unsigned cq_after_success[];
    byte unsigned neighbor_after_seed[];
    byte unsigned srq_after_success[];
    string expected_trace[$];
    bit complete;

    phase.raise_objection(this);
    context_api = rdma_mock_context_backing::type_id::create("context_api");
    binding = make_binding("binding");

    expect_status(
      "ACQUIRE_FAILURE_QUEUE",
      context_api.fail_next(
        "acquire",
        rdma_status::make(RDMA_SC_TIMEOUT, "injected acquire failure")
      ),
      RDMA_SC_OK
    );
    expect_status(
      "CQC_INJECTED_ACQUIRE",
      context_api.acquire(binding, RDMA_RESOURCE_CQ, 20, failed_ref),
      RDMA_SC_TIMEOUT
    );
    if (failed_ref != null || context_api.slots.size() != 0 ||
        context_api.release_call_count != 0)
      `uvm_error("CQC_INJECTED_ACQUIRE", "failed acquire changed mock state")

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

    expect_status(
      "CQC_NEIGHBOR_ACQUIRE",
      context_api.acquire(binding, RDMA_RESOURCE_CQ, 22, neighbor_ref),
      RDMA_SC_OK
    );
    if (!$cast(neighbor_token, neighbor_ref.slot_token) ||
        neighbor_token.completion_authority == null ||
        neighbor_token === cq_token ||
        neighbor_token.completion_authority === cq_token.completion_authority)
      `uvm_error("CQC_NEIGHBOR_TOKEN", "separate acquires share authority")

    bytes = new[1];
    bytes[0] = 8'hc7;
    expect_status(
      "CQC_NEIGHBOR_SEED",
      context_api.write(neighbor_ref, 0, bytes),
      RDMA_SC_OK
    );
    snapshot_slot("CQC_NEIGHBOR_SEED_READ", context_api, neighbor_ref,
                  neighbor_after_seed);
    foreach (neighbor_after_seed[i]) begin
      if (neighbor_after_seed[i] != (i == 0 ? 8'hc7 : 8'h00))
        `uvm_error("CQC_NEIGHBOR_SEED", "neighbor seed write was ignored")
    end

    bytes = new[8];
    foreach (bytes[i]) bytes[i] = byte'(8'ha0 + i);
    expect_status(
      "CQC_SHADOW_WRITE",
      context_api.write(cq_ref, 48, bytes),
      RDMA_SC_OK
    );
    snapshot_slot("CQC_SHADOW_READ", context_api, cq_ref, cq_after_success);
    foreach (cq_after_success[i]) begin
      if (i >= 48 && i < 56) begin
        if (cq_after_success[i] != byte'(8'ha0 + i - 48))
          `uvm_error("CQC_SHADOW_READ", "CQ shadow byte was not written")
      end else if (cq_after_success[i] != 8'h00) begin
        `uvm_error("CQC_SHADOW_READ", "CQ shadow write changed another byte")
      end
    end

    snapshot_slot("CQC_BOUNDS_BEFORE", context_api, cq_ref, cq_snapshot);
    snapshot_slot("CQC_BOUNDS_NEIGHBOR_BEFORE", context_api, neighbor_ref,
                  neighbor_snapshot);
    bytes = new[9];
    foreach (bytes[i]) bytes[i] = 8'h5a;
    expect_status(
      "CQC_BOUNDS",
      context_api.write(cq_ref, 48, bytes),
      RDMA_SC_DMA_TRANSLATION
    );
    expect_slots_unchanged("CQC_BOUNDS_ATOMIC", context_api, cq_ref,
                           cq_snapshot, neighbor_ref, neighbor_snapshot);

    expect_status(
      "WRITE_FAILURE_QUEUE",
      context_api.fail_next(
        "write",
        rdma_status::make(RDMA_SC_TIMEOUT, "injected write failure")
      ),
      RDMA_SC_OK
    );
    bytes = new[64];
    foreach (bytes[i]) bytes[i] = byte'(8'h30 + i);
    expect_status(
      "CQC_INJECTED_WRITE",
      context_api.write(neighbor_ref, 0, bytes),
      RDMA_SC_TIMEOUT
    );
    expect_slots_unchanged("CQC_INJECTED_WRITE_ATOMIC", context_api,
                           neighbor_ref, neighbor_snapshot, cq_ref,
                           cq_snapshot);

    bytes = new[2];
    bytes[0] = 8'h11;
    bytes[1] = 8'h22;
    expect_status(
      "CQC_CROSS_SLOT",
      context_api.write(cq_ref, 63, bytes),
      RDMA_SC_DMA_TRANSLATION
    );
    expect_slots_unchanged("CQC_CROSS_SLOT_ATOMIC", context_api, cq_ref,
                           cq_snapshot, neighbor_ref, neighbor_snapshot);

    bytes = new[1];
    bytes[0] = 8'he1;
    cloned = cq_ref.clone();
    void'($cast(bad_ref, cloned));
    bad_ref.local_id++;
    expect_status(
      "CQC_LOCAL_ID_AUTHORITY",
      context_api.write(bad_ref, 0, bytes),
      RDMA_SC_INVALID_ARGUMENT
    );
    expect_slots_unchanged("CQC_LOCAL_ID_ATOMIC", context_api, cq_ref,
                           cq_snapshot, neighbor_ref, neighbor_snapshot);

    cloned = cq_ref.clone();
    void'($cast(bad_ref, cloned));
    bad_ref.resource_kind = RDMA_RESOURCE_SRQ;
    expect_status(
      "CQC_KIND_AUTHORITY",
      context_api.write(bad_ref, 0, bytes),
      RDMA_SC_INVALID_ARGUMENT
    );
    expect_slots_unchanged("CQC_KIND_ATOMIC", context_api, cq_ref,
                           cq_snapshot, neighbor_ref, neighbor_snapshot);

    cloned = cq_ref.clone();
    void'($cast(bad_ref, cloned));
    bad_ref.owner.function_uid++;
    expect_status(
      "CQC_OWNER_AUTHORITY",
      context_api.write(bad_ref, 0, bytes),
      RDMA_SC_INVALID_ARGUMENT
    );
    expect_slots_unchanged("CQC_OWNER_ATOMIC", context_api, cq_ref,
                           cq_snapshot, neighbor_ref, neighbor_snapshot);

    cloned = cq_ref.clone();
    void'($cast(bad_ref, cloned));
    bad_ref.slot_token = neighbor_ref.slot_token;
    expect_status(
      "CQC_NEIGHBOR_TOKEN_AUTHORITY",
      context_api.write(bad_ref, 0, bytes),
      RDMA_SC_INVALID_ARGUMENT
    );
    expect_slots_unchanged("CQC_NEIGHBOR_TOKEN_ATOMIC", context_api, cq_ref,
                           cq_snapshot, neighbor_ref, neighbor_snapshot);

    expect_status(
      "QUERY_FAILURE_QUEUE",
      context_api.fail_next(
        "query_release_completion",
        rdma_status::make(RDMA_SC_TIMEOUT, "injected query failure")
      ),
      RDMA_SC_OK
    );
    complete = 1'b1;
    expect_status(
      "CQC_INJECTED_QUERY",
      context_api.query_release_completion(cq_ref, complete),
      RDMA_SC_TIMEOUT
    );
    if (complete || context_api.release_call_count != 0)
      `uvm_error("CQC_INJECTED_QUERY", "failed query changed release state")
    repeat (2) begin
      complete = 1'b1;
      expect_status(
        "CQC_QUERY_BEFORE_RELEASE",
        context_api.query_release_completion(cq_ref, complete),
        RDMA_SC_OK
      );
      if (complete || context_api.release_call_count != 0)
        `uvm_error("CQC_QUERY_BEFORE_RELEASE", "query mutated release state")
    end
    complete = 1'b1;
    expect_status(
      "CQC_NEIGHBOR_QUERY_BEFORE_RELEASE",
      context_api.query_release_completion(neighbor_ref, complete),
      RDMA_SC_OK
    );
    if (complete || context_api.release_call_count != 0)
      `uvm_error("CQC_NEIGHBOR_QUERY_BEFORE_RELEASE",
                 "neighbor unexpectedly reports completion")

    expect_status(
      "RELEASE_FAILURE_QUEUE",
      context_api.fail_next(
        "release",
        rdma_status::make(RDMA_SC_TIMEOUT, "injected release failure")
      ),
      RDMA_SC_OK
    );
    expect_status(
      "CQC_INJECTED_RELEASE",
      context_api.\release (cq_ref),
      RDMA_SC_TIMEOUT
    );
    if (context_api.release_call_count != 0 || cq_ref.release_complete)
      `uvm_error("CQC_INJECTED_RELEASE", "failed release changed state/count")
    complete = 1'b1;
    expect_status(
      "CQC_QUERY_AFTER_FAILED_RELEASE",
      context_api.query_release_completion(cq_ref, complete),
      RDMA_SC_OK
    );
    if (complete || context_api.release_call_count != 0)
      `uvm_error("CQC_QUERY_AFTER_FAILED_RELEASE", "failed release completed")
    complete = 1'b1;
    expect_status(
      "CQC_NEIGHBOR_AFTER_FAILED_RELEASE",
      context_api.query_release_completion(neighbor_ref, complete),
      RDMA_SC_OK
    );
    if (complete || context_api.release_call_count != 0)
      `uvm_error("CQC_NEIGHBOR_AFTER_FAILED_RELEASE",
                 "failed release completed neighboring slot")

    expect_status(
      "CQC_RELEASE",
      context_api.\release (cq_ref),
      RDMA_SC_OK
    );
    complete = 1'b0;
    expect_status(
      "CQC_QUERY_CLONE",
      context_api.query_release_completion(cq_clone, complete),
      RDMA_SC_OK
    );
    if (!complete || context_api.release_call_count != 1)
      `uvm_error("CQC_RELEASE", "clone cannot prove exactly-once release")
    complete = 1'b0;
    expect_status(
      "CQC_QUERY_AFTER_RELEASE_AGAIN",
      context_api.query_release_completion(cq_ref, complete),
      RDMA_SC_OK
    );
    if (!complete || context_api.release_call_count != 1)
      `uvm_error("CQC_QUERY_AFTER_RELEASE_AGAIN", "query mutated completion")
    complete = 1'b1;
    expect_status(
      "CQC_NEIGHBOR_ISOLATION",
      context_api.query_release_completion(neighbor_ref, complete),
      RDMA_SC_OK
    );
    if (complete || context_api.release_call_count != 1)
      `uvm_error("CQC_NEIGHBOR_ISOLATION", "release authority is global")
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
    if (srq_ref == null || srq_ref.slot_length != 32 ||
        srq_ref.shadow_view_offset != 28 ||
        srq_ref.shadow_view_length != 4 ||
        (srq_ref.shadow_pointer_base.value & 4095) != 0)
      `uvm_error("SRQC_REF", "SRQC slot/view geometry is incorrect")
    if (!$cast(srq_token, srq_ref.slot_token) ||
        srq_token.completion_authority == null ||
        srq_token === cq_token || srq_token === neighbor_token ||
        srq_token.completion_authority === cq_token.completion_authority ||
        srq_token.completion_authority ===
          neighbor_token.completion_authority)
      `uvm_error("SRQC_TOKEN", "SRQ acquire shares token authority")

    bytes = new[32];
    foreach (bytes[i]) bytes[i] = byte'(8'h40 + i);
    expect_status(
      "SRQC_FULL_SLOT_WRITE",
      context_api.write(srq_ref, 0, bytes),
      RDMA_SC_OK
    );
    snapshot_slot("SRQC_FULL_SLOT_READ", context_api, srq_ref,
                  srq_after_success);
    foreach (srq_after_success[i]) begin
      if (srq_after_success[i] != byte'(8'h40 + i))
        `uvm_error("SRQC_FULL_SLOT_READ", "SRQ full-slot write was ignored")
    end
    complete = 1'b1;
    expect_status(
      "SRQC_QUERY_BEFORE_RELEASE",
      context_api.query_release_completion(srq_ref, complete),
      RDMA_SC_OK
    );
    if (complete || context_api.release_call_count != 1)
      `uvm_error("SRQC_QUERY_BEFORE_RELEASE", "SRQ completion is not isolated")

    expect_status(
      "CQC_NEIGHBOR_RELEASE",
      context_api.\release (neighbor_ref),
      RDMA_SC_OK
    );
    complete = 1'b1;
    expect_status(
      "SRQC_QUERY_AFTER_NEIGHBOR_RELEASE",
      context_api.query_release_completion(srq_ref, complete),
      RDMA_SC_OK
    );
    if (complete || context_api.release_call_count != 2)
      `uvm_error("SRQC_QUERY_AFTER_NEIGHBOR_RELEASE",
                 "neighbor release completed SRQ")
    complete = 1'b0;
    expect_status(
      "CQC_QUERY_AFTER_NEIGHBOR_RELEASE",
      context_api.query_release_completion(cq_clone, complete),
      RDMA_SC_OK
    );
    if (!complete || context_api.release_call_count != 2)
      `uvm_error("CQC_QUERY_AFTER_NEIGHBOR_RELEASE",
                 "later release changed CQC completion")

    // QP_SQ_RING is only the mock's QP context fault-routing discriminator;
    // the acquired authority remains a QPC context, not SQ backing.
    context_api.fail_role_call(
      "acquire", RDMA_QUEUE_ROLE_QP_SQ_RING, 5,
      rdma_status::make(RDMA_SC_TIMEOUT, "injected QP context acquire failure")
    );
    expect_status(
      "QPC_ROLE_INJECTED_ACQUIRE",
      context_api.acquire(binding, RDMA_RESOURCE_QP, 17, failed_ref),
      RDMA_SC_TIMEOUT
    );
    if (failed_ref != null || context_api.slots.size() != 3)
      `uvm_error("QPC_ROLE_INJECTED_ACQUIRE",
                 "failed QP context acquire changed mock state")

    expect_status(
      "QPC_ACQUIRE",
      context_api.acquire(binding, RDMA_RESOURCE_QP, 17, qp_ref),
      RDMA_SC_OK
    );
    if (qp_ref == null || qp_ref.resource_kind != RDMA_RESOURCE_QP ||
        qp_ref.local_id != 17 || qp_ref.owner == null ||
        !qp_ref.owner.same_instance(binding.make_handle()) ||
        qp_ref.slot_length != 512 || qp_ref.shadow_view_offset != 0 ||
        qp_ref.shadow_view_length != 512 ||
        (qp_ref.shadow_pointer_base.value & 511) != 0 ||
        qp_ref.hmc_ref == null || qp_ref.hmc_ref.size != 512 ||
        qp_ref.hmc_ref.ownership != RDMA_OWNERSHIP_CONTROL_PLANE)
      `uvm_error("QPC_REF", "QP context slot authority is incorrect")
    if (qp_ref != null) begin
    if (!$cast(qp_token, qp_ref.slot_token) ||
        qp_token.completion_authority == null || qp_token === cq_token ||
        qp_token === neighbor_token || qp_token === srq_token)
      `uvm_error("QPC_TOKEN", "QP context lacks isolated opaque authority")

    cloned = qp_ref.clone();
    if (cloned == null || !$cast(qp_clone, cloned) || qp_clone === qp_ref ||
        !$cast(qp_clone_token, qp_clone.slot_token) ||
        qp_clone_token === qp_token ||
        qp_clone_token.completion_authority !== qp_token.completion_authority)
      `uvm_error("QPC_CLONE", "QP context clone lost release authority")

    bytes = new[512];
    foreach (bytes[i]) bytes[i] = byte'(i);
    expect_status("QPC_FULL_SLOT_WRITE",
                  context_api.write(qp_ref, 0, bytes), RDMA_SC_OK);
    expect_status("QPC_LAST_BYTE_READ",
                  context_api.read_slot_byte(qp_ref, 511, bytes[0]),
                  RDMA_SC_OK);
    if (bytes[0] != 8'hff)
      `uvm_error("QPC_LAST_BYTE_READ", "QP context write was not retained")

    context_api.fail_role_call(
      "query_release_completion", RDMA_QUEUE_ROLE_QP_SQ_RING, 13,
      rdma_status::make(RDMA_SC_TIMEOUT, "injected QP context query failure")
    );
    complete = 1'b1;
    expect_status(
      "QPC_ROLE_INJECTED_QUERY",
      context_api.query_release_completion(qp_ref, complete), RDMA_SC_TIMEOUT
    );
    if (complete || context_api.release_call_count != 2)
      `uvm_error("QPC_ROLE_INJECTED_QUERY",
                 "failed QP query changed completion state")
    expect_status(
      "QPC_QUERY_BEFORE_RELEASE",
      context_api.query_release_completion(qp_ref, complete), RDMA_SC_OK
    );
    if (complete)
      `uvm_error("QPC_QUERY_BEFORE_RELEASE",
                 "QP context completed before release")

    context_api.fail_role_call(
      "release", RDMA_QUEUE_ROLE_QP_SQ_RING, 5,
      rdma_status::make(RDMA_SC_TIMEOUT, "injected QP context release failure")
    );
    expect_status("QPC_ROLE_INJECTED_RELEASE",
                  context_api.\release (qp_ref), RDMA_SC_TIMEOUT);
    if (context_api.release_call_count != 2 || qp_ref.release_complete)
      `uvm_error("QPC_ROLE_INJECTED_RELEASE",
                 "failed QP release changed completion state")
    expect_status("QPC_RELEASE", context_api.\release (qp_ref), RDMA_SC_OK);
    complete = 1'b0;
    expect_status(
      "QPC_QUERY_CLONE_AFTER_RELEASE",
      context_api.query_release_completion(qp_clone, complete), RDMA_SC_OK
    );
    if (!complete || context_api.release_call_count != 3)
      `uvm_error("QPC_RELEASE", "QP clone cannot prove one release")
    expect_status("QPC_RELEASE_TWICE",
                  context_api.\release (qp_clone), RDMA_SC_INVALID_STATE);
    if (context_api.release_call_count != 3)
      `uvm_error("QPC_RELEASE_COUNT", "duplicate QP release reached backing")
    end

    expected_trace.push_back("acquire");
    expected_trace.push_back("acquire");
    expected_trace.push_back("acquire");
    expected_trace.push_back("write");
    expected_trace.push_back("write");
    expected_trace.push_back("write");
    expected_trace.push_back("write");
    expected_trace.push_back("write");
    expected_trace.push_back("write");
    expected_trace.push_back("write");
    expected_trace.push_back("write");
    expected_trace.push_back("write");
    expected_trace.push_back("query_release_completion");
    expected_trace.push_back("query_release_completion");
    expected_trace.push_back("query_release_completion");
    expected_trace.push_back("query_release_completion");
    expected_trace.push_back("release");
    expected_trace.push_back("query_release_completion");
    expected_trace.push_back("query_release_completion");
    expected_trace.push_back("release");
    expected_trace.push_back("query_release_completion");
    expected_trace.push_back("query_release_completion");
    expected_trace.push_back("query_release_completion");
    expected_trace.push_back("release");
    expected_trace.push_back("acquire");
    expected_trace.push_back("write");
    expected_trace.push_back("query_release_completion");
    expected_trace.push_back("release");
    expected_trace.push_back("query_release_completion");
    expected_trace.push_back("query_release_completion");
    expected_trace.push_back("acquire");
    expected_trace.push_back("acquire");
    expected_trace.push_back("write");
    expected_trace.push_back("query_release_completion");
    expected_trace.push_back("query_release_completion");
    expected_trace.push_back("release");
    expected_trace.push_back("release");
    expected_trace.push_back("query_release_completion");
    expected_trace.push_back("release");
    expect_trace(context_api, expected_trace);

    phase.drop_objection(this);
  endtask
endclass
