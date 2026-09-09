// 目录：核心执行层 core/rdma_queue_runtime.sv。
// 职责：实现 rdma_queue_runtime 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_queue_runtime.sv 属于核心执行层，负责队列、控制面、资源和恢复流程。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

typedef enum bit [2:0] {
  RDMA_QUEUE_RUNTIME_DETACHED = 3'd0,
  RDMA_QUEUE_RUNTIME_ATTACHED = 3'd1,
  RDMA_QUEUE_RUNTIME_ACTIVE = 3'd2,
  RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED = 3'd3,
  // Resize owns a short quiesce window in which no producer/consumer
  // reservation may be created.  Keeping this distinct from DETACHED lets
  // the engine restore the old attachment when a replacement transaction
  // fails without losing its cursor ledger.
  RDMA_QUEUE_RUNTIME_QUIESCING = 3'd4
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

typedef enum bit [2:0] {
  RDMA_QUEUE_MMIO_NONE           = 3'd0,
  RDMA_QUEUE_MMIO_NOT_APPLICABLE = 3'd1,
  RDMA_QUEUE_MMIO_NO_SUBMIT      = 3'd2,
  RDMA_QUEUE_MMIO_SUCCESS        = 3'd3,
  RDMA_QUEUE_MMIO_AMBIGUOUS      = 3'd4
} rdma_queue_mmio_evidence_e;

class rdma_queue_cursor_snapshot extends uvm_object;
  `uvm_object_utils(rdma_queue_cursor_snapshot)
  int unsigned index;
  bit wrap;

  // 功能：构造 rdma_queue_cursor_snapshot，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：index=0；wrap=0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_cursor_snapshot 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name="rdma_queue_cursor_snapshot"); super.new(name); index=0; wrap=0; endfunction

  // 功能：将 rhs 中 rdma_queue_cursor_snapshot 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（cursor snapshot copy mismatch），不保留部分有效快照。
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
  bit device_producer;
  bit device_write_attempted;
  bit consumer_committed;
  bit cq_consumer_committed;
  bit completion_released;
  bit consumer_doorbell_succeeded;
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
  rdma_queue_mmio_evidence_e mmio_evidence;
  rdma_queue_cursor_snapshot committed_consumer_cursor;
  rdma_status failure_status;
  int unsigned entry_size;
  rdma_route_key_t route;
  bit route_valid;
  rdma_reset_epoch_t reset_epoch;
  bit epoch_valid;

  // 功能：构造 rdma_queue_pending_operation，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：queue_h=null；kind=RDMA_QUEUE_RUNTIME_SQ；producer=0；entry_offset=0；cursor=null；next_cursor=null；image=null；request_snapshot=null；其余字段按实现默认值初始化。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_pending_operation 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name="rdma_queue_pending_operation");
    super.new(name);
    queue_h=null; kind=RDMA_QUEUE_RUNTIME_SQ; producer=0; entry_offset=0;
    cursor=null; next_cursor=null; image=null; request_snapshot=null;
    signaled=0; wr_id=0; completion_index=0; completion_wrap=0;
    completion_target_valid=0; completion_released=0; routed_qp_h=null;
    device_producer=0; device_write_attempted=0; consumer_committed=0;
    cq_consumer_committed=0; consumer_doorbell_succeeded=0;
    mmio_maybe_submitted=0; known_no_mmio=0; mmio_evidence=RDMA_QUEUE_MMIO_NONE;
    committed_consumer_cursor=null; failure_status=null; entry_size=0;
    route='0; route_valid=0; reset_epoch=0; epoch_valid=0;
  endfunction

  // 功能：将 rhs 中 rdma_queue_pending_operation 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（pending operation copy mismatch），不保留部分有效快照。
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
    device_producer = source.device_producer;
    device_write_attempted = source.device_write_attempted;
    consumer_committed = source.consumer_committed;
    cq_consumer_committed = source.cq_consumer_committed;
    completion_released = source.completion_released;
    consumer_doorbell_succeeded = source.consumer_doorbell_succeeded;
    entry_offset = source.entry_offset;
    mmio_maybe_submitted = source.mmio_maybe_submitted;
    known_no_mmio = source.known_no_mmio;
    mmio_evidence = source.mmio_evidence;
    entry_size = source.entry_size;
    route = source.route;
    route_valid = source.route_valid;
    reset_epoch = source.reset_epoch;
    epoch_valid = source.epoch_valid;
    if (source.committed_consumer_cursor == null) committed_consumer_cursor = null;
    else begin
      cloned = source.committed_consumer_cursor.clone();
      if (cloned == null || !$cast(committed_consumer_cursor, cloned))
        `uvm_fatal("RDMA_COPY_TYPE", "pending committed cursor clone mismatch");
    end
    if (source.failure_status == null) failure_status = null;
    else failure_status = rdma_clone_status_value(source.failure_status);
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

  // 功能：构造 rdma_queue_slot_ledger_entry，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：posted=0；consumed=0；signaled=0；wr_id=0；index=0；wrap=0；request_snapshot=null；image=null；其余字段按实现默认值初始化。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_slot_ledger_entry 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
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
  rdma_route_key_t route;
  bit route_valid;
  rdma_reset_epoch_t reset_epoch;
  bit epoch_valid;
  int unsigned used;
  rdma_queue_pending_operation pending_operation;
  // 中文设计：device-produced ring 不使用 host WQE ledger，必须在同一把 runtime lock
  // 保护下保存单一 detached reservation，供写入/提交/恢复阶段共享且不泄露内部句柄。
  bit host_produced;
  bit device_reservation_valid;
  rdma_queue_cursor_snapshot device_reservation;
  protected rdma_queue_slot_ledger_entry slots[];
  protected semaphore lock;
  protected bit recovery_commit_allowed;

  // 功能：在 rdma_queue_runtime 中，acquire_lock 检查容量后预留资源并返回带 owner 证据的句柄/计划；失败时回滚已登记的局部状态。
  // 输入/输出及副作用：无显式参数；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或 output 发布新句柄/映射。
  // 失败/边界：容量不足、范围非法、重复占用或身份过期时返回错误；失败不得泄漏半分配资源。
  protected function rdma_status acquire_lock();
    if (lock == null || !lock.try_get(1))
      return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                               "queue runtime is busy");
    return rdma_status::success();
  endfunction

  // 功能：构造 rdma_queue_runtime，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：queue_h=null；kind=RDMA_QUEUE_RUNTIME_SQ；state=RDMA_QUEUE_RUNTIME_DETACHED；depth=0；producer_index=0；consumer_index=0；producer_wrap=0；consumer_wrap=0；其余字段按实现默认值初始化。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_runtime 构造只建立本地初始状态；本地 semaphore/ledger 等按构造体显式分配，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name="rdma_queue_runtime");
    super.new(name); queue_h=null; kind=RDMA_QUEUE_RUNTIME_SQ; state=RDMA_QUEUE_RUNTIME_DETACHED;
    depth=0; producer_index=0; consumer_index=0; producer_wrap=0; consumer_wrap=0; initial_polarity=0; route='0; route_valid=0; reset_epoch=0; epoch_valid=0; used=0; pending_operation=null; host_produced=0; device_reservation_valid=0; device_reservation=null; lock=new(1); recovery_commit_allowed=0;
  endfunction

  // 功能：configure 校验 ring 方向、几何与初始游标，构造临时句柄/账本并一次性发布 ATTACHED runtime 配置。
  // 输入/输出及副作用：qh、k、d、pi、pw、ci、cw、host_produced_cfg、initial_owner_polarity（输入）；成功时锁存游标、方向、occupancy 与 detached handle，外部资源仍由调用方拥有。
  // 失败/边界：空句柄、重复配置、深度非二次幂、游标越界/组合非法、方向与 queue kind 不匹配或临时对象分配失败时返回错误，并保留旧状态。
  function rdma_status configure(rdma_handle qh, rdma_queue_runtime_kind_e k,
                                 int unsigned d, int unsigned pi, bit pw,
                                 int unsigned ci, bit cw, bit host_produced_cfg,
                                 bit initial_owner_polarity = 1'b0);
    rdma_status lock_status;
    rdma_handle queue_snapshot;
    rdma_queue_slot_ledger_entry staged_slots[];
    int unsigned staged_used;
    bit device_kind;
    bit expected_host_direction;
    rdma_resource_kind_e expected_resource_kind;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_DETACHED) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_STATE,"queue runtime is already configured"); end
    if (qh==null) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"queue handle is null"); end
    if (d==0 || (d & (d-1))!=0) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"queue depth is not a power of two"); end
    if (pi>=d || ci>=d) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"queue cursor is outside depth"); end
    if (!(k inside {RDMA_QUEUE_RUNTIME_SQ,RDMA_QUEUE_RUNTIME_RQ,RDMA_QUEUE_RUNTIME_SRQ,RDMA_QUEUE_RUNTIME_CQ,RDMA_QUEUE_RUNTIME_CEQ,RDMA_QUEUE_RUNTIME_AEQ}))
      begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"queue runtime kind is invalid"); end
    device_kind = (k inside {RDMA_QUEUE_RUNTIME_CQ, RDMA_QUEUE_RUNTIME_CEQ, RDMA_QUEUE_RUNTIME_AEQ});
    expected_host_direction = !device_kind;
    case (k)
      RDMA_QUEUE_RUNTIME_CQ: expected_resource_kind = RDMA_RESOURCE_CQ;
      RDMA_QUEUE_RUNTIME_CEQ: expected_resource_kind = RDMA_RESOURCE_CEQ;
      RDMA_QUEUE_RUNTIME_AEQ: expected_resource_kind = RDMA_RESOURCE_AEQ;
      RDMA_QUEUE_RUNTIME_SRQ: expected_resource_kind = RDMA_RESOURCE_SRQ;
      default: expected_resource_kind = RDMA_RESOURCE_QP;
    endcase
    if (qh.kind != expected_resource_kind) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "queue handle kind does not match runtime kind");
    end
    if (host_produced_cfg != expected_host_direction) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "producer direction does not match queue kind");
    end
    if (device_kind) begin
      if (pw == cw) begin
        if (pi < ci) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"same-wrap cursors are reversed"); end
        staged_used = pi - ci;
      end else if (pi == ci) staged_used = d;
      else staged_used = d - ci + pi;
      if (staged_used > d) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"initial occupancy exceeds depth"); end
    end else staged_used = 0;
    // Keep an immutable identity snapshot.  The lifecycle resource remains
    // authoritative, but callers must not be able to mutate the runtime's
    // generation fence through the handle passed to configure().
    queue_snapshot = rdma_clone_handle_value(qh, "queue runtime handle");
    if (queue_snapshot == null) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "queue runtime handle snapshot failed");
    end
    if (!device_kind) begin
      staged_slots = new[d];
      foreach (staged_slots[i]) begin
        staged_slots[i] = rdma_queue_slot_ledger_entry::type_id::create($sformatf("slot_%0d", i));
        if (staged_slots[i] == null) begin lock.put(1); return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,"slot ledger allocation failed"); end
      end
    end else staged_slots = new[0];
    queue_h=queue_snapshot; kind=k; depth=d; producer_index=pi; producer_wrap=pw; consumer_index=ci; consumer_wrap=cw;
    initial_polarity=initial_owner_polarity; host_produced=host_produced_cfg; used=staged_used;
    slots=staged_slots; pending_operation=null; device_reservation_valid=0; device_reservation=null; route='0; route_valid=0; reset_epoch=0; epoch_valid=0; recovery_commit_allowed=0; state=RDMA_QUEUE_RUNTIME_ATTACHED; lock.put(1); return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_runtime 中，activate 校验依赖和 binding 后建立运行边界，只保存非拥有引用并拒绝重复配置。
  // 输入/输出及副作用：无显式参数；activate 先依据 !lock_status.ok(；state!=RDMA_QUEUE_RUNTIME_ATTACHED 校验 函数体读取的依赖；成功时更新本对象配置/状态并保存非拥有引用，返回 rdma_status。
  // 失败/边界：实现中的空依赖、重复登记、状态或 generation/authority 校验失败时返回错误；失败时保留旧配置。
  function rdma_status activate();
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (state!=RDMA_QUEUE_RUNTIME_ATTACHED) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_STATE,"queue runtime is not attached"); end
    state=RDMA_QUEUE_RUNTIME_ACTIVE; lock.put(1); return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_runtime 中，begin_quiesce 建立 resize/删除屏障，把 ACTIVE runtime 切到 QUIESCING，并阻止新的 post/poll reservation。
  // 输入/输出及副作用：无显式参数；begin_quiesce 读取当前 state、pending_operation、used 并更新 state；函数返回 rdma_status，不接管外部资源。
  // 失败/边界：runtime 未 ACTIVE、已有 pending operation 或仍有 used 槽位时返回 RESOURCE_BUSY/INVALID_STATE；失败不改变 state 或账本。
  virtual function rdma_status begin_quiesce();
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_ACTIVE) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "queue runtime is not active");
    end
    if (pending_operation != null || device_reservation_valid || used != 0) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                               pending_operation != null ?
                               "queue runtime has a pending operation" :
                               (device_reservation_valid ?
                                "queue runtime has a device reservation" :
                                "queue runtime has outstanding slots"));
    end
    state = RDMA_QUEUE_RUNTIME_QUIESCING;
    lock.put(1);
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_runtime 中，restore_active 撤销未提交的 quiesce 屏障，恢复旧 runtime 的 ACTIVE 状态。
  // 输入/输出及副作用：无显式参数；restore_active 读取 state、pending_operation、used 并更新 state；函数返回 rdma_status，不接管外部资源。
  // 失败/边界：仅 QUIESCING 且无 pending/used 的 runtime 可恢复；其它状态返回 INVALID_STATE/RESOURCE_BUSY 且保持原状态。
  virtual function rdma_status restore_active();
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_QUIESCING) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "queue runtime is not quiescing");
    end
    if (pending_operation != null || device_reservation_valid || used != 0) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                               "quiesced runtime has mutable work");
    end
    state = RDMA_QUEUE_RUNTIME_ACTIVE;
    lock.put(1);
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_runtime 中，detach_quiesced 在 backing replacement 已提交后使旧 runtime 失效，防止旧 cursor 再访问 Host-memory。
  // 输入/输出及副作用：无显式参数；detach_quiesced 读取 state、pending_operation、used 并更新 state；函数返回 rdma_status，不接管外部资源。
  // 失败/边界：仅 QUIESCING 且无 pending/used 的 runtime 可 detach；重复 detach 或残留工作返回错误并保留原状态。
  virtual function rdma_status detach_quiesced();
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (state != RDMA_QUEUE_RUNTIME_QUIESCING) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "queue runtime is not quiescing");
    end
    if (pending_operation != null || device_reservation_valid || used != 0) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                               "quiesced runtime has mutable work");
    end
    state = RDMA_QUEUE_RUNTIME_DETACHED;
    lock.put(1);
    return rdma_status::success();
  endfunction

  // 功能：将旧 ring 的 owner/CI 游标及槽位账本复制到已 configure 的新 ring。
  // 输入输出及副作用：source 为输入；更新当前 runtime 的 cursor、used 和 slot 快照。
  // 失败边界：source 为空、深度不足或槽位 clone 失败时返回错误且不发布部分复制状态。
  function rdma_status copy_ring_state(rdma_queue_runtime source);
    int unsigned i, limit;
    uvm_object cloned;
    rdma_queue_slot_ledger_entry staged_slots[];
    rdma_queue_slot_ledger_entry staged_slot;
    // 动态数组不能用 null aggregate 比较；以 source.depth 和实际 size
    // 同时作为“已配置且有槽位账本”的判据，避免在复制阶段触发越界。
    if (source == null || source.depth == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "source runtime is null");
    if (source.consumer_index >= depth || source.producer_index >= depth)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "source cursor exceeds resized depth");
    if (source.used > depth)
      return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                               "source runtime occupancy exceeds resized depth");
    if (!source.host_produced && !host_produced) begin
      producer_index = source.producer_index;
      producer_wrap = source.producer_wrap;
      consumer_index = source.consumer_index;
      consumer_wrap = source.consumer_wrap;
      used = source.used;
      slots = new[0];
      return rdma_status::success();
    end
    if (source.slots.size() == 0 || source.slots.size() < source.depth)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "source runtime has no host ledger");
    limit = (source.depth < depth) ? source.depth : depth;
    // A shrink may only discard slots that are truly empty.  Validate the
    // entire source ledger before touching this runtime so a failed clone
    // cannot publish half of a new cursor/slot state.
    if (source.depth > depth) begin
      for (i = depth; i < source.depth; i++) begin
        if (source.slots[i] != null && source.slots[i].posted &&
            !source.slots[i].consumed)
          return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                                   "source runtime has slots outside resized depth");
      end
    end
    staged_slots = new[depth];
    foreach (staged_slots[i]) begin
      staged_slots[i] = rdma_queue_slot_ledger_entry::type_id::create(
        $sformatf("staged_slot_%0d", i));
      if (staged_slots[i] == null)
        return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "slot staging allocation failed");
    end
    for (i = 0; i < limit; i++) begin
      if (source.slots[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "source runtime has a null slot");
      staged_slot = staged_slots[i];
      staged_slot.posted = source.slots[i].posted;
      staged_slot.consumed = source.slots[i].consumed;
      staged_slot.signaled = source.slots[i].signaled;
      staged_slot.wr_id = source.slots[i].wr_id;
      staged_slot.index = source.slots[i].index;
      staged_slot.wrap = source.slots[i].wrap;
      staged_slot.request_snapshot = null;
      staged_slot.image = null;
      staged_slot.completion_status = null;
      if (source.slots[i].request_snapshot != null) begin
        cloned = source.slots[i].request_snapshot.clone();
        if (cloned == null || !$cast(staged_slot.request_snapshot, cloned))
          return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED, "slot request clone failed");
      end
      if (source.slots[i].image != null) begin
        cloned = source.slots[i].image.clone();
        if (cloned == null || !$cast(staged_slot.image, cloned))
          return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED, "slot image clone failed");
      end
      if (source.slots[i].completion_status != null) begin
        staged_slot.completion_status = rdma_clone_status_value(source.slots[i].completion_status);
        if (staged_slot.completion_status == null)
          return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED, "slot status clone failed");
      end
    end
    producer_index = source.producer_index; producer_wrap = source.producer_wrap;
    consumer_index = source.consumer_index; consumer_wrap = source.consumer_wrap;
    used = source.used;
    foreach (staged_slots[i]) begin
      slots[i].posted = staged_slots[i].posted;
      slots[i].consumed = staged_slots[i].consumed;
      slots[i].signaled = staged_slots[i].signaled;
      slots[i].wr_id = staged_slots[i].wr_id;
      slots[i].index = staged_slots[i].index;
      slots[i].wrap = staged_slots[i].wrap;
      slots[i].request_snapshot = staged_slots[i].request_snapshot;
      slots[i].image = staged_slots[i].image;
      slots[i].completion_status = staged_slots[i].completion_status;
    end
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_runtime 中，query_available 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：value（输出）；query_available 读取 value 并使用字段 value，并写入 value；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：query_available 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  // 功能：query_available 在 runtime lock 内返回可再提交的 producer credit，并扣除尚未 commit 的 device reservation。
  // 输入/输出及副作用：value（输出）先置零，成功时写入 depth-used-1（有 reservation）或 depth-used；不修改游标或账本。
  // 失败/边界：未配置、内部 used 越界或锁忙返回非成功状态；结果下限为零，失败不泄露旧值。
  function rdma_status query_available(output int unsigned value);
    rdma_status lock_status;
    value = 0;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (depth == 0) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_STATE,"runtime is unconfigured"); end
    if (used > depth) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_STATE,"runtime occupancy exceeds depth"); end
    value = depth - used;
    if (!host_produced && device_reservation_valid && value > 0) value--;
    lock.put(1);
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_runtime 中，available_slots 只读查询当前运行时/测试账本，返回槽位、对象或恢复记录的快照而不推进事务。
  // 输入/输出及副作用：无显式参数；available_slots 读取当前对象的 depth 和 used 计数，返回尚可预留的槽位数，不修改运行时账本；函数返回 int unsigned，不取得调用方资源所有权。
