// 目录：协议与资源模型层 model/rdma_queue_txn_types.sv。
// 职责：定义队列事务的值模型、阶段转换与恢复契约。
// 依赖：本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源仅保存非拥有引用，生命周期由调用方管理。

// // 队列事务值模型、阶段转换与恢复契约。
typedef class rdma_cq_shadow_snapshot;
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
  // // CQ WQE 释放计划由事务 evidence 创建并拥有，记录 index/wrap 与释放状态，不转移队列资源所有权。
  `rdma_object_utils(rdma_queue_cq_release_plan)
  int unsigned index;
  bit wrap;
  bit released;
  // 功能：构造 CQ 释放计划，默认 index=0、wrap=0、released=0。
  // 输入/输出及副作用：name 传给 super.new。
  // 失败/边界：无。
  function new(string name = "rdma_queue_cq_release_plan");
    super.new(name); index = 0; wrap = 0; released = 0;
  endfunction
  // 功能：复制 release plan 的值字段。
  // 输入/输出及副作用：rhs 为源对象；当前对象被覆盖，源不变。
  // 失败/边界：rhs 类型不符触发 UVM fatal（release plan copy mismatch）。
  virtual function void do_copy(uvm_object rhs);
    rdma_queue_cq_release_plan source;
    super.do_copy(rhs);
    if (!$cast(source, rhs)) `uvm_fatal("RDMA_COPY_TYPE", "release plan copy mismatch");
    index = source.index; wrap = source.wrap; released = source.released;
  endfunction
endclass

