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

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name="rdma_queue_cursor_snapshot"); super.new(name); index=0; wrap=0; endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
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

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name="rdma_queue_pending_operation");
    super.new(name);
    queue_h=null; kind=RDMA_QUEUE_RUNTIME_SQ; producer=0; entry_offset=0;
    cursor=null; next_cursor=null; image=null; request_snapshot=null;
    signaled=0; wr_id=0; completion_index=0; completion_wrap=0;
    completion_target_valid=0; completion_released=0; routed_qp_h=null;
    mmio_maybe_submitted=0; known_no_mmio=0;
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
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

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
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

  // 功能：检查可用容量并预留所需资源，返回带所有权证据的分配结果；容量不足时不留下部分分配。
  // 输入/输出及副作用：输入请求、容量和依赖用于构造/预留资源；返回独立对象或状态，不暴露内部可变集合。
  //   参数越界、容量不足或构造中途失败时回滚已登记的局部状态。
  // 失败/边界：依赖为空、参数越界、容量不足或构造步骤失败时清理局部结果并返回明确错误。
  protected function rdma_status acquire_lock();
    if (lock == null || !lock.try_get(1))
      return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                               "queue runtime is busy");
    return rdma_status::success();
  endfunction

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name="rdma_queue_runtime");
    super.new(name); queue_h=null; kind=RDMA_QUEUE_RUNTIME_SQ; state=RDMA_QUEUE_RUNTIME_DETACHED;
    depth=0; producer_index=0; consumer_index=0; producer_wrap=0; consumer_wrap=0; initial_polarity=0; used=0; pending_operation=null; lock=new(1); recovery_commit_allowed=0;
  endfunction

  // 功能：校验依赖并建立该对象的运行边界，成功后保存必要的非拥有引用；拒绝不完整或重复配置。
  // 输入/输出及副作用：接收 manager、binding、router 或 profile 等依赖；成功后保存非拥有引用并更新配置状态。
  //   任一依赖为空、重复配置或代际不匹配时保持原状态并返回错误。
  // 失败/边界：配置失败不得写入半成品引用；已激活对象不得被无条件降级或重复占用资源。
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

  // 功能：校验依赖并建立该对象的运行边界，成功后保存必要的非拥有引用；拒绝不完整或重复配置。
  // 输入/输出及副作用：接收 manager、binding、router 或 profile 等依赖；成功后保存非拥有引用并更新配置状态。
  //   任一依赖为空、重复配置或代际不匹配时保持原状态并返回错误。
  // 失败/边界：配置失败不得写入半成品引用；已激活对象不得被无条件降级或重复占用资源。
  function rdma_status activate();
    rdma_status lock_status;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (state!=RDMA_QUEUE_RUNTIME_ATTACHED) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_STATE,"queue runtime is not attached"); end
    state=RDMA_QUEUE_RUNTIME_ACTIVE; lock.put(1); return rdma_status::success();
  endfunction

  // 功能：按输入的完整标识查询当前权威记录并返回独立快照；缺失、歧义或代际过期时返回明确错误。
  // 输入/输出及副作用：输入为完整 key/handle，output 或返回值为记录快照；查询不改变登记表和外部资源。
  //   缺失、歧义、空句柄或旧 generation/reset epoch 返回明确错误。
  // 失败/边界：查询不到唯一记录、输入为空或 authority 已失效时返回错误，不回退到默认 Function/root。
  function rdma_status query_available(output int unsigned value); if(depth==0) begin value=0; return rdma_status::make(RDMA_SC_INVALID_STATE,"runtime is unconfigured"); end value=depth-used; return rdma_status::success(); endfunction

  // 功能：处理 available_slots：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 endfunction 用于执行 available_slots；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：available_slots 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function int unsigned available_slots(); return depth-used; endfunction

  // 功能：处理 peek_consumer：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 lock_status 用于执行 peek_consumer；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：peek_consumer 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
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

  // 功能：执行一次受控事务并推进所属状态机；返回结果时保留失败阶段、代际和后端提交证据。
  // 输入/输出及副作用：参数 lock_status 用于执行 commit_consumer；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：事务超时、代际变化或提交证据不完整时不得推进下一阶段。
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

  // 功能：在测试中检查调用结果、状态码和副作用是否符合契约；失败时报告可定位的验证信息。
  // 输入/输出及副作用：参数 consumer_wrap 用于执行 expected_owner_polarity；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：测试前置对象缺失时应报告断言错误并停止依赖该对象的后续检查。
  function bit expected_owner_polarity();
    return initial_polarity ^ consumer_wrap;
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  function rdma_status validate_queue_handle(rdma_handle qh);
    if (queue_h==null || qh==null) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"queue handle is null");
    if (qh.kind!=queue_h.kind || qh.function_uid!=queue_h.function_uid || qh.object_id!=queue_h.object_id)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"queue handle identity mismatch");
    if (qh.generation!=queue_h.generation) return rdma_status::make(RDMA_SC_STALE_GENERATION,"queue handle generation is stale");
    return rdma_status::success();
  endfunction

  // 功能：检查可用容量并预留所需资源，返回带所有权证据的分配结果；容量不足时不留下部分分配。
  // 输入/输出及副作用：输入请求、容量和依赖用于构造/预留资源；返回独立对象或状态，不暴露内部可变集合。
  //   参数越界、容量不足或构造中途失败时回滚已登记的局部状态。
  // 失败/边界：依赖为空、参数越界、容量不足或构造步骤失败时清理局部结果并返回明确错误。
  function rdma_status reserve_producer(output rdma_queue_cursor_snapshot reservation);
    rdma_status lock_status;
    reservation=null;
    lock_status = acquire_lock();
    if (!lock_status.ok()) return lock_status;
    if (state!=RDMA_QUEUE_RUNTIME_ACTIVE) begin lock.put(1); return rdma_status::make(RDMA_SC_INVALID_STATE,"queue runtime is not active"); end
    if (used>=depth) begin lock.put(1); return rdma_status::make(RDMA_SC_QUEUE_FULL,"queue producer ring is full"); end
    reservation=rdma_queue_cursor_snapshot::type_id::create("producer_reservation"); reservation.index=producer_index; reservation.wrap=producer_wrap; lock.put(1); return rdma_status::success();
  endfunction

  // 功能：执行一次受控事务并推进所属状态机；返回结果时保留失败阶段、代际和后端提交证据。
  // 输入/输出及副作用：参数 reservation, request, wr_id, signaled, slot 用于执行 commit_producer；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：事务超时、代际变化或提交证据不完整时不得推进下一阶段。
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

  // 功能：处理 cursor_equal：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 a, aw, b, a 用于执行 cursor_equal；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：cursor_equal 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function bit cursor_equal(int unsigned a, bit aw, int unsigned b, bit bw); return a==b && aw==bw; endfunction

  // 功能：处理 cursor_advance：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 i, i 用于执行 cursor_advance；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：cursor_advance 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function void cursor_advance(inout int unsigned i, inout bit w); if(i+1>=depth) begin i=0; w=~w; end else i++; endfunction

  // 功能：处理 match_and_release：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 target_index, target_wrap, reached_target 用于执行 match_and_release；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：match_and_release 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
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
  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
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

  // 功能：处理 enter_recovery：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 operation, lock_status 用于执行 enter_recovery；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：enter_recovery 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
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
  // 功能：处理 complete_recovery_retry：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 lock_status 用于执行 complete_recovery_retry；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：complete_recovery_retry 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
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

  // 功能：记录本次调用的名称和顺序，供测试断言转发路径；不改变被测事务的业务结果。
  // 输入/输出及副作用：输入为调用名称、事件或 trace 数据；成功后追加测试可见记录，不改变业务资源。
  //   空名称或记录容量边界按测试替身约定处理，不影响被测对象。
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

  // 功能：处理 abort_recovery：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 lock_status 用于执行 abort_recovery；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：abort_recovery 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
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

  // 功能：处理 enable_recovery_commit：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 lock_status 用于执行 enable_recovery_commit；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：enable_recovery_commit 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
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
  // 功能：按输入的完整标识查询当前权威记录并返回独立快照；缺失、歧义或代际过期时返回明确错误。
  // 输入/输出及副作用：输入为完整 key/handle，output 或返回值为记录快照；查询不改变登记表和外部资源。
  //   缺失、歧义、空句柄或旧 generation/reset epoch 返回明确错误。
  // 失败/边界：查询不到唯一记录、输入为空或 authority 已失效时返回错误，不回退到默认 Function/root。
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

  // 功能：执行一次受控事务并推进所属状态机；返回结果时保留失败阶段、代际和后端提交证据。
  // 输入/输出及副作用：参数 action, caller_confirmed_no_submit 用于执行 recover；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：事务超时、代际变化或提交证据不完整时不得推进下一阶段。
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