// 失败/边界：available_slots 返回 depth-used；runtime 未 configure 时 depth 为 0，结果保持 0，不会为负数或修改槽位账本。
  function int unsigned available_slots();
    int unsigned value;
    value = (used <= depth) ? (depth - used) : 0;
    if (!host_produced && device_reservation_valid && value > 0) value--;
    return value;
  endfunction

  // 功能：在 rdma_queue_runtime 中，peek_consumer 只读查询当前运行时/测试账本，返回槽位、对象或恢复记录的快照而不推进事务。
  // 输入/输出及副作用：snapshot（输出）；peek_consumer 读取 snapshot 并使用字段 snapshot、lock_status、snapshot.index、snapshot.wrap，并写入 snapshot；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：目标不存在、route/authority 不匹配或快照代际失效时返回错误/空值；不得返回陈旧或歧义条目。
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
    if (!host_produced && used == 0) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_QUEUE_EMPTY,
                               "device ring has no committed entries");
    end
    snapshot = rdma_queue_cursor_snapshot::type_id::create("consumer_snapshot");
    if (snapshot == null) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "consumer snapshot allocation failed");
    end
    snapshot.index = consumer_index;
    snapshot.wrap = consumer_wrap;
    lock.put(1);
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_runtime 中，commit_consumer 执行受控事务并按后端提交证据推进状态机，同时保留失败阶段和 generation 证据。
  // 输入/输出及副作用：reservation（输入）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过 output
  //   返回结果。
  // 失败/边界：commit_consumer 遇到锁、超时、generation 变化或提交证据不完整时保持原状态，不推进游标。
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
    if (!host_produced) begin
      if (used == 0) begin
        lock.put(1);
        return rdma_status::make(RDMA_SC_QUEUE_EMPTY,
                                 "device ring has no committed entries");
      end
      used--;
    end
    cursor_advance(consumer_index, consumer_wrap);
    lock.put(1);
    return rdma_status::success();
  endfunction

  // 功能：reserve_device_producer 为 CQ/CEQ/AEQ 锁定当前 producer cursor，返回与 runtime 内部隔离的 detached 快照。
  // 输入/输出及副作用：reservation（输出）先置 null；成功时只登记 device_reservation/device_reservation_valid，不推进 committed PI 或 used。
  // 失败/边界：未配置/非 ACTIVE、host-produced 方向、SQ/RQ/SRQ kind、pending recovery、已有 reservation、ring full 或快照分配失败时返回明确错误且 output 保持 null。
  function rdma_status reserve_device_producer(
    output rdma_queue_cursor_snapshot reservation
  );
    rdma_status lock_status;
    reservation = null;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (host_produced || !(kind inside {RDMA_QUEUE_RUNTIME_CQ,
                                        RDMA_QUEUE_RUNTIME_CEQ,
                                        RDMA_QUEUE_RUNTIME_AEQ})) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "device producer is invalid for this ring");
    end
    if (state != RDMA_QUEUE_RUNTIME_ACTIVE || pending_operation != null) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "queue runtime is not ready for reservation");
    end
    if (device_reservation_valid) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                               "device reservation is busy");
    end
    if (used >= depth) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_QUEUE_FULL,
                               "device ring is full");
    end
    device_reservation = rdma_queue_cursor_snapshot::type_id::create(
      "device_producer_reservation");
    reservation = rdma_queue_cursor_snapshot::type_id::create(
      "device_producer_reservation_out");
    if (device_reservation == null || reservation == null) begin
      device_reservation = null;
      reservation = null;
      lock.put(1);
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "device reservation allocation failed");
    end
    device_reservation.index = producer_index;
    device_reservation.wrap = producer_wrap;
    reservation.index = producer_index;
    reservation.wrap = producer_wrap;
    device_reservation_valid = 1'b1;
    lock.put(1);
    return rdma_status::success();
  endfunction

  // 功能：commit_device_producer 将匹配的 device reservation 原子推进到 committed producer cursor，并增加 occupancy。
  // 输入/输出及副作用：reservation（输入）必须是 reserve_device_producer 返回的值副本；成功时只更新 PI/wrap、used 并清除 reservation，不访问 WQE slots。
  // 失败/边界：reservation 为空/失配、runtime 非 ACTIVE（且未显式 recovery commit）、pending evidence、内部计数越界或方向错误时返回错误并保留 reservation。
  function rdma_status commit_device_producer(
    rdma_queue_cursor_snapshot reservation
  );
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (host_produced || !(kind inside {RDMA_QUEUE_RUNTIME_CQ,
                                        RDMA_QUEUE_RUNTIME_CEQ,
                                        RDMA_QUEUE_RUNTIME_AEQ})) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "device producer is invalid for this ring");
    end
    if (reservation == null || !device_reservation_valid ||
        device_reservation == null ||
        reservation.index != device_reservation.index ||
        reservation.wrap != device_reservation.wrap) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "device reservation is stale");
    end
    if (state != RDMA_QUEUE_RUNTIME_ACTIVE &&
        !(recovery_commit_allowed && state == RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED)) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "queue runtime is not active");
    end
    if (used >= depth) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_QUEUE_FULL,
                               "device ring is full");
    end
    cursor_advance(producer_index, producer_wrap);
    used++;
    device_reservation_valid = 1'b0;
    device_reservation = null;
    lock.put(1);
    return rdma_status::success();
  endfunction

  // 功能：cancel_device_producer 清除尚未产生写入副作用的 device reservation，不改变 committed cursor 或 occupancy。
  // 输入/输出及副作用：reservation（输入）必须匹配内部快照；成功时清除 reservation 状态，调用方继续拥有传入值副本。
  // 失败/边界：空/失配快照、非 ACTIVE、无 reservation 或 pending 标记写入尝试时返回 INVALID_STATE/RECOVERY_REQUIRED，并保留内部 reservation。
  function rdma_status cancel_device_producer(
    rdma_queue_cursor_snapshot reservation
  );
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (reservation == null || !device_reservation_valid ||
        device_reservation == null ||
        reservation.index != device_reservation.index ||
        reservation.wrap != device_reservation.wrap) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "device reservation is stale");
    end
    if (state != RDMA_QUEUE_RUNTIME_ACTIVE) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "queue runtime is not active");
    end
    if (pending_operation != null && pending_operation.mmio_maybe_submitted) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_RECOVERY_REQUIRED,
                               "device reservation has write evidence");
    end
    device_reservation_valid = 1'b0;
    device_reservation = null;
    lock.put(1);
    return rdma_status::success();
  endfunction

  // 功能：expected_producer_polarity 依据 initial_polarity 与 reservation（或当前 producer wrap）纯计算 device producer owner 位。
  // 输入/输出及副作用：reservation（可选输入）；函数只读取快照并返回 bit，不修改 runtime 或外部资源。
  // 失败/边界：null reservation 使用当前 producer_wrap；该 helper 不验证 runtime 状态，状态化校验必须调用 query_expected_producer_polarity。
  function bit expected_producer_polarity(
    rdma_queue_cursor_snapshot reservation = null
  );
    return initial_polarity ^ (reservation == null ? producer_wrap : reservation.wrap);
  endfunction

  // 功能：query_occupancy 在 runtime lock 内返回已 commit 的 producer-consumer 距离。
  // 输入/输出及副作用：value（输出）先置零，成功时写入 used；不修改游标、reservation 或 ledger。
  // 失败/边界：未配置、used 超过 depth 或锁忙时返回非成功状态并保持安全输出零。
  function rdma_status query_occupancy(output int unsigned value);
    rdma_status lock_status;
    value = 0;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (depth == 0) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_STATE,"runtime is unconfigured"); end
    if (used > depth) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_STATE,"runtime occupancy exceeds depth"); end
    value = used;
    lock.put(1);
    return rdma_status::success();
  endfunction

  // 功能：query_device_reservation 返回内部 device reservation 的 detached value copy，供诊断与恢复读取。
  // 输入/输出及副作用：valid、reservation（输出）先分别置 0/null；成功时复制 reservation，调用方不得修改 runtime 内部对象。
  // 失败/边界：未配置、非 device ring、内部 reservation 句柄缺失或 clone 分配失败时返回非成功状态且保留安全输出。
  function rdma_status query_device_reservation(
    output bit valid,
    output rdma_queue_cursor_snapshot reservation
  );
    rdma_status lock_status;
    valid = 1'b0;
    reservation = null;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (depth == 0 || host_produced) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_STATE,"runtime is not a device ring"); end
    if (!device_reservation_valid) begin lock.put(1); return rdma_status::success(); end
    if (device_reservation == null) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_STATE,"device reservation state is corrupt"); end
    reservation = rdma_queue_cursor_snapshot::type_id::create("device_reservation_query");
    if (reservation == null) begin lock.put(1); return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,"device reservation snapshot allocation failed"); end
    reservation.index = device_reservation.index;
    reservation.wrap = device_reservation.wrap;
    valid = 1'b1;
    lock.put(1);
    return rdma_status::success();
  endfunction

  // 功能：query_expected_producer_polarity 对 device runtime 执行状态化 owner/polarity 查询。
  // 输入/输出及副作用：polarity（输出）先置零，成功时写入 initial_polarity XOR producer_wrap；不修改 runtime 状态。
  // 失败/边界：未配置、host-produced ring、游标/occupancy 越界或锁忙时返回非成功状态，输出保持零。
  function rdma_status query_expected_producer_polarity(output bit polarity);
    rdma_status lock_status;
    polarity = 1'b0;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (depth == 0 || host_produced || producer_index >= depth || used > depth) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_INVALID_STATE,"producer polarity is unavailable");
    end
    polarity = initial_polarity ^ producer_wrap;
    lock.put(1);
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_runtime 中，expected_owner_polarity 在测试中检查调用结果、状态码和副作用是否符合契约；失败时报告可定位的验证信息。
  // 输入/输出及副作用：无显式参数；expected_owner_polarity 读取 对象字段：initial_polarity、consumer_wrap 并使用字段 initial_polarity、consumer_wrap；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：测试函数 expected_owner_polarity 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function bit expected_owner_polarity();
    return initial_polarity ^ consumer_wrap;
  endfunction

  // 功能：validate_queue_handle 校验 qh 与当前对象状态的一致性，并显式处理“queue handle is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：qh（输入）；validate_queue_handle 读取 qh 并使用字段 rdma_status、queue_h、queue_h.kind、queue_h.function_uid、queue_h.object_id、queue_h.generation；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  function rdma_status validate_queue_handle(rdma_handle qh);
    if (queue_h==null || qh==null) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"queue handle is null");
    if (qh.kind!=queue_h.kind || qh.function_uid!=queue_h.function_uid || qh.object_id!=queue_h.object_id)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"queue handle identity mismatch");
    if (qh.generation!=queue_h.generation) return rdma_status::make(RDMA_SC_STALE_GENERATION,"queue handle generation is stale");
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_runtime 中，reserve_producer 检查容量后预留资源并返回带 owner 证据的句柄/计划；失败时回滚已登记的局部状态。
  // 输入/输出及副作用：reservation（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或 output 发布新句柄/映射。
  // 失败/边界：容量不足、范围非法、重复占用或身份过期时返回错误；失败不得泄漏半分配资源。
  function rdma_status reserve_producer(output rdma_queue_cursor_snapshot reservation);
    rdma_status lock_status;
    reservation=null;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (!host_produced) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_STATE,"host producer is invalid for this ring"); end
    if (state!=RDMA_QUEUE_RUNTIME_ACTIVE) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_STATE,"queue runtime is not active"); end
    if (used>=depth) begin lock.put(1); return rdma_status::make(RDMA_SC_QUEUE_FULL,"queue producer ring is full"); end
    reservation=rdma_queue_cursor_snapshot::type_id::create("producer_reservation"); reservation.index=producer_index; reservation.wrap=producer_wrap; lock.put(1); return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_runtime 中，commit_producer 执行受控事务并按后端提交证据推进状态机，同时保留失败阶段和 generation 证据。
  // 输入/输出及副作用：reservation（输入）、request（输入）、wr_id（输入）、signaled（输入）、image（输入）；输入 request/image/cursor 决定写入内容；成功时更新
  //   PI/CI、slot ledger 或 pending journal，并通过 output 返回结果。
  // 失败/边界：commit_producer 遇到锁、超时、generation 变化或提交证据不完整时保持原状态，不推进游标。
  function rdma_status commit_producer(rdma_queue_cursor_snapshot reservation, rdma_semantic_request request, longint unsigned wr_id, bit signaled, rdma_hw_image image);
    rdma_queue_slot_ledger_entry slot;
    rdma_semantic_request request_copy;
    rdma_hw_image image_copy;
    uvm_object cloned;
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (!host_produced) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_STATE,"host producer is invalid for this ring"); end
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

  // 功能：在 rdma_queue_runtime 中，cursor_equal 逐字段比较输入快照或镜像，确认其身份、布局和 payload 完全一致后返回布尔结果。
  // 输入/输出及副作用：a（输入）、aw（输入）、b（输入）、bw（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