class rdma_queue_txn_evidence extends uvm_object;
  `rdma_object_utils(rdma_queue_txn_evidence)
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
  // // URC 共享 CQ 的恢复证据与 queue runtime 状态分离。
  int unsigned urc_sq_ci;
  int unsigned urc_rq_ci;
  bit [1:0] urc_arm_state;
  longint unsigned urc_sequence;
  rdma_queue_cq_release_plan release_plan[$];

  // 功能：构造事务 evidence，所有句柄/快照为 null，phase 为 NONE，游标清零。
  // 输入/输出及副作用：name 传给 super.new。
  // 失败/边界：无；业务入口使用前须先 capture。
  function new(string name = "rdma_queue_txn_evidence");
    super.new(name); function_identity = null; queue_h = null;
    cursor = '{default:'0}; next_cursor = '{default:'0}; image = null;
    request_snapshot = null; cqe_snapshot = null; route = '0;
    failure_status = null; phase = RDMA_QUEUE_TXN_NONE;
    mmio_maybe_submitted = 0; aborted = 0; created_at = 0;
    urc_sq_ci = 0; urc_rq_ci = 0; urc_arm_state = '0; urc_sequence = 0;
    release_plan.delete();
  endfunction

  // // evidence 是事务创建者拥有的不可变审计快照；capture_* 均克隆调用方对象，不保留外部可变 alias。
  // 功能：复制 evidence 的值字段与 release plan。
  // 输入/输出及副作用：rhs 为源对象；当前对象被覆盖，嵌套对象按值复制。
  // 失败/边界：rhs 类型不符触发 UVM fatal（queue transaction evidence copy mismatch）。
  virtual function void do_copy(uvm_object rhs);
    rdma_queue_txn_evidence source;
    rdma_queue_cq_release_plan plan_copy;

    super.do_copy(rhs);
    if (!$cast(source, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "queue transaction evidence copy mismatch")
    function_identity = rdma_deep_copy#(rdma_function_identity)::of(
      source.function_identity, "transaction identity clone mismatch");
    queue_h = rdma_deep_copy#(rdma_handle)::of(
      source.queue_h, "transaction queue handle clone mismatch");
    cursor = source.cursor;
    next_cursor = source.next_cursor;
    image = rdma_deep_copy#(rdma_hw_image)::of(
      source.image, "transaction image clone mismatch");
    request_snapshot = rdma_deep_copy#(rdma_semantic_request)::of(
      source.request_snapshot, "transaction request clone mismatch");
    if (source.cqe_snapshot == null) cqe_snapshot = null;
    else begin
      cqe_snapshot = source.cqe_snapshot.clone();
      if (cqe_snapshot == null)
        `uvm_fatal("RDMA_COPY_TYPE", "transaction CQE clone mismatch")
    end
    route = source.route;
    failure_status = rdma_deep_copy#(rdma_status)::of(
      source.failure_status, "transaction failure clone mismatch");
    phase = source.phase;
    mmio_maybe_submitted = source.mmio_maybe_submitted;
    aborted = source.aborted;
    created_at = source.created_at;
    urc_sq_ci = source.urc_sq_ci;
    urc_rq_ci = source.urc_rq_ci;
    urc_arm_state = source.urc_arm_state;
    urc_sequence = source.urc_sequence;
    release_plan.delete();
    foreach (source.release_plan[i]) begin
      if (source.release_plan[i] == null) begin
        release_plan.push_back(null);
      end
      else begin
        plan_copy = rdma_deep_copy#(rdma_queue_cq_release_plan)::of(
          source.release_plan[i], "transaction release plan clone mismatch");
        release_plan.push_back(plan_copy);
      end
    end
  endfunction

  // 功能：记录共享 URC CQ 的 SQ/RQ consumer CI、arm state 与 sequence，作为可重放证据。
  // 输入/输出及副作用：shadow 为输入快照；成功时复制其游标字段，不改 shadow。
  // 失败/边界：shadow 为空、validate 返回 null 或失败时返回确定错误，既有字段不变。
  function rdma_status capture_urc_shadow(rdma_cq_shadow_snapshot shadow);
    rdma_status status;
    if (shadow == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "URC CQ shadow is null");
    status = rdma_status::nonnull(
      shadow.validate(),
      "URC CQ shadow validation returned null status"
    );
    if (!status.ok())
      return status;
    urc_sq_ci = shadow.sq_ci;
    urc_rq_ci = shadow.rq_ci;
    urc_arm_state = shadow.arm_state;
    urc_sequence = shadow.\sequence ;
    return rdma_status::success();
  endfunction

  // 功能：按固定顺序推进事务 phase。
  // 输入/输出及副作用：next_phase 为目标阶段；成功时更新 phase。
  // 失败/边界：已终态、phase 回退、非相邻迁移返回 INVALID_STATE；进入 CONSUMER_COMMITTED 需已有 image 证据。
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

  // // 把可变 producer 对象捕获为 detached 值快照。
  // 功能：克隆 Function identity 并记录 route。
  // 输入/输出及副作用：source 为输入；成功时 clone 保存到 evidence。
  // 失败/边界：source 为空返回 INVALID_ARGUMENT；validator 返回 null 返回 INVALID_STATE；clone 失败返回
  //   RESOURCE_EXHAUSTED。
  function rdma_status capture_function_identity(rdma_function_identity source);
    uvm_object cloned;
    rdma_status status;

    if (source == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "Function identity is null");
    status = rdma_status::nonnull(
      source.validate(),
      "Function identity validation returned null status"
    );
    if (!status.ok())
      return status;
    cloned = source.clone();
    if (cloned == null || !$cast(function_identity, cloned))
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED, "Function identity snapshot clone failed");
    route = function_identity.route_key();
    if (!rdma_route_key_valid(route))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "Function route key is invalid");
    return rdma_status::success();
  endfunction

  // 功能：克隆 queue handle 保存到 evidence。
  // 输入/输出及副作用：source 为输入；成功时保存 clone。
  // 失败/边界：source 为空返回 INVALID_ARGUMENT；clone 失败返回 RESOURCE_EXHAUSTED。
  function rdma_status capture_queue_handle(rdma_handle source);
    uvm_object cloned;
    if (source == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "queue handle is null");
    cloned = source.clone();
    if (cloned == null || !$cast(queue_h, cloned))
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "queue handle snapshot clone failed");
    if (queue_h == source)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "queue handle snapshot aliased source");
    return rdma_status::success();
  endfunction

  // // 兼容 queue_h 命名，统一走 detached capture。
  // 功能：capture_queue_handle 的别名。
  // 输入/输出及副作用：同 capture_queue_handle。
  // 失败/边界：同 capture_queue_handle。
  function rdma_status capture_queue_h(rdma_handle source);
    return capture_queue_handle(source);
  endfunction

  // 功能：克隆并校验 semantic request 保存到 evidence。
  // 输入/输出及副作用：source 为输入；成功时保存 clone。
  // 失败/边界：source 为空、validate 为 null/失败、clone 失败时返回 INVALID_ARGUMENT/INVALID_STATE/RESOURCE_EXHAUSTE
  //   D。
  function rdma_status capture_request(rdma_semantic_request source);
    uvm_object cloned;
    rdma_status status;
    if (source == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "semantic request is null");
    status = rdma_status::nonnull(
      source.validate(),
      "semantic request validation returned null status"
    );
    if (!status.ok())
      return status;
    cloned = source.clone();
    if (cloned == null || !$cast(request_snapshot, cloned))
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "request snapshot clone failed");
    if (request_snapshot == source)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "request snapshot aliased source");
    return rdma_status::success();
  endfunction

  // 功能：capture_request 的别名。
  // 输入/输出及副作用：同 capture_request。
  // 失败/边界：同 capture_request。
  function rdma_status capture_request_snapshot(rdma_semantic_request source);
    return capture_request(source);
  endfunction

  // 功能：克隆 CQE 保存到 cqe_snapshot。
  // 输入/输出及副作用：source 为输入；成功时保存 clone。
  // 失败/边界：source 为空返回 INVALID_ARGUMENT；clone 失败返回 RESOURCE_EXHAUSTED。
  function rdma_status capture_cqe(uvm_object source);
    if (source == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "CQE is null");
    cqe_snapshot = source.clone();
    if (cqe_snapshot == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "CQE snapshot clone failed");
    if (cqe_snapshot == source)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "CQE snapshot aliased source");
    return rdma_status::success();
  endfunction

  // 功能：capture_cqe 的别名。
  // 输入/输出及副作用：同 capture_cqe。
  // 失败/边界：同 capture_cqe。
  function rdma_status capture_cqe_snapshot(uvm_object source);
    return capture_cqe(source);
  endfunction

  // 功能：克隆失败 status 保存为 failure_status。
  // 输入/输出及副作用：source 为输入；成功时保存 clone。
  // 失败/边界：source 为空返回 INVALID_ARGUMENT；已终态或 clone 失败时拒绝。
  function rdma_status set_failure(rdma_status source);
    uvm_object cloned;
    if (source == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "failure status is null");
    if (aborted || phase == RDMA_QUEUE_TXN_COMPLETED)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "transaction is terminal");
    cloned = source.clone();
    if (cloned == null || !$cast(failure_status, cloned))
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "failure status snapshot clone failed");
    if (failure_status == source)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "failure status snapshot aliased source");
    return rdma_status::success();
  endfunction

  // 功能：set_failure 的别名。
  // 输入/输出及副作用：同 set_failure。
  // 失败/边界：同 set_failure。
  function rdma_status set_failure_status(rdma_status source);
    return set_failure(source);
  endfunction

  // 功能：克隆硬件 image 保存到 evidence。
  // 输入/输出及副作用：source 为输入；成功时保存 clone。
  // 失败/边界：source 为空返回 INVALID_ARGUMENT；clone 失败返回 RESOURCE_EXHAUSTED。
  function rdma_status capture_image(rdma_hw_image source);
    uvm_object cloned;
    if (source == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "hardware image is null");
    cloned = source.clone();
    if (cloned == null || !$cast(image, cloned))
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED, "hardware image snapshot clone failed");
    if (image == source)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "hardware image snapshot aliased source");
    return rdma_status::success();
  endfunction

  // 功能：标记 doorbell 可能已提交，并推进到 DOORBELL_MAYBE_SUBMITTED。
  // 输入/输出及副作用：无参数；成功时置 mmio_maybe_submitted。
  // 失败/边界：已终态、phase 非 PAYLOAD_WRITTEN 或阶段迁移失败返回 INVALID_STATE。
  function rdma_status mark_mmio_maybe_submitted();
    rdma_status transition_status;

    if (aborted || phase == RDMA_QUEUE_TXN_COMPLETED)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "transaction is terminal");
    if (phase != RDMA_QUEUE_TXN_PAYLOAD_WRITTEN)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "MMIO submission requires payload evidence");
    transition_status =
      advance(RDMA_QUEUE_TXN_DOORBELL_MAYBE_SUBMITTED);
    if (transition_status == null || !transition_status.ok())
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "MMIO phase transition failed");
    mmio_maybe_submitted = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：按恢复动作校验事务是否可重试、收尾或放弃。
  // 输入/输出及副作用：action 为恢复动作；caller_confirmed_no_submit 为调用方确认未提交；ABORT_AND_DETACH 置 aborted。
  // 失败/边界：已终态返回 INVALID_STATE；重试缺未提交证据返回 RECOVERY_REQUIRED；收尾缺 image/提交证据返回 INVALID_STATE；未知动作返回
  //   INVALID_ARGUMENT。
  function rdma_status recover(rdma_queue_recovery_action_e action,
                               bit caller_confirmed_no_submit = 1'b0);
    if (aborted || phase == RDMA_QUEUE_TXN_COMPLETED)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "transaction is terminal");
    case (action)
      RDMA_MODEL_RECOVERY_RETRY_NO_SUBMIT:
        if (mmio_maybe_submitted || phase >= RDMA_QUEUE_TXN_DOORBELL_MAYBE_SUBMITTED ||
            !caller_confirmed_no_submit)
          return rdma_status::make(RDMA_SC_RECOVERY_REQUIRED,
                                   "retry requires confirmed no-submit evidence");
      RDMA_MODEL_RECOVERY_FINALIZE_SUBMITTED:
        if (!mmio_maybe_submitted || phase < RDMA_QUEUE_TXN_DOORBELL_MAYBE_SUBMITTED ||
            image == null)
          return rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "finalize requires submitted image evidence");
      RDMA_MODEL_RECOVERY_ABORT_AND_DETACH:
        aborted = 1'b1;
      default:
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "unknown recovery action");
    endcase
    return rdma_status::success();
  endfunction

  // 功能：登记并标记一个 WQE 已释放，并推进到 WQE_RELEASE_PARTIAL。
  // 输入/输出及副作用：index/wrap 标识 WQE；已有计划则置 released，否则新建计划。
  // 失败/边界：事务未到 CONSUMER_COMMITTED 或已终态返回 INVALID_STATE。
  function rdma_status mark_wqe_release(int unsigned index, bit wrap);
    rdma_queue_cq_release_plan plan;
    if (aborted || phase == RDMA_QUEUE_TXN_COMPLETED ||
        phase < RDMA_QUEUE_TXN_CONSUMER_COMMITTED)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "WQE release requires committed transaction");
    foreach (release_plan[i]) begin
      if (release_plan[i] != null &&
          release_plan[i].index == index && release_plan[i].wrap == wrap) begin
        release_plan[i].released = 1'b1;
        if (phase == RDMA_QUEUE_TXN_WQE_RELEASE_PARTIAL)
          return rdma_status::success();
        return advance(RDMA_QUEUE_TXN_WQE_RELEASE_PARTIAL);
      end
    end
    plan = rdma_queue_cq_release_plan::type_id::create("release_plan");
    plan.index = index; plan.wrap = wrap; plan.released = 1'b1;
    release_plan.push_back(plan);
    // // partial release 可累积多个不同 WQE；新增计划不得再做同阶段迁移，也不得在 INVALID_STATE 时留下改动。
    if (phase == RDMA_QUEUE_TXN_WQE_RELEASE_PARTIAL)
      return rdma_status::success();
    return advance(RDMA_QUEUE_TXN_WQE_RELEASE_PARTIAL);
  endfunction

  // 功能：在至少一个 WQE 已释放后完成事务。
  // 输入/输出及副作用：无参数；成功时推进到 COMPLETED。
  // 失败/边界：非 WQE_RELEASE_PARTIAL、无释放计划或没有已释放 WQE 时返回 INVALID_STATE。
  function rdma_status complete();
    if (aborted || phase != RDMA_QUEUE_TXN_WQE_RELEASE_PARTIAL)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "transaction cannot complete");
    if (release_plan.size() == 0)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "transaction completion requires WQE release plan");
    foreach (release_plan[i]) begin
      if (release_plan[i] != null && release_plan[i].released)
        return advance(RDMA_QUEUE_TXN_COMPLETED);
    end
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             "transaction completion requires released WQE");
  endfunction

endclass
