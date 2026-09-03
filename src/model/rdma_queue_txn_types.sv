// 中文说明：rdma_queue_txn_types.sv 定义队列事务的值模型、阶段转换和恢复契约。
typedef struct packed {
  int unsigned index;
  bit wrap;
} rdma_queue_cursor_value_t;

typedef enum bit [2:0] {
  RDMA_QUEUE_TXN_NONE = 3'd0,
  RDMA_QUEUE_TXN_RESERVED = 3'd1,
  RDMA_QUEUE_TXN_PAYLOAD_WRITTEN = 3'd2,
  RDMA_QUEUE_TXN_DOORBELL_MAYBE_SUBMITTED = 3'd3,
  RDMA_QUEUE_TXN_CONSUMER_COMMITTED = 3'd4,
  RDMA_QUEUE_TXN_WQE_RELEASE_PARTIAL = 3'd5,
  RDMA_QUEUE_TXN_COMPLETED = 3'd6
} rdma_queue_txn_phase_e;

typedef enum bit [1:0] {
  RDMA_MODEL_RECOVERY_RETRY_NO_SUBMIT = 2'd0,
  RDMA_MODEL_RECOVERY_FINALIZE_SUBMITTED = 2'd1,
  RDMA_MODEL_RECOVERY_ABORT_AND_DETACH = 2'd2
} rdma_queue_recovery_action_e;

class rdma_queue_cq_release_plan extends uvm_object;
  `uvm_object_utils(rdma_queue_cq_release_plan)
  int unsigned index;
  bit wrap;
  bit released;
  function new(string name = "rdma_queue_cq_release_plan");
    super.new(name); index = 0; wrap = 0; released = 0;
  endfunction
  function rdma_status mark_released();
    released = 1'b1;
    return rdma_status::success();
  endfunction
  virtual function void do_copy(uvm_object rhs);
    rdma_queue_cq_release_plan source;
    super.do_copy(rhs);
    if (!$cast(source, rhs)) `uvm_fatal("RDMA_COPY_TYPE", "release plan copy mismatch");
    index = source.index; wrap = source.wrap; released = source.released;
  endfunction
endclass