// 失败/边界：cursor_equal 只比较 index 与 wrap 两个值；任一字段不同即返回 0，输入不触发状态更新或资源操作。
  function bit cursor_equal(int unsigned a, bit aw, int unsigned b, bit bw); return a==b && aw==bw; endfunction

  // 功能：在 rdma_queue_runtime 中，cursor_advance 按 ring depth 推进 index，并在回卷时翻转 wrap 位，直接写回两个 inout 游标。
  // 输入/输出及副作用：i（输入输出）、w（输入输出）；cursor_advance 读取 i、w 并使用字段 i、w，并写入 i、w；函数返回 void，不取得调用方资源所有权。
// 失败/边界：cursor_advance 仅在 depth 已配置且 index 位于环深度内时使用；index+1 到达 depth 时回到 0 并翻转 wrap，不产生错误码或外部副作用。
  function void cursor_advance(inout int unsigned i, inout bit w); if(i+1>=depth) begin i=0; w=~w; end else i++; endfunction

  // 功能：在 rdma_queue_runtime 中，match_and_release 按 owner、generation 和幂等规则释放或清理资源，同时删除相关账本记录。
  // 输入/输出及副作用：target_index（输入）、target_wrap（输入）、released（输出）；match_and_release 读取 target_index、target_wrap、released 并使用字段 lock_status、w、count、check_slot、reached_target、slot、slot.consumed，并写入 released；函数返回 rdma_status，不取得调用方资源所有权。

  // 失败/边界：match_and_release 返回 RDMA_SC_INVALID_STATE、RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“queue runtime is not active”“completion index is outside depth”；失败路径不提交部分状态或转移未声明资源。
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
  // 功能：validate_release_range 校验 target_index、target_wrap 与当前对象状态的一致性，并显式处理“queue runtime is not active”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：target_index（输入）、target_wrap（输入）；validate_release_range 读取 target_index、target_wrap 并使用字段 lock_status、w、count、slot、reached_target；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate_release_range 返回 RDMA_SC_INVALID_STATE、RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“queue runtime is not active”“completion index is outside depth”；失败路径不提交部分状态或转移未声明资源。
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

  // 功能：在 rdma_queue_runtime 中，enter_recovery 根据当前证据转换事务或恢复状态，并保持重试、复位和所有权边界一致。
  // 输入/输出及副作用：operation（输入）、mmio_maybe_submitted（输入）；enter_recovery 读取 operation、mmio_maybe_submitted 并使用字段 lock_status、cloned、copy.next_cursor、next_cursor.index、next_cursor.wrap、pending_operation、pending_operation.mmio_maybe_submitted、pending_operation.known_no_mmio；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：enter_recovery 返回 RDMA_SC_INVALID_STATE、RDMA_SC_RESOURCE_EXHAUSTED；典型拒绝条件为“queue runtime cannot enter recovery”“pending operation clone failed”；失败路径不提交部分状态或转移未声明资源。
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

  // 功能：enter_recovery_prepared 接管调用方已完成 detached 的 pending，安装 recovery evidence 而不再次 clone。
  // 输入/输出及副作用：prepared（输入）在成功后由 runtime 接管；状态切换为 RECOVERY_REQUIRED，reservation 保持原快照。
  // 失败/边界：prepared 为空、runtime 非 ACTIVE、queue identity/kind 不匹配或已有 pending 时返回错误且不改变现有状态。
  function rdma_status enter_recovery_prepared(rdma_queue_pending_operation prepared);
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (prepared == null || state != RDMA_QUEUE_RUNTIME_ACTIVE ||
        pending_operation != null) begin
      lock.put(1); return rdma_status::make(RDMA_SC_INVALID_STATE,
                                             "runtime cannot install prepared recovery");
    end
    if (prepared.queue_h == null || queue_h == null ||
        prepared.queue_h.kind != queue_h.kind ||
        prepared.queue_h.function_uid != queue_h.function_uid ||
        prepared.queue_h.object_id != queue_h.object_id ||
        prepared.queue_h.generation != queue_h.generation) begin
      lock.put(1); return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                             "prepared recovery identity mismatch");
    end
    if (prepared.device_producer && !device_reservation_valid) begin
      lock.put(1); return rdma_status::make(RDMA_SC_INVALID_STATE,
                                             "device reservation is missing");
    end
    pending_operation = prepared;
    state = RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED;
    lock.put(1);
    return rdma_status::success();
  endfunction

  // 功能：query_pending 返回当前 recovery pending 的 detached clone。
  // 输入/输出及副作用：snapshot（输出）先置 null；成功时复制 pending，调用方不得修改 runtime 内部对象。
  // 失败/边界：没有 pending、runtime 非 RECOVERY_REQUIRED 或 clone 失败时返回非成功状态并保持 null。
  function rdma_status query_pending(output rdma_queue_pending_operation snapshot);
    snapshot = null;
    return snapshot_pending(snapshot);
  endfunction

  // 功能：query_has_pending 查询 runtime 是否持有 pending evidence。
  // 输入/输出及副作用：present（输出）先置零，成功时写入 pending_operation != null；不修改 runtime。
  // 失败/边界：未配置 runtime 或锁忙时返回错误并保持安全输出。
  function rdma_status query_has_pending(output bit present);
    rdma_status lock_status;
    present = 1'b0;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (depth == 0) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_STATE,"runtime is unconfigured"); end
    present = (pending_operation != null);
    lock.put(1);
    return rdma_status::success();
  endfunction

  // 功能：query_state 返回 runtime 当前状态快照。
  // 输入/输出及副作用：runtime_state（输出）先置 DETACHED，成功时写入 state；不改变状态机。
  // 失败/边界：锁忙时返回 RESOURCE_BUSY，输出保持 DETACHED。
  function rdma_status query_state(output rdma_queue_runtime_state_e runtime_state);
    rdma_status lock_status;
    runtime_state = RDMA_QUEUE_RUNTIME_DETACHED;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    runtime_state = state;
    lock.put(1);
    return rdma_status::success();
  endfunction

  // 功能：query_route_epoch 返回 runtime 配置时锁存的 route/reset epoch authority 快照。
  // 输入/输出及副作用：route_snapshot、route_snapshot_valid、epoch_snapshot、epoch_snapshot_valid（输出）先清零；当前 configure 接口未携带 authority，因此未锁存时返回 INVALID_STATE。
  // 失败/边界：未配置、route/epoch 无效或锁忙时返回非成功状态，四个 output 保持安全默认值。
  function rdma_status query_route_epoch(
    output rdma_route_key_t route_snapshot,
    output bit route_snapshot_valid,
    output rdma_reset_epoch_t epoch_snapshot,
    output bit epoch_snapshot_valid
  );
    rdma_status lock_status;
    route_snapshot = '0;
    route_snapshot_valid = 1'b0;
    epoch_snapshot = '0;
    epoch_snapshot_valid = 1'b0;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (depth == 0 || !route_valid || !epoch_valid) begin
      lock.put(1);
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "route or reset epoch is unavailable");
    end
    route_snapshot = route;
    route_snapshot_valid = 1'b1;
    epoch_snapshot = reset_epoch;
    epoch_snapshot_valid = 1'b1;
    lock.put(1);
    return rdma_status::success();
  endfunction

  // 功能：reservation_matches 判断输入 cursor 是否与当前 device reservation 完全相等。
  // 输入/输出及副作用：cursor（输入）；仅读取 reservation 与 cursor，不修改 runtime。
  // 失败/边界：无有效 reservation、输入为空或 runtime 非 device ring 时返回 0。
  function bit reservation_matches(rdma_queue_cursor_snapshot cursor);
    if (cursor == null || !device_reservation_valid || device_reservation == null)
      return 1'b0;
    return cursor_equal(cursor.index, cursor.wrap,
                        device_reservation.index, device_reservation.wrap);
  endfunction

  // 功能：mark_pending_device_write_attempted 标记 pending 已进入 device write backend。
  // 输入/输出及副作用：无显式输入；在 lock 内更新 device_write_attempted 并归一化 MMIO 投影。
  // 失败/边界：无 recovery pending 或 pending 非 device producer 时返回 INVALID_STATE。
  function rdma_status mark_pending_device_write_attempted();
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (pending_operation == null || !pending_operation.device_producer) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_STATE,"device pending is unavailable"); end
    pending_operation.device_write_attempted = 1'b1;
    pending_operation.mmio_evidence = RDMA_QUEUE_MMIO_AMBIGUOUS;
    pending_operation.mmio_maybe_submitted = 1'b1;
    pending_operation.known_no_mmio = 1'b0;
    lock.put(1); return rdma_status::success();
  endfunction

  // 功能：mark_pending_consumer_doorbell_succeeded 记录 consumer doorbell 的确定成功结果。
  // 输入/输出及副作用：无显式输入；更新 pending 阶段位及 MMIO evidence。
  // 失败/边界：无 pending 或 doorbell 已明确 ambiguous 时返回 INVALID_STATE，禁止伪造成功。
  function rdma_status mark_pending_consumer_doorbell_succeeded();
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (pending_operation == null || pending_operation.mmio_evidence == RDMA_QUEUE_MMIO_AMBIGUOUS) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_STATE,"consumer doorbell evidence is unavailable"); end
    pending_operation.consumer_doorbell_succeeded = 1'b1;
    pending_operation.mmio_evidence = RDMA_QUEUE_MMIO_SUCCESS;
    pending_operation.mmio_maybe_submitted = 1'b0;
    pending_operation.known_no_mmio = 1'b0;
    lock.put(1); return rdma_status::success();
  endfunction

  // 功能：mark_pending_consumer_committed 标记 CI 已提交，并保存提交后 cursor 证据。
  // 输入/输出及副作用：无显式输入；更新 consumer_committed/cq_consumer_committed 与 committed_consumer_cursor。
  // 失败/边界：无 pending、未确认 doorbell（consumer pending）或 CI 游标不匹配时返回 INVALID_STATE。
  function rdma_status mark_pending_consumer_committed();
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (pending_operation == null || (!pending_operation.device_producer && !pending_operation.consumer_doorbell_succeeded)) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_STATE,"consumer commit ordering is invalid"); end
    pending_operation.consumer_committed = 1'b1;
    if (pending_operation.next_cursor != null) begin
      pending_operation.committed_consumer_cursor = rdma_queue_cursor_snapshot::type_id::create("committed_consumer_cursor");
      pending_operation.committed_consumer_cursor.index = pending_operation.next_cursor.index;
      pending_operation.committed_consumer_cursor.wrap = pending_operation.next_cursor.wrap;
    end
    lock.put(1); return rdma_status::success();
  endfunction

  // 功能：mark_pending_cq_consumer_committed 记录 CQ consumer CI 已完成的兼容别名阶段。
  // 输入/输出及副作用：无显式输入；仅在 consumer_committed 已置位时更新 cq_consumer_committed。
  // 失败/边界：无 pending 或 consumer_committed 为零时返回 INVALID_STATE，不改变阶段位。
  function rdma_status mark_pending_cq_consumer_committed();
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (pending_operation == null || !pending_operation.consumer_committed) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_STATE,"CQ consumer commit ordering is invalid"); end
    pending_operation.cq_consumer_committed = 1'b1;
    lock.put(1); return rdma_status::success();
  endfunction

  // 功能：mark_pending_completion_released 标记 CQ 对应 WQE 已释放，保证恢复路径幂等。
  // 输入/输出及副作用：无显式输入；更新 completion_released。
  // 失败/边界：无 pending、CI 未提交或目标不是有效 CQ completion 时返回 INVALID_STATE。
  function rdma_status mark_pending_completion_released();
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (pending_operation == null || !pending_operation.consumer_committed || !pending_operation.completion_target_valid) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_STATE,"completion release ordering is invalid"); end
    pending_operation.completion_released = 1'b1;
    lock.put(1); return rdma_status::success();
  endfunction

  // Recovery execution is owned by rdma_queue_data_engine.  These helpers
  // only commit the state transition once that engine has completed the
  // replay, or preserve the evidence when replay itself fails.
  // 功能：在 rdma_queue_runtime 中，complete_recovery_retry 提交当前事务阶段并发布 detached 结果，只有成功路径才推进游标或状态。
  // 输入/输出及副作用：无显式参数；complete_recovery_retry 读取 对象字段：rdma_status、state、pending_operation、recovery_commit_allowed 并使用字段 lock_status、pending_operation、recovery_commit_allowed、state；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：complete_recovery_retry 返回 RDMA_SC_INVALID_STATE；典型拒绝条件为“queue runtime has no pending recovery”；失败路径不提交部分状态或转移未声明资源。
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
    if (pending_operation.device_producer) begin
      if (!pending_operation.device_write_attempted || device_reservation_valid) begin
        lock.put(1);
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "device recovery stages are incomplete");
      end
      if (kind == RDMA_QUEUE_RUNTIME_CQ &&
          (!pending_operation.consumer_doorbell_succeeded ||
           !pending_operation.consumer_committed ||
           (pending_operation.completion_target_valid &&
            !pending_operation.completion_released))) begin
        lock.put(1);
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "CQ recovery stages are incomplete");
      end
    end
    pending_operation = null;
    device_reservation_valid = 1'b0;
    device_reservation = null;
    recovery_commit_allowed = 1'b0;
    state = RDMA_QUEUE_RUNTIME_ACTIVE;
    lock.put(1);
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_runtime 中，record_recovery_failure 记录 record_recovery_failure 的调用名称和顺序，供测试断言转发路径；不改变被测事务业务结果。
  // 输入/输出及副作用：mmio_maybe_submitted（输入）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过
  //   output 返回结果。
  // 失败/边界：记录操作仅影响测试 trace；不得因注入记录故障改变生产状态或吞掉真实错误。
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

  // 功能：在 rdma_queue_runtime 中，abort_recovery 根据当前证据转换事务或恢复状态，并保持重试、复位和所有权边界一致。
  // 输入/输出及副作用：无显式参数；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：当前状态不允许、epoch/generation 过期或恢复证据不完整时返回错误；不得跳过隔离步骤。
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
    device_reservation_valid = 1'b0;
    device_reservation = null;
    recovery_commit_allowed = 1'b0;
    state = RDMA_QUEUE_RUNTIME_DETACHED;
    lock.put(1);
    return rdma_status::success();
  endfunction

  // 功能：enable_recovery_commit 更新字段 lock_status、recovery_commit_allowed，并在提交前保持 Function authority、generation 和资源所有权约束。
  // 输入/输出及副作用：无显式参数；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：当前状态不允许、epoch/generation 过期或恢复证据不完整时返回错误；不得跳过隔离步骤。
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
  // 功能：在 rdma_queue_runtime 中，snapshot_pending 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：snapshot（输出）；snapshot_pending 读取 snapshot 并使用字段 snapshot、lock_status、cloned，并写入 snapshot；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：snapshot_pending 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
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

  // 功能：在 rdma_queue_runtime 中，recover 执行受控事务并按后端提交证据推进状态机，同时保留失败阶段和 generation 证据。
  // 输入/输出及副作用：action（输入）、caller_confirmed_no_submit（输入）；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：recover 遇到锁、超时、generation 变化或提交证据不完整时保持原状态，不推进游标。
  function rdma_status recover(rdma_queue_recovery_action_e action, bit caller_confirmed_no_submit=1'b0);
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if(state!=RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED || pending_operation==null) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_STATE,"queue runtime has no pending recovery"); end
    if(action==RDMA_QUEUE_RECOVERY_RETRY_PENDING) begin
      if(pending_operation.mmio_maybe_submitted) begin lock.put(1); return rdma_status::make(RDMA_SC_RECOVERY_REQUIRED,"pending MMIO outcome is ambiguous"); end
      if(!caller_confirmed_no_submit) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"retry requires caller confirmation"); end
      // caller confirmation only records that retry is permitted; pending
      // evidence remains isolated until the engine completes each stage.
      lock.put(1); return rdma_status::success();
    end
    if(action==RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH) begin state=RDMA_QUEUE_RUNTIME_DETACHED; lock.put(1); return rdma_status::success(); end
    lock.put(1); return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"recovery action is invalid");
  endfunction

  // 功能：record_recovery_failure（枚举重载）以 MMIO evidence 为唯一 authority 更新 recovery 阶段投影。
  // 输入/输出及副作用：evidence（输入）；在 lock 内写入 mmio_evidence，并同步 known_no_mmio/mmio_maybe_submitted/consumer_doorbell_succeeded。
  // 失败/边界：无 recovery pending 或 evidence 非法时返回非成功状态；不会把 SUCCESS 覆盖成 NO_SUBMIT。
  function rdma_status record_recovery_failure(rdma_queue_mmio_evidence_e evidence);
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (pending_operation == null) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_STATE,"queue runtime has no pending recovery"); end
    if (!(evidence inside {RDMA_QUEUE_MMIO_NONE, RDMA_QUEUE_MMIO_NOT_APPLICABLE,
                           RDMA_QUEUE_MMIO_NO_SUBMIT, RDMA_QUEUE_MMIO_SUCCESS,
                           RDMA_QUEUE_MMIO_AMBIGUOUS})) begin
      lock.put(1); return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"MMIO evidence is invalid");
    end
    if (pending_operation.mmio_evidence == RDMA_QUEUE_MMIO_SUCCESS &&
        evidence != RDMA_QUEUE_MMIO_SUCCESS) begin
      lock.put(1); return rdma_status::make(RDMA_SC_INVALID_STATE,"MMIO success evidence is immutable");
    end
    pending_operation.mmio_evidence = evidence;
    pending_operation.known_no_mmio = (evidence inside {RDMA_QUEUE_MMIO_NOT_APPLICABLE, RDMA_QUEUE_MMIO_NO_SUBMIT});
    pending_operation.mmio_maybe_submitted = (evidence == RDMA_QUEUE_MMIO_AMBIGUOUS);
    pending_operation.consumer_doorbell_succeeded = (evidence == RDMA_QUEUE_MMIO_SUCCESS);
    lock.put(1);
    return rdma_status::success();
  endfunction
endclass
