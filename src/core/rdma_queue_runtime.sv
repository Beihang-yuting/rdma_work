// 中文说明：rdma_queue_runtime.sv 属于核心执行层，负责队列、控制面、资源和恢复流程。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

typedef enum bit [2:0] {
  RDMA_QUEUE_RUNTIME_DETACHED = 3'd0,
  RDMA_QUEUE_RUNTIME_ATTACHED = 3'd1,
  RDMA_QUEUE_RUNTIME_ACTIVE = 3'd2,
  RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED = 3'd3
} rdma_queue_runtime_state_e;

typedef enum bit [2:0] {
  RDMA_QUEUE_RUNTIME_SQ = 3'd0,
  RDMA_QUEUE_RUNTIME_RQ = 3'd1,
  RDMA_QUEUE_RUNTIME_SRQ = 3'd2,
  RDMA_QUEUE_RUNTIME_CQ = 3'd3,
  RDMA_QUEUE_RUNTIME_CEQ = 3'd4,
  RDMA_QUEUE_RUNTIME_AEQ = 3'd5
} rdma_queue_runtime_kind_e;

typedef enum bit {
  RDMA_QUEUE_RECOVERY_RETRY_PENDING = 1'b0,
  RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH = 1'b1
} rdma_queue_recovery_action_e;

class rdma_queue_cursor_snapshot extends uvm_object;
  `uvm_object_utils(rdma_queue_cursor_snapshot)
  int unsigned index;
  bit wrap;

  function new(string name="rdma_queue_cursor_snapshot"); super.new(name); index=0; wrap=0; endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_queue_cursor_snapshot source;
    super.do_copy(rhs);
    if (!$cast(source, rhs)) `uvm_fatal("RDMA_COPY_TYPE", "cursor snapshot copy mismatch");
    index = source.index;
    wrap = source.wrap;
  endfunction
endclass

class rdma_queue_pending_operation extends uvm_object;
  `uvm_object_utils(rdma_queue_pending_operation)
  // Detached transaction evidence retained while a queue is in recovery.
  // These fields deliberately contain value snapshots only; no caller-owned
  // descriptor or raw host backing address is exposed.
  rdma_handle queue_h;
  rdma_queue_runtime_kind_e kind;
  bit producer;
  longint unsigned entry_offset;
  rdma_queue_cursor_snapshot cursor;
  // Cursor after the pending operation.  Keeping this value in the evidence
  // object prevents recovery from deriving a different ring transition after
  // a caller mutates queue geometry.
  rdma_queue_cursor_snapshot next_cursor;
  rdma_hw_image image;
  // Producer retries need the semantic request to rebuild the ledger entry;
  // it is detached here so the caller can safely reuse/mutate its request.
  rdma_semantic_request request_snapshot;
  longint unsigned wr_id;
  bit signaled;
  // CQ consumer retries need the WQE cursor and route identity to release the
  // corresponding producer ledger after the consumer doorbell succeeds.
  int unsigned completion_index;
  bit completion_wrap;
  bit completion_target_valid;
  // CQ recovery may retain evidence after the WQE ledger was released but
  // before the CQ consumer cursor commit completed.  Replaying such a
  // transaction must not release the same WQE twice.
  bit completion_released;
  rdma_handle routed_qp_h;
  bit mmio_maybe_submitted;
  bit known_no_mmio;

  function new(string name="rdma_queue_pending_operation");
    super.new(name);
    queue_h=null; kind=RDMA_QUEUE_RUNTIME_SQ; producer=0; entry_offset=0;
    cursor=null; next_cursor=null; image=null; request_snapshot=null;
    signaled=0; wr_id=0; completion_index=0; completion_wrap=0;
    completion_target_valid=0; completion_released=0; routed_qp_h=null;
    mmio_maybe_submitted=0; known_no_mmio=0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_queue_pending_operation source;
    uvm_object cloned;
    super.do_copy(rhs);
    if (!$cast(source, rhs)) `uvm_fatal("RDMA_COPY_TYPE", "pending operation copy mismatch");
    if (source.queue_h == null) queue_h = null;
    else begin
      cloned = source.queue_h.clone();
      if (cloned == null || !$cast(queue_h, cloned))
        `uvm_fatal("RDMA_COPY_TYPE", "pending queue handle clone mismatch");
    end
    kind = source.kind;
    producer = source.producer;
    entry_offset = source.entry_offset;
    mmio_maybe_submitted = source.mmio_maybe_submitted;
    known_no_mmio = source.known_no_mmio;
    if (source.cursor == null) cursor = null;
    else begin
      cloned = source.cursor.clone();
      if (cloned == null || !$cast(cursor, cloned))
        `uvm_fatal("RDMA_COPY_TYPE", "pending cursor clone mismatch");
    end
    if (source.next_cursor == null) next_cursor = null;
    else begin
      cloned = source.next_cursor.clone();
      if (cloned == null || !$cast(next_cursor, cloned))
        `uvm_fatal("RDMA_COPY_TYPE", "pending next cursor clone mismatch");
    end
    if (source.image == null) image = null;
    else begin
      cloned = source.image.clone();
      if (cloned == null || !$cast(image, cloned))
        `uvm_fatal("RDMA_COPY_TYPE", "pending image clone mismatch");
    end
    signaled = source.signaled;
    wr_id = source.wr_id;
    completion_index = source.completion_index;
    completion_wrap = source.completion_wrap;
    completion_target_valid = source.completion_target_valid;
    completion_released = source.completion_released;
    if (source.routed_qp_h == null) routed_qp_h = null;
    else begin
      cloned = source.routed_qp_h.clone();
      if (cloned == null || !$cast(routed_qp_h, cloned))
        `uvm_fatal("RDMA_COPY_TYPE", "pending routed QP clone mismatch");
    end
    if (source.request_snapshot == null) request_snapshot = null;
    else begin
      cloned = source.request_snapshot.clone();
      if (cloned == null || !$cast(request_snapshot, cloned))
        `uvm_fatal("RDMA_COPY_TYPE", "pending request clone mismatch");
    end
  endfunction
