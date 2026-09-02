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
endclass

class rdma_queue_pending_operation extends uvm_object;
  `uvm_object_utils(rdma_queue_pending_operation)
  rdma_queue_cursor_snapshot cursor;
  bit mmio_maybe_submitted;
  bit known_no_mmio;
  function new(string name="rdma_queue_pending_operation"); super.new(name); cursor=null; mmio_maybe_submitted=0; known_no_mmio=0; endfunction
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
  int unsigned used;
  rdma_queue_pending_operation pending_operation;
  protected rdma_queue_slot_ledger_entry slots[];
  protected semaphore lock;

  function new(string name="rdma_queue_runtime");
    super.new(name); queue_h=null; kind=RDMA_QUEUE_RUNTIME_SQ; state=RDMA_QUEUE_RUNTIME_DETACHED;
    depth=0; producer_index=0; consumer_index=0; producer_wrap=0; consumer_wrap=0; used=0; pending_operation=null; lock=new(1);
  endfunction

  function rdma_status configure(rdma_handle qh, rdma_queue_runtime_kind_e k,
                                 int unsigned d, int unsigned pi, bit pw,
                                 int unsigned ci, bit cw, bit host_produced);
    if (qh==null) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"queue handle is null");
    if (d==0 || (d & (d-1))!=0) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"queue depth is not a power of two");
    if (pi>=d || ci>=d) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"queue cursor is outside depth");
    if (!(k inside {RDMA_QUEUE_RUNTIME_SQ,RDMA_QUEUE_RUNTIME_RQ,RDMA_QUEUE_RUNTIME_SRQ,RDMA_QUEUE_RUNTIME_CQ,RDMA_QUEUE_RUNTIME_CEQ,RDMA_QUEUE_RUNTIME_AEQ}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"queue runtime kind is invalid");
    queue_h=qh; kind=k; depth=d; producer_index=pi; producer_wrap=pw; consumer_index=ci; consumer_wrap=cw;
    used=0; slots=new[d]; foreach(slots[i]) slots[i]=rdma_queue_slot_ledger_entry::type_id::create($sformatf("slot_%0d",i));
    pending_operation=null; state=RDMA_QUEUE_RUNTIME_ATTACHED; return rdma_status::success();
  endfunction

  function rdma_status activate();
    if (state!=RDMA_QUEUE_RUNTIME_ATTACHED) return rdma_status::make(RDMA_SC_INVALID_STATE,"queue runtime is not attached");
    state=RDMA_QUEUE_RUNTIME_ACTIVE; return rdma_status::success();
  endfunction
  function rdma_status query_available(output int unsigned value); if(depth==0) begin value=0; return rdma_status::make(RDMA_SC_INVALID_STATE,"runtime is unconfigured"); end value=depth-used; return rdma_status::success(); endfunction
  function int unsigned available_slots(); return depth-used; endfunction

  function rdma_status validate_queue_handle(rdma_handle qh);
    if (queue_h==null || qh==null) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"queue handle is null");
    if (qh.kind!=queue_h.kind || qh.function_uid!=queue_h.function_uid || qh.object_id!=queue_h.object_id)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"queue handle identity mismatch");
    if (qh.generation!=queue_h.generation) return rdma_status::make(RDMA_SC_STALE_GENERATION,"queue handle generation is stale");
    return rdma_status::success();
  endfunction

  function rdma_status reserve_producer(output rdma_queue_cursor_snapshot reservation);
    reservation=null;
    if (state!=RDMA_QUEUE_RUNTIME_ACTIVE) return rdma_status::make(RDMA_SC_INVALID_STATE,"queue runtime is not active");
    if (used>=depth) return rdma_status::make(RDMA_SC_QUEUE_FULL,"queue producer ring is full");
    reservation=rdma_queue_cursor_snapshot::type_id::create("producer_reservation"); reservation.index=producer_index; reservation.wrap=producer_wrap; return rdma_status::success();
  endfunction

  function rdma_status commit_producer(rdma_queue_cursor_snapshot reservation, rdma_semantic_request request, longint unsigned wr_id, bit signaled, rdma_hw_image image);
    rdma_queue_slot_ledger_entry slot;
    if (reservation==null || reservation.index>=depth) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"producer reservation is invalid");
    if (state!=RDMA_QUEUE_RUNTIME_ACTIVE) return rdma_status::make(RDMA_SC_INVALID_STATE,"queue runtime is not active");
    if (reservation.index!=producer_index || reservation.wrap!=producer_wrap || used>=depth) return rdma_status::make(RDMA_SC_INVALID_STATE,"producer reservation is stale");
    slot=slots[reservation.index]; if(slot.posted && !slot.consumed) return rdma_status::make(RDMA_SC_INVALID_STATE,"producer slot is still posted");
    slot.posted=1; slot.consumed=0; slot.signaled=signaled; slot.wr_id=wr_id; slot.index=reservation.index; slot.wrap=reservation.wrap; slot.request_snapshot=request; slot.image=image; slot.completion_status=null;
    used++; if(producer_index+1>=depth) begin producer_index=0; producer_wrap=~producer_wrap; end else producer_index++;
    return rdma_status::success();
  endfunction

  function bit cursor_equal(int unsigned a, bit aw, int unsigned b, bit bw); return a==b && aw==bw; endfunction
  function void cursor_advance(inout int unsigned i, inout bit w); if(i+1>=depth) begin i=0; w=~w; end else i++; endfunction

  function rdma_status match_and_release(int unsigned target_index, bit target_wrap, output rdma_queue_slot_ledger_entry released[$]);
    int unsigned i; bit w; int unsigned count; bit reached_target;
    rdma_queue_slot_ledger_entry slot;
    released.delete();
    if(state!=RDMA_QUEUE_RUNTIME_ACTIVE) return rdma_status::make(RDMA_SC_INVALID_STATE,"queue runtime is not active");
    if(target_index>=depth) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"completion index is outside depth");
    i=consumer_index; w=consumer_wrap; count=0;
    while (!cursor_equal(i,w,target_index,target_wrap) && count<=depth) begin cursor_advance(i,w); count++; end
    if(count>=depth && !cursor_equal(i,w,target_index,target_wrap)) return rdma_status::make(RDMA_SC_INVALID_STATE,"completion cursor is not outstanding");
    count=0; i=consumer_index; w=consumer_wrap;
    do begin
      slot=slots[i]; if(slot==null || !slot.posted || slot.consumed || slot.index!=i || slot.wrap!=w) begin released.delete(); return rdma_status::make(RDMA_SC_INVALID_STATE,"completion skips an unposted slot"); end
      reached_target=cursor_equal(i,w,target_index,target_wrap);
      slot.consumed=1; slot.posted=0; released.push_back(slot); if(used>0) used--; cursor_advance(i,w); count++;
      if (reached_target) break;
    end while (count<=depth);
    consumer_index=i; consumer_wrap=w; return rdma_status::success();
  endfunction

  function rdma_status enter_recovery(rdma_queue_pending_operation operation, bit mmio_maybe_submitted);
    if(state!=RDMA_QUEUE_RUNTIME_ACTIVE || operation==null) return rdma_status::make(RDMA_SC_INVALID_STATE,"queue runtime cannot enter recovery");
    pending_operation=operation; pending_operation.mmio_maybe_submitted=mmio_maybe_submitted; pending_operation.known_no_mmio=!mmio_maybe_submitted; state=RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED; return rdma_status::success();
  endfunction
  function rdma_status recover(rdma_queue_recovery_action_e action, bit caller_confirmed_no_submit=1'b0);
    if(state!=RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED || pending_operation==null) return rdma_status::make(RDMA_SC_INVALID_STATE,"queue runtime has no pending recovery");
    if(action==RDMA_QUEUE_RECOVERY_RETRY_PENDING) begin
      if(pending_operation.mmio_maybe_submitted) return rdma_status::make(RDMA_SC_RECOVERY_REQUIRED,"pending MMIO outcome is ambiguous");
      if(!caller_confirmed_no_submit) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"retry requires caller confirmation");
      state=RDMA_QUEUE_RUNTIME_ACTIVE; return rdma_status::success();
    end
    if(action==RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH) begin state=RDMA_QUEUE_RUNTIME_DETACHED; return rdma_status::success(); end
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"recovery action is invalid");
  endfunction
endclass
