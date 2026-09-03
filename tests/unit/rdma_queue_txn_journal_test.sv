// 中文说明：覆盖 queue transaction evidence 的单调阶段与恢复前置条件。
class rdma_queue_txn_journal_test extends uvm_test;
  `uvm_component_utils(rdma_queue_txn_journal_test)
  function new(string name = "rdma_queue_txn_journal_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  task run_phase(uvm_phase phase);
    rdma_queue_txn_evidence evidence, submitted;
    rdma_hw_image image;
    rdma_status status;
    phase.raise_objection(this);
    evidence = rdma_queue_txn_evidence::type_id::create("evidence");
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
    evidence.mark_mmio_maybe_submitted();
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

    status = evidence.recover(RDMA_MODEL_RECOVERY_ABORT_AND_DETACH);
    if (!status.ok() || !evidence.aborted)
      `uvm_error("TXN", "abort-and-detach recovery failed")
    status = evidence.advance(RDMA_QUEUE_TXN_PAYLOAD_WRITTEN);
    if (status.ok() || status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("TXN", "aborted transaction advanced")
    phase.drop_objection(this);
  endtask
endclass