endclass

class rdma_queue_slot_ledger_entry extends uvm_object;
  `uvm_object_utils(rdma_queue_slot_ledger_entry)
  bit posted;
  bit consumed;
  bit signaled;
  bit [63:0] wr_id;
  int unsigned index;
  bit wrap;
  rdma_semantic_request request_snapshot;
  rdma_hw_image image;
  rdma_status completion_status;

  function new(string name="rdma_queue_slot_ledger_entry"); super.new(name); posted=0; consumed=0; signaled=0; wr_id=0; index=0; wrap=0; request_snapshot=null; image=null; completion_status=null; endfunction
endclass

class rdma_queue_runtime extends uvm_object;
  `uvm_object_utils(rdma_queue_runtime)
  rdma_handle queue_h;
  rdma_queue_runtime_kind_e kind;
  rdma_queue_runtime_state_e state;
  int unsigned depth;
  int unsigned producer_index;
  int unsigned consumer_index;
  bit producer_wrap;
  bit consumer_wrap;
  bit initial_polarity;
  int unsigned used;
  rdma_queue_pending_operation pending_operation;
  protected rdma_queue_slot_ledger_entry slots[];
  protected semaphore lock;
  protected bit recovery_commit_allowed;

  protected function rdma_status acquire_lock();
    if (lock == null || !lock.try_get(1))
      return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                               "queue runtime is busy");
    return rdma_status::success();
  endfunction

  function new(string name="rdma_queue_runtime");
    super.new(name); queue_h=null; kind=RDMA_QUEUE_RUNTIME_SQ; state=RDMA_QUEUE_RUNTIME_DETACHED;
    depth=0; producer_index=0; consumer_index=0; producer_wrap=0; consumer_wrap=0; initial_polarity=0; used=0; pending_operation=null; lock=new(1); recovery_commit_allowed=0;
  endfunction

  function rdma_status configure(rdma_handle qh, rdma_queue_runtime_kind_e k,
                                 int unsigned d, int unsigned pi, bit pw,
                                 int unsigned ci, bit cw, bit host_produced,
                                 bit initial_owner_polarity = 1'b0);
    rdma_status lock_status;
    rdma_handle queue_snapshot;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (qh==null) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"queue handle is null"); end
    if (d==0 || (d & (d-1))!=0) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"queue depth is not a power of two"); end
    if (pi>=d || ci>=d) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"queue cursor is outside depth"); end
    if (!(k inside {RDMA_QUEUE_RUNTIME_SQ,RDMA_QUEUE_RUNTIME_RQ,RDMA_QUEUE_RUNTIME_SRQ,RDMA_QUEUE_RUNTIME_CQ,RDMA_QUEUE_RUNTIME_CEQ,RDMA_QUEUE_RUNTIME_AEQ}))
      begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"queue runtime kind is invalid"); end
    // Keep an immutable identity snapshot.  The lifecycle resource remains
    // authoritative, but callers must not be able to mutate the runtime's
    // generation fence through the handle passed to configure().
    queue_snapshot = rdma_clone_handle_value(qh, "queue runtime handle");
    if (queue_snapshot == null) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "queue runtime handle snapshot failed");
    end
    queue_h=queue_snapshot; kind=k; depth=d; producer_index=pi; producer_wrap=pw; consumer_index=ci; consumer_wrap=cw;
    initial_polarity=initial_owner_polarity;
    used=0; slots=new[d]; foreach(slots[i]) slots[i]=rdma_queue_slot_ledger_entry::type_id::create($sformatf("slot_%0d",i));
    pending_operation=null; recovery_commit_allowed=0; state=RDMA_QUEUE_RUNTIME_ATTACHED; lock.put(1); return rdma_status::success();
  endfunction

  function rdma_status activate();
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (state!=RDMA_QUEUE_RUNTIME_ATTACHED) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_STATE,"queue runtime is not attached"); end
    state=RDMA_QUEUE_RUNTIME_ACTIVE; lock.put(1); return rdma_status::success();
  endfunction

  function rdma_status query_available(output int unsigned value); if(depth==0) begin value=0; return rdma_status::make(RDMA_SC_INVALID_STATE,"runtime is unconfigured"); end value=depth-used; return rdma_status::success(); endfunction

  function int unsigned available_slots(); return depth-used; endfunction

  function rdma_status peek_consumer(output rdma_queue_cursor_snapshot snapshot);
    rdma_status lock_status;
    snapshot = null;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_ACTIVE) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "queue runtime is not active");
    end
    snapshot = rdma_queue_cursor_snapshot::type_id::create("consumer_snapshot");
    snapshot.index = consumer_index;
    snapshot.wrap = consumer_wrap;
    lock.put(1);
    return rdma_status::success();
  endfunction

  function rdma_status commit_consumer(rdma_queue_cursor_snapshot reservation);
    rdma_status lock_status;
    if (reservation == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "consumer reservation is null");
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_ACTIVE &&
        !(recovery_commit_allowed && state == RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED)) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "queue runtime is not active");
    end
    if (reservation.index != consumer_index ||
        reservation.wrap != consumer_wrap) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "consumer reservation is stale");
    end
    cursor_advance(consumer_index, consumer_wrap);
    lock.put(1);
    return rdma_status::success();
  endfunction

  function bit expected_owner_polarity();
    return initial_polarity ^ consumer_wrap;
  endfunction

  function rdma_status validate_queue_handle(rdma_handle qh);
    if (queue_h==null || qh==null) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"queue handle is null");
    if (qh.kind!=queue_h.kind || qh.function_uid!=queue_h.function_uid || qh.object_id!=queue_h.object_id)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"queue handle identity mismatch");
    if (qh.generation!=queue_h.generation) return rdma_status::make(RDMA_SC_STALE_GENERATION,"queue handle generation is stale");
    return rdma_status::success();
  endfunction

  function rdma_status reserve_producer(output rdma_queue_cursor_snapshot reservation);
    rdma_status lock_status;
    reservation=null;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (state!=RDMA_QUEUE_RUNTIME_ACTIVE) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_STATE,"queue runtime is not active"); end
    if (used>=depth) begin lock.put(1); return rdma_status::make(RDMA_SC_QUEUE_FULL,"queue producer ring is full"); end
    reservation=rdma_queue_cursor_snapshot::type_id::create("producer_reservation"); reservation.index=producer_index; reservation.wrap=producer_wrap; lock.put(1); return rdma_status::success();
  endfunction

  function rdma_status commit_producer(rdma_queue_cursor_snapshot reservation, rdma_semantic_request request, longint unsigned wr_id, bit signaled, rdma_hw_image image);
    rdma_queue_slot_ledger_entry slot;
    rdma_semantic_request request_copy;
    rdma_hw_image image_copy;
    uvm_object cloned;
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (reservation==null || reservation.index>=depth) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"producer reservation is invalid"); end
    if (state!=RDMA_QUEUE_RUNTIME_ACTIVE &&
        !(recovery_commit_allowed && state == RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED)) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_STATE,"queue runtime is not active"); end
    if (reservation.index!=producer_index || reservation.wrap!=producer_wrap || used>=depth) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_STATE,"producer reservation is stale"); end
    slot=slots[reservation.index]; if(slot.posted && !slot.consumed) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_STATE,"producer slot is still posted"); end
    if (request != null) begin
      cloned = request.clone();
      if (cloned == null || !$cast(request_copy, cloned)) begin lock.put(1); return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,"producer request snapshot clone failed"); end
    end
    if (image != null) begin
      cloned = image.clone();
      if (cloned == null || !$cast(image_copy, cloned)) begin lock.put(1); return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,"producer image snapshot clone failed"); end
    end
    slot.posted=1; slot.consumed=0; slot.signaled=signaled; slot.wr_id=wr_id; slot.index=reservation.index; slot.wrap=reservation.wrap; slot.request_snapshot=request_copy; slot.image=image_copy; slot.completion_status=null;
    used++; if(producer_index+1>=depth) begin producer_index=0; producer_wrap=~producer_wrap; end else producer_index++;
    lock.put(1);
    return rdma_status::success();
  endfunction

  function bit cursor_equal(int unsigned a, bit aw, int unsigned b, bit bw); return a==b && aw==bw; endfunction

  function void cursor_advance(inout int unsigned i, inout bit w); if(i+1>=depth) begin i=0; w=~w; end else i++; endfunction

  function rdma_status match_and_release(int unsigned target_index, bit target_wrap, output rdma_queue_slot_ledger_entry released[$]);
    int unsigned i; bit w; int unsigned count; bit reached_target;
    rdma_queue_slot_ledger_entry slot;
    rdma_queue_slot_ledger_entry check_slot;
    rdma_status lock_status;
    released.delete();
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if(state!=RDMA_QUEUE_RUNTIME_ACTIVE &&
       !(recovery_commit_allowed && state == RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED)) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_STATE,"queue runtime is not active"); end
    if(target_index>=depth) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"completion index is outside depth"); end
    i=consumer_index; w=consumer_wrap; count=0;
    while (!cursor_equal(i,w,target_index,target_wrap) && count<=depth) begin cursor_advance(i,w); count++; end
    if(count>=depth && !cursor_equal(i,w,target_index,target_wrap)) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_STATE,"completion cursor is not outstanding"); end
    // Validate the complete release range before mutating any slot. A
    // malformed completion therefore cannot partially advance CI/credits.
    count=0; i=consumer_index; w=consumer_wrap;
    do begin
      check_slot=slots[i];
      if(check_slot==null || !check_slot.posted || check_slot.consumed || check_slot.index!=i || check_slot.wrap!=w) begin lock.put(1); released.delete(); return rdma_status::make(RDMA_SC_INVALID_STATE,"completion skips an unposted slot"); end
      reached_target=cursor_equal(i,w,target_index,target_wrap);
      cursor_advance(i,w); count++;
      if (reached_target) break;
    end while (count<=depth);
    count=0; i=consumer_index; w=consumer_wrap;
    do begin
      slot=slots[i];
      reached_target=cursor_equal(i,w,target_index,target_wrap);
      slot.consumed=1; slot.posted=0; released.push_back(slot); if(used>0) used--; cursor_advance(i,w); count++;
      if (reached_target) break;
    end while (count<=depth);
    consumer_index=i; consumer_wrap=w; lock.put(1); return rdma_status::success();
  endfunction

  // Validate a completion cursor without consuming any slot.  The data-plane
  // engine uses this before issuing the CQ consumer doorbell so a failed MMIO
  // transaction cannot silently release producer credits.
  function rdma_status validate_release_range(
    int unsigned target_index, bit target_wrap
  );
    int unsigned i;
    bit w;
    int unsigned count;
    bit reached_target;
    rdma_queue_slot_ledger_entry slot;
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_ACTIVE) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "queue runtime is not active");
    end
    if (target_index >= depth) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "completion index is outside depth");
    end
    i = consumer_index;
    w = consumer_wrap;
    count = 0;
    while (!cursor_equal(i, w, target_index, target_wrap) && count <= depth) begin
      cursor_advance(i, w);
      count++;
    end
    if (count >= depth && !cursor_equal(i, w, target_index, target_wrap)) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "completion cursor is not outstanding");
    end
    count = 0;
    i = consumer_index;
    w = consumer_wrap;
    do begin
      slot = slots[i];
      if (slot == null || !slot.posted || slot.consumed ||
          slot.index != i || slot.wrap != w) begin
        lock.put(1);
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "completion skips an unposted slot");
      end
      reached_target = cursor_equal(i, w, target_index, target_wrap);
      cursor_advance(i, w);
      count++;
      if (reached_target) break;
    end while (count <= depth);
    lock.put(1);
    return rdma_status::success();
  endfunction

  function rdma_status enter_recovery(rdma_queue_pending_operation operation, bit mmio_maybe_submitted);
    rdma_status lock_status;
    rdma_queue_pending_operation copy;
    uvm_object cloned;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if(state!=RDMA_QUEUE_RUNTIME_ACTIVE || operation==null) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_STATE,"queue runtime cannot enter recovery"); end
    cloned = operation.clone();
    if (cloned == null || !$cast(copy, cloned)) begin lock.put(1); return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,"pending operation clone failed"); end
    // Derive and retain the post-operation cursor while the ring geometry is
    // still protected by this runtime lock.  Recovery therefore does not
    // depend on a mutable caller-side cursor or on a later geometry lookup.
    if (copy.next_cursor == null && copy.cursor != null && depth != 0 &&
        copy.cursor.index < depth) begin
      copy.next_cursor = rdma_queue_cursor_snapshot::type_id::create(
        "pending_next_cursor");
      copy.next_cursor.index = copy.cursor.index;
      copy.next_cursor.wrap = copy.cursor.wrap;
      cursor_advance(copy.next_cursor.index, copy.next_cursor.wrap);
    end
    pending_operation=copy; pending_operation.mmio_maybe_submitted=mmio_maybe_submitted; pending_operation.known_no_mmio=!mmio_maybe_submitted; state=RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED; lock.put(1); return rdma_status::success();
  endfunction

  // Recovery execution is owned by rdma_queue_data_engine.  These helpers
  // only commit the state transition once that engine has completed the
  // replay, or preserve the evidence when replay itself fails.
  function rdma_status complete_recovery_retry();
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED ||
        pending_operation == null) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "queue runtime has no pending recovery");
    end
    pending_operation = null;
    recovery_commit_allowed = 1'b0;
    state = RDMA_QUEUE_RUNTIME_ACTIVE;
    lock.put(1);
    return rdma_status::success();
  endfunction

  function rdma_status record_recovery_failure(bit mmio_maybe_submitted);
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED ||
        pending_operation == null) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "queue runtime has no pending recovery");
    end
    pending_operation.mmio_maybe_submitted = mmio_maybe_submitted;
    pending_operation.known_no_mmio = !mmio_maybe_submitted;
    recovery_commit_allowed = 1'b0;
    lock.put(1);
    return rdma_status::success();
  endfunction

  function rdma_status abort_recovery();
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED ||
        pending_operation == null) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "queue runtime has no pending recovery");
    end
    pending_operation = null;
    recovery_commit_allowed = 1'b0;
    state = RDMA_QUEUE_RUNTIME_DETACHED;
    lock.put(1);
    return rdma_status::success();
  endfunction

  function rdma_status enable_recovery_commit();
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED ||
        pending_operation == null) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "queue runtime has no pending recovery");
    end
    recovery_commit_allowed = 1'b1;
    lock.put(1);
    return rdma_status::success();
  endfunction

  // Return a detached copy of the pending transaction.  Recovery callers use
  // this to audit the exact cursor/image evidence without obtaining a handle
  // into mutable runtime state.
  function rdma_status snapshot_pending(
    output rdma_queue_pending_operation snapshot
  );
    rdma_status lock_status;
    uvm_object cloned;
    snapshot = null;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED ||
        pending_operation == null) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "queue runtime has no pending recovery");
    end
    cloned = pending_operation.clone();
    if (cloned == null || !$cast(snapshot, cloned)) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "pending recovery snapshot clone failed");
    end
    lock.put(1);
    return rdma_status::success();
  endfunction

  function rdma_status recover(rdma_queue_recovery_action_e action, bit caller_confirmed_no_submit=1'b0);
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if(state!=RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED || pending_operation==null) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_STATE,"queue runtime has no pending recovery"); end
    if(action==RDMA_QUEUE_RECOVERY_RETRY_PENDING) begin
      if(pending_operation.mmio_maybe_submitted) begin lock.put(1); return rdma_status::make(RDMA_SC_RECOVERY_REQUIRED,"pending MMIO outcome is ambiguous"); end
      if(!caller_confirmed_no_submit) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"retry requires caller confirmation"); end
      state=RDMA_QUEUE_RUNTIME_ACTIVE; lock.put(1); return rdma_status::success();
    end
    if(action==RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH) begin state=RDMA_QUEUE_RUNTIME_DETACHED; lock.put(1); return rdma_status::success(); end
    lock.put(1); return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"recovery action is invalid");
  endfunction
endclass