class rdma_queue_txn_evidence extends uvm_object;
  `uvm_object_utils(rdma_queue_txn_evidence)
  rdma_function_identity function_identity;
  rdma_handle queue_h;
  rdma_queue_cursor_value_t cursor;
  rdma_queue_cursor_value_t next_cursor;
  rdma_hw_image image;
  rdma_semantic_request request_snapshot;
  uvm_object cqe_snapshot;
  rdma_route_key_t route;
  rdma_status failure_status;
  rdma_queue_txn_phase_e phase;
  bit mmio_maybe_submitted;
  bit aborted;
  time created_at;
  rdma_queue_cq_release_plan release_plan[$];

  function new(string name = "rdma_queue_txn_evidence");
    super.new(name); function_identity = null; queue_h = null;
    cursor = '{default:'0}; next_cursor = '{default:'0}; image = null;
    request_snapshot = null; cqe_snapshot = null; route = '0;
    failure_status = null; phase = RDMA_QUEUE_TXN_NONE;
    mmio_maybe_submitted = 0; aborted = 0; created_at = 0;
    release_plan.delete();
  endfunction

  function rdma_status advance(rdma_queue_txn_phase_e next_phase);
    bit valid_transition;
    if (aborted || phase == RDMA_QUEUE_TXN_COMPLETED)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "transaction is terminal");
    if (next_phase <= phase)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "transaction phase rollback");
    valid_transition = 1'b0;
    case (phase)
      RDMA_QUEUE_TXN_NONE:
        valid_transition = next_phase == RDMA_QUEUE_TXN_RESERVED;
      RDMA_QUEUE_TXN_RESERVED:
        valid_transition = next_phase == RDMA_QUEUE_TXN_PAYLOAD_WRITTEN;
      RDMA_QUEUE_TXN_PAYLOAD_WRITTEN:
        valid_transition = next_phase == RDMA_QUEUE_TXN_DOORBELL_MAYBE_SUBMITTED;
      RDMA_QUEUE_TXN_DOORBELL_MAYBE_SUBMITTED:
        valid_transition = next_phase == RDMA_QUEUE_TXN_CONSUMER_COMMITTED;
      RDMA_QUEUE_TXN_CONSUMER_COMMITTED:
        valid_transition = next_phase == RDMA_QUEUE_TXN_WQE_RELEASE_PARTIAL;
      RDMA_QUEUE_TXN_WQE_RELEASE_PARTIAL:
        valid_transition = next_phase == RDMA_QUEUE_TXN_COMPLETED;
      default:
        valid_transition = 1'b0;
    endcase
    if (!valid_transition)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "invalid transaction phase transition");
    if (next_phase == RDMA_QUEUE_TXN_CONSUMER_COMMITTED && image == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "consumer commit requires image evidence");
    phase = next_phase;
    return rdma_status::success();
  endfunction

  // Capture mutable producer objects as detached value snapshots.
  function rdma_status capture_function_identity(rdma_function_identity source);
    uvm_object cloned;
    if (source == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "Function identity is null");
    if (!source.validate().ok())
      return source.validate();
    cloned = source.clone();
    if (cloned == null || !$cast(function_identity, cloned))
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED, "Function identity snapshot clone failed");
    route = function_identity.route_key();
    return rdma_status::success();
  endfunction

  function rdma_status capture_image(rdma_hw_image source);
    uvm_object cloned;
    if (source == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "hardware image is null");
    cloned = source.clone();
    if (cloned == null || !$cast(image, cloned))
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED, "hardware image snapshot clone failed");
    return rdma_status::success();
  endfunction

  function rdma_status mark_mmio_maybe_submitted();
    if (aborted || phase == RDMA_QUEUE_TXN_COMPLETED)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "transaction is terminal");
    mmio_maybe_submitted = 1'b1;
    if (phase < RDMA_QUEUE_TXN_DOORBELL_MAYBE_SUBMITTED)
      phase = RDMA_QUEUE_TXN_DOORBELL_MAYBE_SUBMITTED;
    return rdma_status::success();
  endfunction

  function rdma_status recover(rdma_queue_recovery_action_e action,
                               bit caller_confirmed_no_submit = 1'b0);
    if (aborted || phase == RDMA_QUEUE_TXN_COMPLETED)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "transaction is terminal");
    case (action)
      RDMA_QUEUE_RECOVERY_RETRY_NO_SUBMIT:
        if (mmio_maybe_submitted || phase >= RDMA_QUEUE_TXN_DOORBELL_MAYBE_SUBMITTED ||
            !caller_confirmed_no_submit)
          return rdma_status::make(RDMA_SC_RECOVERY_REQUIRED,
                                   "retry requires confirmed no-submit evidence");
      RDMA_QUEUE_RECOVERY_FINALIZE_SUBMITTED:
        if (!mmio_maybe_submitted || phase < RDMA_QUEUE_TXN_DOORBELL_MAYBE_SUBMITTED ||
            image == null)
          return rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "finalize requires submitted image evidence");
      RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH:
        aborted = 1'b1;
      default:
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "unknown recovery action");
    endcase
    return rdma_status::success();
  endfunction

  function rdma_status mark_wqe_release(int unsigned index, bit wrap);
    if (aborted || phase == RDMA_QUEUE_TXN_COMPLETED ||
        phase < RDMA_QUEUE_TXN_CONSUMER_COMMITTED)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "WQE release requires committed transaction");
    rdma_queue_cq_release_plan plan;
    foreach (release_plan[i]) begin
      if (release_plan[i].index == index && release_plan[i].wrap == wrap) begin
        release_plan[i].released = 1'b1;
        phase = RDMA_QUEUE_TXN_WQE_RELEASE_PARTIAL;
        return rdma_status::success();
      end
    end
    plan = rdma_queue_cq_release_plan::type_id::create("release_plan");
    plan.index = index; plan.wrap = wrap; plan.released = 1'b1;
    release_plan.push_back(plan);
    phase = RDMA_QUEUE_TXN_WQE_RELEASE_PARTIAL;
    return rdma_status::success();
  endfunction

  function rdma_status complete();
    if (aborted || phase != RDMA_QUEUE_TXN_WQE_RELEASE_PARTIAL)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "transaction cannot complete");
    phase = RDMA_QUEUE_TXN_COMPLETED;
    return rdma_status::success();
  endfunction

  function rdma_status abort();
    aborted = 1'b1;
    return rdma_status::success();
  endfunction
endclass
