class rdma_queue_data_engine_recovery_test extends uvm_test;
  `uvm_component_utils(rdma_queue_data_engine_recovery_test)

  function new(string name = "rdma_queue_data_engine_recovery_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function automatic rdma_handle make_queue_handle(string name);
    rdma_handle result;
    result = rdma_handle::type_id::create(name);
    result.kind = RDMA_RESOURCE_QP;
    result.function_uid = 64'hfeed_0000_0000_0001;
    result.object_id = 32'h42;
    result.generation = 9;
    return result;
  endfunction

  task automatic check_pending_snapshot();
    rdma_queue_runtime runtime;
    rdma_queue_pending_operation pending;
    rdma_queue_pending_operation snapshot;
    rdma_queue_cursor_snapshot cursor;
    rdma_hw_image image;
    rdma_handle queue_h;
    rdma_status status;

    runtime = rdma_queue_runtime::type_id::create("recovery_runtime");
    queue_h = make_queue_handle("recovery_qp");
    status = runtime.configure(queue_h, RDMA_QUEUE_RUNTIME_SQ,
                               8, 0, 0, 0, 0, 1'b1);
    if (status == null || !status.ok()) begin
      `uvm_error("RECOVERY_SETUP", status == null ? "null status" :
                 status.convert2string())
      return;
    end
    status = runtime.activate();
    if (status == null || !status.ok()) begin
      `uvm_error("RECOVERY_ACTIVATE", status == null ? "null status" :
                 status.convert2string())
      return;
    end

    cursor = rdma_queue_cursor_snapshot::type_id::create("pending_cursor");
    cursor.index = 3;
    cursor.wrap = 1'b1;
    image = rdma_hw_image::type_id::create("pending_image");
    image.bytes.push_back(8'haa);
    image.bytes.push_back(8'h55);
    image.length = 2;
    pending = rdma_queue_pending_operation::type_id::create("pending");
    pending.queue_h = queue_h;
    pending.kind = RDMA_QUEUE_RUNTIME_SQ;
    pending.producer = 1'b1;
    pending.entry_offset = 192;
    pending.cursor = cursor;
    pending.image = image;
    status = runtime.enter_recovery(pending, 1'b0);
    if (status == null || !status.ok()) begin
      `uvm_error("RECOVERY_ENTER", status == null ? "null status" :
                 status.convert2string())
      return;
    end

    snapshot = null;
    status = runtime.snapshot_pending(snapshot);
    if (status == null || !status.ok() || snapshot == null ||
        snapshot.queue_h == null || snapshot.queue_h == queue_h ||
        snapshot.kind != RDMA_QUEUE_RUNTIME_SQ || !snapshot.producer ||
        snapshot.entry_offset != 192 || snapshot.cursor == null ||
        snapshot.cursor == cursor || snapshot.cursor.index != 3 ||
        !snapshot.cursor.wrap || snapshot.image == null ||
        snapshot.image == image || snapshot.image.bytes.size() != 2 ||
        snapshot.image.bytes[0] != 8'haa || snapshot.image.bytes[1] != 8'h55)
      `uvm_error("RECOVERY_SNAPSHOT",
                 status == null ? "pending snapshot unavailable" :
                 status.convert2string())
  endtask

  task automatic check_engine_recovery_policy();
    rdma_queue_data_engine_fixture fixture;
    rdma_post_send_req request;
    rdma_queue_post_result result;
    rdma_status status;
    rdma_status injected;

    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "recovery_engine_fixture");
    fixture.setup(status);
    if (status == null || !status.ok()) begin
      `uvm_error("RECOVERY_FIXTURE", status == null ? "null setup status" :
                 status.convert2string())
      return;
    end
    request = fixture.make_send(64'h9999_aaaa_bbbb_cccc);
    injected = rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                  "injected queue write failure");
    fixture.mem.fail_next("write", injected);
    fixture.engine.post_send(request, result, status);
    if (status == null || status.ok() || result != null)
      `uvm_error("RECOVERY_WRITE_FAIL", "failed write published a result")
    fixture.engine.recover_queue(
      fixture.qp.handle, RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b0, status);
    if (status == null || status.code != RDMA_SC_INVALID_ARGUMENT)
      `uvm_error("RECOVERY_CONFIRM", "retry without confirmation was accepted")
    fixture.engine.recover_queue(
      fixture.qp.handle, RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1, status);
    if (status == null || !status.ok())
      `uvm_error("RECOVERY_RETRY", status == null ? "null status" :
                 status.convert2string())
    // A confirmed retry must replay the pending write and producer commit,
    // rather than merely changing the runtime state.  The next post therefore
    // starts at slot 1; slot 0 is owned by the recovered operation.
    result = null;
    fixture.engine.post_send(fixture.make_send(64'h9999_aaaa_bbbb_cccd),
                             result, status);
    if (status == null || !status.ok() || result == null || result.index != 1)
      `uvm_error("RECOVERY_REPLAY", status == null ? "null status" :
                 status.convert2string())

    fixture.pcie.fail_next("mmio_write",
      rdma_status::make(RDMA_SC_TIMEOUT, "injected ambiguous MMIO"));
    result = null;
    fixture.engine.post_send(request, result, status);
    if (status == null || status.ok() || result != null)
      `uvm_error("RECOVERY_MMIO_FAIL", "ambiguous MMIO published a result")
    fixture.engine.recover_queue(
      fixture.qp.handle, RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1, status);
    if (status == null || status.code != RDMA_SC_RECOVERY_REQUIRED)
      `uvm_error("RECOVERY_MMIO_RETRY", "ambiguous MMIO was retried")
    fixture.engine.recover_queue(
      fixture.qp.handle, RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH, 1'b0, status);
    if (status == null || !status.ok())
      `uvm_error("RECOVERY_ABORT", status == null ? "null status" :
                 status.convert2string())
  endtask

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    check_pending_snapshot();
    check_engine_recovery_policy();
    phase.drop_objection(this);
  endtask
endclass
