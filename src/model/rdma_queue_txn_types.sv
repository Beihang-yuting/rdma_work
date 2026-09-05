// 目录：协议与资源模型层 model/rdma_queue_txn_types.sv。
// 职责：实现 rdma_queue_txn_types 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_queue_txn_types.sv 定义队列事务的值模型、阶段转换和恢复契约。
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
  // 中文说明：单个 CQ WQE 释放计划由事务 evidence 创建并拥有；记录 index/
  // wrap 及释放状态，随 evidence 生命周期销毁，不转移底层队列资源所有权。
  `uvm_object_utils(rdma_queue_cq_release_plan)
  int unsigned index;
  bit wrap;
  bit released;
  // 功能：构造 rdma_queue_cq_release_plan，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：index=0；wrap=0；released=0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_cq_release_plan 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_cq_release_plan");
    super.new(name); index = 0; wrap = 0; released = 0;
  endfunction
  // 功能：执行 mark_released 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：无显式参数；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过 output 返回结果。
  // 失败/边界：mark_released 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  function rdma_status mark_released();
    released = 1'b1;
    return rdma_status::success();
  endfunction
  // 功能：将 rhs 中 rdma_queue_cq_release_plan 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（release plan copy mismatch），不保留部分有效快照。
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
  // URC shared-CQ recovery evidence is detached from queue runtime state.
  int unsigned urc_sq_ci;
  int unsigned urc_rq_ci;
  bit [1:0] urc_arm_state;
  longint unsigned urc_sequence;
  rdma_queue_cq_release_plan release_plan[$];

  // 功能：构造 rdma_queue_txn_evidence，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：function_identity=null；queue_h=null；cursor='{default:'0}；next_cursor='{default:'0}；image=null；request_snapshot=null；cqe_snapshot=null；route='0；其余字段按实现默认值初始化。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_txn_evidence 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_txn_evidence");
    super.new(name); function_identity = null; queue_h = null;
    cursor = '{default:'0}; next_cursor = '{default:'0}; image = null;
    request_snapshot = null; cqe_snapshot = null; route = '0;
    failure_status = null; phase = RDMA_QUEUE_TXN_NONE;
    mmio_maybe_submitted = 0; aborted = 0; created_at = 0;
    urc_sq_ci = 0; urc_rq_ci = 0; urc_arm_state = '0; urc_sequence = 0;
    release_plan.delete();
  endfunction

  // 中文：evidence 是事务创建者拥有的不可变审计快照；capture_* 均克隆
  // 调用方对象，释放由本对象生命周期负责，不保留外部可变 alias。
  // 功能：将 rhs 中 rdma_queue_txn_evidence 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（queue transaction evidence copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_queue_txn_evidence source;
    uvm_object cloned;
    rdma_queue_cq_release_plan plan_copy;

    super.do_copy(rhs);
    if (!$cast(source, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "queue transaction evidence copy mismatch")
    if (source.function_identity == null) function_identity = null;
    else begin
      cloned = source.function_identity.clone();
      if (cloned == null || !$cast(function_identity, cloned))
        `uvm_fatal("RDMA_COPY_TYPE", "transaction identity clone mismatch")
    end
    if (source.queue_h == null) queue_h = null;
    else begin
      cloned = source.queue_h.clone();
      if (cloned == null || !$cast(queue_h, cloned))
        `uvm_fatal("RDMA_COPY_TYPE", "transaction queue handle clone mismatch")
    end
    cursor = source.cursor;
    next_cursor = source.next_cursor;
    if (source.image == null) image = null;
    else begin
      cloned = source.image.clone();
      if (cloned == null || !$cast(image, cloned))
        `uvm_fatal("RDMA_COPY_TYPE", "transaction image clone mismatch")
    end
    if (source.request_snapshot == null) request_snapshot = null;
    else begin
      cloned = source.request_snapshot.clone();
      if (cloned == null || !$cast(request_snapshot, cloned))
        `uvm_fatal("RDMA_COPY_TYPE", "transaction request clone mismatch")
    end
    if (source.cqe_snapshot == null) cqe_snapshot = null;
    else begin
      cqe_snapshot = source.cqe_snapshot.clone();
      if (cqe_snapshot == null)
        `uvm_fatal("RDMA_COPY_TYPE", "transaction CQE clone mismatch")
    end
    route = source.route;
    if (source.failure_status == null) failure_status = null;
    else begin
      cloned = source.failure_status.clone();
      if (cloned == null || !$cast(failure_status, cloned))
        `uvm_fatal("RDMA_COPY_TYPE", "transaction failure clone mismatch")
    end
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
        cloned = source.release_plan[i].clone();
        if (cloned == null || !$cast(plan_copy, cloned))
          `uvm_fatal("RDMA_COPY_TYPE", "transaction release plan clone mismatch")
        release_plan.push_back(plan_copy);
      end
    end
  endfunction

  // 功能：记录共享 URC CQ 的 SQ/RQ consumer CI、arm state 和 sequence，形成可重放事务证据。
  // 输入/输出及副作用：shadow 为输入值快照；成功时复制其 authority 游标字段到本 evidence，不修改 shadow 或 queue runtime。
  // 失败边界：shadow 为空或 validate 失败时返回对应错误，既有 evidence 字段保持不变。
  function rdma_status capture_urc_shadow(rdma_cq_shadow_snapshot shadow);
    rdma_status status;
    if (shadow == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "URC CQ shadow is null");
    status = shadow.validate();
    if (!status.ok()) return status;
    urc_sq_ci = shadow.sq_ci;
    urc_rq_ci = shadow.rq_ci;
    urc_arm_state = shadow.arm_state;
    urc_sequence = shadow.\sequence ;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_txn_evidence 中，advance 推进队列/事务游标或执行对应 I/O，并把结果写回声明的输出参数。
  // 输入/输出及副作用：next_phase（输入）；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：advance 返回 RDMA_SC_INVALID_STATE；典型拒绝条件为“transaction is terminal”“transaction phase rollback”；失败路径不提交部分状态或转移未声明资源。
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

  // 中文：所有阶段变更统一经过 advance，禁止恢复/释放路径绕过转换表。
  // 功能：在 rdma_queue_txn_evidence 中，transition_to 执行受控事务并按后端提交证据推进状态机，同时保留失败阶段和 generation 证据。
  // 输入/输出及副作用：next_phase（输入）；transition_to 可能更新本对象明确拥有的状态；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：transition_to 遇到锁、超时、generation 变化或提交证据不完整时保持原状态，不推进游标。
  function rdma_status transition_to(rdma_queue_txn_phase_e next_phase);
    return advance(next_phase);
  endfunction

  // Capture mutable producer objects as detached value snapshots.
  // 功能：在 rdma_queue_txn_evidence 中，capture_function_identity 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）；capture_function_identity 读取 source 并使用字段 cloned、route；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：capture_function_identity 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_RESOURCE_EXHAUSTED；典型拒绝条件为“Function identity is null”“Function identity snapshot clone failed”；失败路径不提交部分状态或转移未声明资源。
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
    if (!rdma_route_key_valid(route))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "Function route key is invalid");
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_txn_evidence 中，capture_queue_handle 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）；capture_queue_handle 读取 source 并使用字段 cloned；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：capture_queue_handle 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_RESOURCE_EXHAUSTED；典型拒绝条件为“queue handle is null”“queue handle snapshot clone failed”；失败路径不提交部分状态或转移未声明资源。
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

  // 中文：兼容调用方的 queue_h 命名；实现仍统一走 detached capture。
  // 功能：在 rdma_queue_txn_evidence 中，capture_queue_h 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）；capture_queue_h 读取 source 并使用输入参数和固定枚举/常量；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：capture_queue_h 的结果直接由 return capture_queue_handle(source) 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function rdma_status capture_queue_h(rdma_handle source);
    return capture_queue_handle(source);
  endfunction

  // 功能：执行 set_queue_handle 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：source（输入）；调用方必须先完成输入对象的空值、authority 和 generation 校验；成功时更新本对象配置/状态并保存非拥有引用，返回 rdma_status。
  // 失败/边界：set_queue_handle 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  function rdma_status set_queue_handle(rdma_handle source);
    return capture_queue_handle(source);
  endfunction

  // 功能：在 rdma_queue_txn_evidence 中，capture_request 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）；capture_request 读取 source 并使用字段 status、cloned；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：capture_request 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_RESOURCE_EXHAUSTED；典型拒绝条件为“semantic request is null”“request snapshot clone failed”；失败路径不提交部分状态或转移未声明资源。
  function rdma_status capture_request(rdma_semantic_request source);
    uvm_object cloned;
    rdma_status status;
    if (source == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "semantic request is null");
    status = source.validate();
    if (!status.ok()) return status;
    cloned = source.clone();
    if (cloned == null || !$cast(request_snapshot, cloned))
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "request snapshot clone failed");
    if (request_snapshot == source)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "request snapshot aliased source");
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_txn_evidence 中，capture_request_snapshot 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）；capture_request_snapshot 读取 source 并使用输入参数和固定枚举/常量；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：capture_request_snapshot 的结果直接由 return capture_request(source) 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function rdma_status capture_request_snapshot(rdma_semantic_request source);
    return capture_request(source);
  endfunction

  // 功能：执行 set_request_snapshot 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：source（输入）；调用方必须先完成输入对象的空值、authority 和 generation 校验；成功时更新本对象配置/状态并保存非拥有引用，返回 rdma_status。
  // 失败/边界：set_request_snapshot 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  function rdma_status set_request_snapshot(rdma_semantic_request source);
    return capture_request(source);
  endfunction

  // 功能：在 rdma_queue_txn_evidence 中，capture_cqe 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）；capture_cqe 读取 source 并使用字段 cqe_snapshot；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：capture_cqe 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_RESOURCE_EXHAUSTED；典型拒绝条件为“CQE is null”“CQE snapshot clone failed”；失败路径不提交部分状态或转移未声明资源。
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

  // 功能：在 rdma_queue_txn_evidence 中，capture_cqe_snapshot 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）；capture_cqe_snapshot 读取 source 并使用输入参数和固定枚举/常量；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：capture_cqe_snapshot 的结果直接由 return capture_cqe(source) 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function rdma_status capture_cqe_snapshot(uvm_object source);
    return capture_cqe(source);
  endfunction

  // 功能：执行 set_cqe_snapshot 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：source（输入）；调用方必须先完成输入对象的空值、authority 和 generation 校验；成功时更新本对象配置/状态并保存非拥有引用，返回 rdma_status。
  // 失败/边界：set_cqe_snapshot 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  function rdma_status set_cqe_snapshot(uvm_object source);
    return capture_cqe(source);
  endfunction

  // 功能：执行 set_failure 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：source（输入）；调用方必须先完成输入对象的空值、authority 和 generation 校验；成功时更新本对象配置/状态并保存非拥有引用，返回 rdma_status。
  // 失败/边界：set_failure 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
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

  // 功能：执行 set_failure_status 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：source（输入）；set_failure_status 可能更新本对象明确拥有的状态；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：set_failure_status 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  function rdma_status set_failure_status(rdma_status source);
    return set_failure(source);
  endfunction

  // 功能：在 rdma_queue_txn_evidence 中，capture_failure_status 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）；capture_failure_status 读取 source 并使用输入参数和固定枚举/常量；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：capture_failure_status 的结果直接由 return set_failure(source) 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function rdma_status capture_failure_status(rdma_status source);
    return set_failure(source);
  endfunction

  // 功能：在 rdma_queue_txn_evidence 中，capture_image 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）；capture_image 读取 source 并使用字段 cloned；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：capture_image 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_RESOURCE_EXHAUSTED；典型拒绝条件为“hardware image is null”“hardware image snapshot clone failed”；失败路径不提交部分状态或转移未声明资源。
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

  // 功能：执行 mark_mmio_maybe_submitted 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：无显式参数；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过 output 返回结果。
  // 失败/边界：mark_mmio_maybe_submitted 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  function rdma_status mark_mmio_maybe_submitted();
    if (aborted || phase == RDMA_QUEUE_TXN_COMPLETED)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "transaction is terminal");
    if (phase != RDMA_QUEUE_TXN_PAYLOAD_WRITTEN)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "MMIO submission requires payload evidence");
    if (!transition_to(RDMA_QUEUE_TXN_DOORBELL_MAYBE_SUBMITTED).ok())
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "MMIO phase transition failed");
    mmio_maybe_submitted = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_txn_evidence 中，recover 执行受控事务并按后端提交证据推进状态机，同时保留失败阶段和 generation 证据。
  // 输入/输出及副作用：action（输入）、caller_confirmed_no_submit（输入）；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：recover 遇到锁、超时、generation 变化或提交证据不完整时保持原状态，不推进游标。
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

  // 功能：执行 mark_wqe_release 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：index（输入）、wrap（输入）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过 output
  //   返回结果。
  // 失败/边界：mark_wqe_release 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
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
        return transition_to(RDMA_QUEUE_TXN_WQE_RELEASE_PARTIAL);
      end
    end
    plan = rdma_queue_cq_release_plan::type_id::create("release_plan");
    plan.index = index; plan.wrap = wrap; plan.released = 1'b1;
    release_plan.push_back(plan);
    // A partial release may accumulate multiple distinct WQE entries; adding
    // a plan must not attempt a same-phase transition (or leave a mutation
    // behind on an INVALID_STATE result).
    if (phase == RDMA_QUEUE_TXN_WQE_RELEASE_PARTIAL)
      return rdma_status::success();
    return transition_to(RDMA_QUEUE_TXN_WQE_RELEASE_PARTIAL);
  endfunction

  // 功能：在 rdma_queue_txn_evidence 中，complete 提交当前事务阶段并发布 detached 结果，只有成功路径才推进游标或状态。
  // 输入/输出及副作用：无显式参数；complete 读取 对象字段：rdma_status、aborted、release_plan、released 并使用字段 rdma_status、aborted、release_plan、released；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：complete 返回 RDMA_SC_INVALID_STATE；具体拒绝条件包括 “transaction cannot complete”；“transaction completion requires WQE release plan”；“transaction completion requires released WQE”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  function rdma_status complete();
    if (aborted || phase != RDMA_QUEUE_TXN_WQE_RELEASE_PARTIAL)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "transaction cannot complete");
    if (release_plan.size() == 0)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "transaction completion requires WQE release plan");
    foreach (release_plan[i]) begin
      if (release_plan[i] != null && release_plan[i].released)
        return transition_to(RDMA_QUEUE_TXN_COMPLETED);
    end
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             "transaction completion requires released WQE");
  endfunction

  // 中文：abort 是不可逆终态标记；调用者仍拥有 evidence，释放动作必须
  // 由上层按资源所有权顺序执行，任何后续阶段修改都会被拒绝。
  // 功能：在 rdma_queue_txn_evidence 中，abort 根据当前证据转换事务或恢复状态，并保持重试、复位和所有权边界一致。
  // 输入/输出及副作用：无显式参数；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：当前状态不允许、epoch/generation 过期或恢复证据不完整时返回错误；不得跳过隔离步骤。
  function rdma_status abort();
    if (aborted || phase == RDMA_QUEUE_TXN_COMPLETED)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "transaction is terminal");
    aborted = 1'b1;
    return rdma_status::success();
  endfunction
endclass
