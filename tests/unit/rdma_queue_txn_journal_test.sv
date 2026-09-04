// 中文说明：覆盖 queue transaction evidence 的单调阶段与恢复前置条件。
class rdma_queue_txn_journal_test extends uvm_test;
  `uvm_component_utils(rdma_queue_txn_journal_test)
  function new(string name = "rdma_queue_txn_journal_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  task run_phase(uvm_phase phase);
    rdma_queue_txn_evidence evidence, submitted, evidence_copy;
    rdma_hw_image image, cqe, cqe_snapshot_image;
    rdma_function_identity identity;
    rdma_function_key_t key;
    rdma_handle queue_h;
    rdma_semantic_request request;
    rdma_status status, source_failure;
    uvm_object cloned;
    phase.raise_objection(this);
    evidence = rdma_queue_txn_evidence::type_id::create("evidence");
    key = '{root_id:16'h1, host_topology_key:32'h10, function_kind:RDMA_FUNCTION_VF,
            parent_pf_bdf:'{segment:0,bus:8'h20,device:5'h1,function_num:0},
            vf_index:16'h2, bdf:'{segment:0,bus:8'h30,device:5'h4,function_num:1}};
    identity = rdma_function_identity::type_id::create("identity");
    status = identity.configure(key, 0, 64'h1234, 1, 1);
    if (!status.ok() || !evidence.capture_function_identity(identity).ok())
      `uvm_error("TXN", "identity evidence capture failed")
    queue_h = rdma_handle::type_id::create("queue_h");
    queue_h.kind = RDMA_RESOURCE_QP;
    queue_h.function_uid = 64'h1234;
    queue_h.object_id = 32'h55;
    queue_h.generation = 1;
    request = rdma_semantic_request::type_id::create("request");
    request.request_id = 64'ha5;
    cqe = rdma_hw_image::type_id::create("cqe");
    cqe.image_kind = RDMA_IMAGE_CQE;
    source_failure = rdma_status::make(RDMA_SC_TIMEOUT, "timeout captured");
    source_failure.command_id = 64'h77;
    if (!evidence.capture_queue_h(queue_h).ok() ||
        !evidence.capture_request_snapshot(request).ok() ||
        !evidence.capture_cqe_snapshot(cqe).ok() ||
        !evidence.set_failure_status(source_failure).ok())
      `uvm_error("TXN", "transaction evidence capture API failed")
    cloned = evidence.clone();
    if (cloned == null || !$cast(evidence_copy, cloned))
      `uvm_error("TXN", "transaction evidence clone failed")
    else begin
      queue_h.object_id = 32'haa;
      request.request_id = 64'hbb;
      cqe.image_kind = RDMA_IMAGE_SQE;
      source_failure.command_id = 64'hcc;
      if (!$cast(cqe_snapshot_image, evidence.cqe_snapshot))
        `uvm_error("TXN", "CQE snapshot type was not preserved")
      if (evidence.queue_h.object_id != 32'h55 ||
          evidence.request_snapshot.request_id != 64'ha5 ||
          cqe_snapshot_image == null || cqe_snapshot_image.image_kind != RDMA_IMAGE_CQE ||
          evidence.failure_status.command_id != 64'h77 ||
          evidence_copy.queue_h == evidence.queue_h ||
          evidence_copy.failure_status == evidence.failure_status)
        `uvm_error("TXN", "transaction snapshots are not isolated")
    end
    status = evidence.advance(RDMA_QUEUE_TXN_RESERVED);
    if (!status.ok() || evidence.phase != RDMA_QUEUE_TXN_RESERVED)
      `uvm_error("TXN", "reserve phase failed")
    status = evidence.advance(RDMA_QUEUE_TXN_DOORBELL_MAYBE_SUBMITTED);
    if (status.ok() || status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("TXN", "illegal phase skip accepted")
    status = evidence.advance(RDMA_QUEUE_TXN_NONE);
    if (status.ok() || status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("TXN", "illegal phase rollback accepted")
    status = evidence.recover(RDMA_MODEL_RECOVERY_RETRY_NO_SUBMIT, 1'b0);
    if (status.ok() || status.code != RDMA_SC_RECOVERY_REQUIRED)
      `uvm_error("TXN", "retry without no-submit confirmation accepted")
    status = evidence.recover(RDMA_MODEL_RECOVERY_RETRY_NO_SUBMIT, 1'b1);
    if (!status.ok()) `uvm_error("TXN", $sformatf("known no-submit retry rejected: %s", status.convert2string()))
    status = evidence.advance(RDMA_QUEUE_TXN_PAYLOAD_WRITTEN);
    if (!status.ok()) `uvm_error("TXN", "payload phase failed")
    status = evidence.mark_mmio_maybe_submitted();
    if (!status.ok()) `uvm_error("TXN", "MMIO transition failed")
    status = evidence.recover(RDMA_MODEL_RECOVERY_RETRY_NO_SUBMIT, 1'b1);
    if (status.ok() || status.code != RDMA_SC_RECOVERY_REQUIRED)
      `uvm_error("TXN", "ambiguous MMIO retry accepted")
    status = evidence.recover(RDMA_MODEL_RECOVERY_FINALIZE_SUBMITTED, 1'b0);
    if (status.ok() || status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("TXN", "missing image finalize accepted")

    submitted = rdma_queue_txn_evidence::type_id::create("submitted");
    image = rdma_hw_image::type_id::create("image");
    image.image_kind = RDMA_IMAGE_SQE;
    status = submitted.capture_image(image);
    if (!status.ok()) `uvm_error("TXN", "image snapshot capture failed")
    submitted.advance(RDMA_QUEUE_TXN_RESERVED);
    submitted.advance(RDMA_QUEUE_TXN_PAYLOAD_WRITTEN);
    submitted.mark_mmio_maybe_submitted();
    status = submitted.recover(RDMA_MODEL_RECOVERY_FINALIZE_SUBMITTED, 1'b0);
    if (!status.ok()) `uvm_error("TXN", "submitted image finalize rejected")
    if (!submitted.mmio_maybe_submitted || submitted.image == null ||
        submitted.phase != RDMA_QUEUE_TXN_DOORBELL_MAYBE_SUBMITTED)
      `uvm_error("TXN", "finalize recovery lost submitted evidence")
    submitted.advance(RDMA_QUEUE_TXN_CONSUMER_COMMITTED);

    // Release plans are idempotent and completion is only legal after release.
    status = submitted.mark_wqe_release(3, 1'b0);
    if (!status.ok() || submitted.release_plan.size() != 1 ||
        !submitted.release_plan[0].released)
      `uvm_error("TXN", "initial WQE release plan missing")
    status = submitted.mark_wqe_release(3, 1'b0);
    if (!status.ok() || submitted.release_plan.size() != 1 ||
        !submitted.release_plan[0].released)
      `uvm_error("TXN", "duplicate WQE release was not idempotent")
    status = submitted.complete();
    if (!status.ok() || submitted.phase != RDMA_QUEUE_TXN_COMPLETED)
      `uvm_error("TXN", "transaction completion rejected after release")
    status = submitted.advance(RDMA_QUEUE_TXN_RESERVED);
    if (status.ok() || status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("TXN", "advance accepted after terminal completion")

    // Direct phase writes do not bypass complete() transition validation.
    submitted.phase = RDMA_QUEUE_TXN_RESERVED;
    status = submitted.complete();
    if (status.ok() || status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("TXN", "completion bypassed transition validation")

    status = evidence.recover(RDMA_MODEL_RECOVERY_ABORT_AND_DETACH);
    if (!status.ok() || !evidence.aborted)
      `uvm_error("TXN", "abort-and-detach recovery failed")
    status = evidence.advance(RDMA_QUEUE_TXN_PAYLOAD_WRITTEN);
    if (status.ok() || status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("TXN", "aborted transaction advanced")
    phase.drop_objection(this);
  endtask
endclass
