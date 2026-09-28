// 目录/层次：核心执行层 core/rdma_queue_runtime_transaction_models.sv。
// 文件职责：定义 queue runtime 使用的枚举、cursor、pending recovery evidence 和
//   host slot ledger 值模型，把 detached transaction 数据与可变 runtime owner 分离。
// 主要依赖：依赖 rdma_types_pkg 的 status/route/reset epoch、rdma_model_pkg 的
//   handle、semantic request 与 hardware image，以及 UVM object factory；不访问
//   runtime lock、账本、Host-memory、PCIe 或外部 adapter。
// 所有权与生命周期：这些对象只保存一次 runtime transaction 窗口内的 detached 值；
//   runtime 仍拥有 slots、pending publication、cursor mutation 和锁，外部 backing、
//   scheduler、QP/Function 资源仍由各自 lifecycle owner 管理。

// 中文设计说明：这些 enum 是 queue runtime 的 wire-independent 状态 vocabulary。
// 它们放在值模型文件中，保证 policy/engine 可以读取稳定分类，而不需要依赖 runtime
// 的可变实现；新增枚举不能隐含创建第二份状态账本。
typedef enum bit [2:0] {
  RDMA_QUEUE_RUNTIME_DETACHED = 3'd0,
  RDMA_QUEUE_RUNTIME_ATTACHED = 3'd1,
  RDMA_QUEUE_RUNTIME_ACTIVE = 3'd2,
  RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED = 3'd3,
  // resize 在 QUIESCING 窗口禁止新事务；它与 DETACHED 分离，使 replacement 失败时
  // 还能恢复旧 attachment 而不丢失游标账本。
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

// 设计说明：ring cursor 必须把 index 和 wrap 作为一个值传递，否则在回卷边界仅
// 比较 index 会把 stale reservation 误认为当前事务。
class rdma_queue_cursor_snapshot extends uvm_object;
  `uvm_object_utils(rdma_queue_cursor_snapshot)
  int unsigned index;
  bit wrap;

  // 功能：构造默认指向 ring 第 0 项、未回卷的 cursor 值对象。
  // 输入/输出及副作用：name（输入）仅设置 UVM 对象名；初始化 index=0/wrap=0。
  // 失败/边界：构造不知道 ring depth，因此 0/0 只是值默认项，不是已授权 reservation。
  function new(string name = "rdma_queue_cursor_snapshot");
    super.new(name);
    index = 0;
    wrap = 0;
  endfunction

  // 功能：将 rhs 中 cursor 的 index/wrap 复制到当前对象，建立与源对象隔离的值快照。
  // 输入/输出及副作用：rhs（输入）；类型正确时覆盖当前 index/wrap，不修改 rhs。
  // 失败/边界：rhs 为 null 或类型不匹配时保留当前 cursor；本函数不验证 index<depth。
  virtual function void do_copy(uvm_object rhs);
    rdma_queue_cursor_snapshot source;
    super.do_copy(rhs);
    if (!$cast(source, rhs)) return;
    index = source.index;
    wrap = source.wrap;
  endfunction
endclass

// 设计说明：pending operation 是 recovery 的唯一事务证据载体，冻结 queue identity、
// cursor、image、route/epoch、MMIO evidence 和阶段位；runtime 通过 non-fatal helper
// 建立 detached 快照，不信任 caller 的兼容 bit。
class rdma_queue_pending_operation extends uvm_object;
  `uvm_object_utils(rdma_queue_pending_operation)
  rdma_handle queue_h;
  rdma_queue_runtime_kind_e kind;
  bit producer;
  bit device_producer;
  bit device_write_attempted;
  bit consumer_committed;
  bit cq_consumer_committed;
  bit completion_released;
  bit consumer_doorbell_succeeded;
  // CQ shadow publication 是 host-memory write，不是 MMIO doorbell；两者 evidence 分离。
  bit consumer_shadow_required;
  bit consumer_shadow_urc;
  bit consumer_shadow_attempted;
  bit consumer_shadow_published;
  longint unsigned consumer_shadow_offset;
  int unsigned consumer_shadow_length;
  int unsigned consumer_shadow_value;
  longint unsigned entry_offset;
  rdma_queue_cursor_snapshot cursor;
  rdma_queue_cursor_snapshot next_cursor;
  rdma_hw_image image;
  rdma_semantic_request request_snapshot;
  longint unsigned wr_id;
  bit signaled;
  int unsigned completion_index;
  bit completion_wrap;
  bit completion_target_valid;
  rdma_queue_runtime_kind_e completion_wq_kind;
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

  // 功能：构造一个尚未具备任何可提交 authority 的 pending evidence 外壳。
  // 输入/输出及副作用：name（输入）设置 UVM 名称；所有 handle/快照置 null、阶段位清零，
  //   kind 默认 SQ，MMIO authority 置 RDMA_QUEUE_MMIO_NONE。
  // 失败/边界：默认对象不能直接交给 recovery；缺 queue_h/cursor/image/status/route/epoch
  //   的 device evidence 必须在 enter_recovery_prepared 被拒绝。
  function new(string name = "rdma_queue_pending_operation");
    super.new(name);
    queue_h = null;
    kind = RDMA_QUEUE_RUNTIME_SQ;
    producer = 0;
    device_producer = 0;
    device_write_attempted = 0;
    consumer_committed = 0;
    cq_consumer_committed = 0;
    completion_released = 0;
    consumer_doorbell_succeeded = 0;
    consumer_shadow_required = 0;
    consumer_shadow_urc = 0;
    consumer_shadow_attempted = 0;
    consumer_shadow_published = 0;
    consumer_shadow_offset = 0;
    consumer_shadow_length = 0;
    consumer_shadow_value = 0;
    entry_offset = 0;
    cursor = null;
    next_cursor = null;
    image = null;
    request_snapshot = null;
    wr_id = 0;
    signaled = 0;
    completion_index = 0;
    completion_wrap = 0;
    completion_target_valid = 0;
    completion_wq_kind = RDMA_QUEUE_RUNTIME_SQ;
    routed_qp_h = null;
    mmio_maybe_submitted = 0;
    known_no_mmio = 0;
    mmio_evidence = RDMA_QUEUE_MMIO_NONE;
    committed_consumer_cursor = null;
    failure_status = null;
    entry_size = 0;
    route = '0;
    route_valid = 0;
    reset_epoch = 0;
    epoch_valid = 0;
  endfunction

  // 功能：do_copy 为 UVM print/clone 兼容复制 pending 标量，并为 queue/cursor/image/status
  //   建立局部值对象；request_snapshot/routed_qp_h 保留兼容的非拥有引用。
  // 输入/输出及副作用：rhs（输入）；覆盖当前对象，不修改 rhs；关键 recovery 深拷贝由
  //   runtime.clone_pending_value 提供，以便传播 non-fatal 失败。
  // 失败/边界：rhs 为 null 或类型不匹配时保留当前值；本 void 入口不保证完整 detached
  //   graph，不能替代 runtime 的带状态 clone helper。
  virtual function void do_copy(uvm_object rhs);
    rdma_queue_pending_operation source;
    super.do_copy(rhs);
    if (!$cast(source, rhs)) return;
    if (source.queue_h == null) queue_h = null;
    else begin
      queue_h = new("pending_copy_queue");
      if (queue_h != null) begin
        queue_h.kind = source.queue_h.kind;
        queue_h.function_uid = source.queue_h.function_uid;
        queue_h.object_id = source.queue_h.object_id;
        queue_h.generation = source.queue_h.generation;
      end
    end
    kind = source.kind;
    producer = source.producer;
    device_producer = source.device_producer;
    device_write_attempted = source.device_write_attempted;
    consumer_committed = source.consumer_committed;
    cq_consumer_committed = source.cq_consumer_committed;
    completion_released = source.completion_released;
    consumer_doorbell_succeeded = source.consumer_doorbell_succeeded;
    consumer_shadow_required = source.consumer_shadow_required;
    consumer_shadow_urc = source.consumer_shadow_urc;
    consumer_shadow_attempted = source.consumer_shadow_attempted;
    consumer_shadow_published = source.consumer_shadow_published;
    consumer_shadow_offset = source.consumer_shadow_offset;
    consumer_shadow_length = source.consumer_shadow_length;
    consumer_shadow_value = source.consumer_shadow_value;
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
      committed_consumer_cursor = new("pending_copy_committed_cursor");
      if (committed_consumer_cursor != null) begin
        committed_consumer_cursor.index = source.committed_consumer_cursor.index;
        committed_consumer_cursor.wrap = source.committed_consumer_cursor.wrap;
      end
    end
    if (source.failure_status == null) failure_status = null;
    else begin
      failure_status = new("pending_copy_failure_status");
      if (failure_status != null) begin
        failure_status.category = source.failure_status.category;
        failure_status.code = source.failure_status.code;
        failure_status.hardware_code = source.failure_status.hardware_code;
        failure_status.hardware_code_valid = source.failure_status.hardware_code_valid;
        failure_status.source_engine = source.failure_status.source_engine;
        failure_status.function_uid = source.failure_status.function_uid;
        failure_status.generation = source.failure_status.generation;
        failure_status.resource_id = source.failure_status.resource_id;
        failure_status.command_id = source.failure_status.command_id;
        failure_status.wr_id = source.failure_status.wr_id;
        failure_status.severity = source.failure_status.severity;
        failure_status.retryable = source.failure_status.retryable;
        failure_status.message = source.failure_status.message;
      end
    end
    if (source.cursor == null) cursor = null;
    else begin
      cursor = new("pending_copy_cursor");
      cursor.index = source.cursor.index;
      cursor.wrap = source.cursor.wrap;
    end
    if (source.next_cursor == null) next_cursor = null;
    else begin
      next_cursor = new("pending_copy_next_cursor");
      next_cursor.index = source.next_cursor.index;
      next_cursor.wrap = source.next_cursor.wrap;
    end
    if (source.image == null) image = null;
    else begin
      image = new("pending_copy_image");
      if (image != null) begin
        image.length = source.image.length;
        image.alignment = source.image.alignment;
        image.endian = source.image.endian;
        image.image_kind = source.image.image_kind;
        image.hardware_version = source.image.hardware_version;
        image.function_generation = source.image.function_generation;
        image.write_target_kind = source.image.write_target_kind;
        image.backing_target = source.image.backing_target;
        image.hmc_target = source.image.hmc_target;
        image.bar_target = source.image.bar_target;
        image.bytes = source.image.bytes;
        image.field_summary = source.image.field_summary;
      end
    end
    signaled = source.signaled;
    wr_id = source.wr_id;
    completion_index = source.completion_index;
    completion_wrap = source.completion_wrap;
    completion_target_valid = source.completion_target_valid;
    completion_wq_kind = source.completion_wq_kind;
    routed_qp_h = source.routed_qp_h;
    request_snapshot = source.request_snapshot;
  endfunction
endclass

// 设计说明：host-produced ring 需要以 slot 记录 request/image/wr_id 与 completion 状态，
// 才能按 signaled completion 连续释放前置 unsignaled WQE。
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

  // 功能：构造一个未 post、未 consume 的 host WQE ledger slot。
  // 输入/输出及副作用：name（输入）设置 UVM 名称；清零游标/元数据并置 request_snapshot、
  //   image、completion_status 为 null。
  // 失败/边界：初始 slot 不代表可消费 WQE；只有 commit_producer 可以将 posted 置位。
  function new(string name = "rdma_queue_slot_ledger_entry");
    super.new(name);
    posted = 0;
    consumed = 0;
    signaled = 0;
    wr_id = 0;
    index = 0;
    wrap = 0;
    request_snapshot = null;
    image = null;
    completion_status = null;
  endfunction
endclass
