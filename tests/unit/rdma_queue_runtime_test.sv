class rdma_queue_runtime_test extends uvm_test;
  `uvm_component_utils(rdma_queue_runtime_test)

  function new(string name = "rdma_queue_runtime_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function automatic rdma_handle queue_handle(
    string name,
    rdma_resource_kind_e kind,
    int unsigned object_id
  );
    rdma_handle result;
    result = rdma_handle::type_id::create(name);
    result.kind = kind;
    result.function_uid = 64'h1234;
    result.object_id = object_id;
    result.generation = 5;
    return result;
  endfunction

  function automatic void expect_ok(string label, rdma_status status);
    if (status == null || !status.ok())
      `uvm_error(label, status == null ? "null status" :
                 status.convert2string())
  endfunction

  function automatic void expect_code(
    string label,
    rdma_status status,
    rdma_status_code_e code
  );
    if (status == null || status.code != code)
      `uvm_error(label, status == null ? "null status" :
                 status.convert2string())
  endfunction

  task run_phase(uvm_phase phase);
    rdma_queue_runtime runtime;
    rdma_queue_cursor_snapshot reservation;
    rdma_queue_slot_ledger_entry released[$];
    rdma_queue_pending_operation pending;
    rdma_handle queue_h;
    rdma_handle stale_h;
    rdma_post_send_req request;
    rdma_hw_image image;
    rdma_status status;

    phase.raise_objection(this);
    runtime = rdma_queue_runtime::type_id::create("runtime");
    queue_h = queue_handle("qp", RDMA_RESOURCE_QP, 9);

    status = runtime.configure(queue_h, RDMA_QUEUE_RUNTIME_SQ, 3,
                               0, 1'b0, 0, 1'b0, 1'b1);
    expect_code("POWER_OF_TWO", status, RDMA_SC_INVALID_ARGUMENT);
    status = runtime.configure(queue_h, RDMA_QUEUE_RUNTIME_SQ, 4,
                               3, 1'b0, 3, 1'b0, 1'b1);
    expect_ok("CONFIGURE", status);
    expect_ok("ACTIVATE", runtime.activate());

    request = rdma_post_send_req::type_id::create("request");
    image = rdma_hw_image::type_id::create("image");
    image.length = 64;
    status = runtime.reserve_producer(reservation);
    expect_ok("RESERVE_WRAP", status);
    if (reservation == null || reservation.index != 3 || reservation.wrap)
      `uvm_error("RESERVE_WRAP", "wrong producer reservation")
    status = runtime.commit_producer(reservation, request, 64'h11, 1'b0,
                                     image);
    expect_ok("COMMIT_WRAP", status);
    if (runtime.producer_index != 0 || runtime.producer_wrap != 1'b1 ||
        runtime.used != 1 || runtime.available_slots() != 3)
      `uvm_error("COMMIT_WRAP", "producer wrap/credit update is wrong")

    // Fill remaining credits and prove the full check is side-effect free.
    repeat (3) begin
      expect_ok("RESERVE_FILL", runtime.reserve_producer(reservation));
      expect_ok("COMMIT_FILL", runtime.commit_producer(
        reservation, request, 64'h20 + runtime.used, runtime.used == 3,
        image));
    end
    reservation = rdma_queue_cursor_snapshot::type_id::create("sentinel");
    reservation.index = 99;
    status = runtime.reserve_producer(reservation);
    expect_code("QUEUE_FULL", status, RDMA_SC_QUEUE_FULL);
    if (reservation != null)
      `uvm_error("QUEUE_FULL", "failed reserve published an output")

    // Completion of the last slot releases all preceding contiguous,
    // unsignaled slots and advances CI through the same wrap rule.
    status = runtime.match_and_release(2, 1'b1, released);
    expect_ok("RELEASE_CONTIGUOUS", status);
    if (released.size() != 4 || runtime.used != 0 ||
        runtime.consumer_index != 3 || runtime.consumer_wrap != 1'b1)
      `uvm_error("RELEASE_CONTIGUOUS", "contiguous release is wrong")
    released.delete();
    status = runtime.match_and_release(2, 1'b1, released);
    expect_code("DUPLICATE_COMPLETION", status, RDMA_SC_INVALID_STATE);
    if (released.size() != 0)
      `uvm_error("DUPLICATE_COMPLETION", "failed match published slots")

    stale_h = rdma_clone_handle_value(queue_h, "stale runtime handle");
    stale_h.generation++;
    expect_code("GENERATION", runtime.validate_queue_handle(stale_h),
                RDMA_SC_STALE_GENERATION);

    pending = rdma_queue_pending_operation::type_id::create("pending");
    pending.cursor = rdma_queue_cursor_snapshot::type_id::create("cursor");
    pending.cursor.index = runtime.producer_index;
    expect_ok("ENTER_RECOVERY", runtime.enter_recovery(pending, 1'b1));
    expect_code("AMBIGUOUS_RETRY",
                runtime.recover(RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1),
                RDMA_SC_RECOVERY_REQUIRED);
    expect_ok("ABORT_RECOVERY",
              runtime.recover(RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH, 1'b0));
    if (runtime.state != RDMA_QUEUE_RUNTIME_DETACHED)
      `uvm_error("ABORT_RECOVERY", "runtime did not detach")

    // Known-no-MMIO retry additionally requires explicit caller confirmation.
    runtime = rdma_queue_runtime::type_id::create("retry_runtime");
    expect_ok("RETRY_CONFIG", runtime.configure(
      queue_h, RDMA_QUEUE_RUNTIME_CQ, 8, 0, 1'b0, 0, 1'b0, 1'b0));
    expect_ok("RETRY_ACTIVE", runtime.activate());
    expect_ok("RETRY_ENTER", runtime.enter_recovery(pending, 1'b0));
    expect_code("RETRY_CONFIRM",
                runtime.recover(RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b0),
                RDMA_SC_INVALID_ARGUMENT);
    expect_ok("RETRY_ALLOWED",
              runtime.recover(RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1));
    if (runtime.state != RDMA_QUEUE_RUNTIME_ACTIVE ||
        runtime.pending_operation == null)
      `uvm_error("RETRY_ALLOWED", "retry did not retain pending authority")
    phase.drop_objection(this);
  endtask
endclass
