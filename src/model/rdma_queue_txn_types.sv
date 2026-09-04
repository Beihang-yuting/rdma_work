// 目录：协议与资源模型层 model/rdma_queue_txn_types.sv。
// 职责：实现 rdma_queue_txn_types 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

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
  // 中文说明：单个 CQ WQE 释放计划由事务 evidence 创建并拥有；记录 index/
  // wrap 及释放状态，随 evidence 生命周期销毁，不转移底层队列资源所有权。
  `uvm_object_utils(rdma_queue_cq_release_plan)
  int unsigned index;
  bit wrap;
  bit released;
  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_queue_cq_release_plan");
    super.new(name); index = 0; wrap = 0; released = 0;
  endfunction
  // 功能：执行 mark_released 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：参数 released 用于执行 mark_released；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：mark_released 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  function rdma_status mark_released();
    released = 1'b1;
    return rdma_status::success();
  endfunction
  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
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

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_queue_txn_evidence");
    super.new(name); function_identity = null; queue_h = null;
    cursor = '{default:'0}; next_cursor = '{default:'0}; image = null;
    request_snapshot = null; cqe_snapshot = null; route = '0;
    failure_status = null; phase = RDMA_QUEUE_TXN_NONE;
    mmio_maybe_submitted = 0; aborted = 0; created_at = 0;
    release_plan.delete();
  endfunction

  // 中文：evidence 是事务创建者拥有的不可变审计快照；capture_* 均克隆
  // 调用方对象，释放由本对象生命周期负责，不保留外部可变 alias。
  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
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

  // 功能：处理 advance：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 valid_transition 用于执行 advance；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：advance 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
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
  // 功能：执行一次受控事务并推进所属状态机；返回结果时保留失败阶段、代际和后端提交证据。
  // 输入/输出及副作用：参数 next_phase 用于执行 transition_to；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：事务超时、代际变化或提交证据不完整时不得推进下一阶段。
  function rdma_status transition_to(rdma_queue_txn_phase_e next_phase);
    return advance(next_phase);
  endfunction

  // Capture mutable producer objects as detached value snapshots.
  // 功能：处理 capture_function_identity：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 cloned 用于执行 capture_function_identity；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：capture_function_identity 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
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

  // 功能：处理 capture_queue_handle：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 cloned 用于执行 capture_queue_handle；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：capture_queue_handle 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
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
  // 功能：处理 capture_queue_h：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 source 用于执行 capture_queue_h；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：capture_queue_h 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function rdma_status capture_queue_h(rdma_handle source);
    return capture_queue_handle(source);
  endfunction

  // 功能：执行 set_queue_handle 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：参数 source 用于执行 set_queue_handle；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：set_queue_handle 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  function rdma_status set_queue_handle(rdma_handle source);
    return capture_queue_handle(source);
  endfunction

  // 功能：处理 capture_request：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 cloned 用于执行 capture_request；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：capture_request 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
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

  // 功能：处理 capture_request_snapshot：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 source 用于执行 capture_request_snapshot；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：capture_request_snapshot 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function rdma_status capture_request_snapshot(rdma_semantic_request source);
    return capture_request(source);
  endfunction

  // 功能：执行 set_request_snapshot 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：参数 source 用于执行 set_request_snapshot；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：set_request_snapshot 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  function rdma_status set_request_snapshot(rdma_semantic_request source);
    return capture_request(source);
  endfunction

  // 功能：处理 capture_cqe：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 source 用于执行 capture_cqe；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：capture_cqe 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
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

  // 功能：处理 capture_cqe_snapshot：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 source 用于执行 capture_cqe_snapshot；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：capture_cqe_snapshot 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function rdma_status capture_cqe_snapshot(uvm_object source);
    return capture_cqe(source);
  endfunction

  // 功能：执行 set_cqe_snapshot 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：参数 source 用于执行 set_cqe_snapshot；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：set_cqe_snapshot 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  function rdma_status set_cqe_snapshot(uvm_object source);
    return capture_cqe(source);
  endfunction

  // 功能：执行 set_failure 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：参数 cloned 用于执行 set_failure；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
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
  // 输入/输出及副作用：参数 source 用于执行 set_failure_status；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：set_failure_status 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  function rdma_status set_failure_status(rdma_status source);
    return set_failure(source);
  endfunction

  // 功能：处理 capture_failure_status：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 source 用于执行 capture_failure_status；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：capture_failure_status 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function rdma_status capture_failure_status(rdma_status source);
    return set_failure(source);
  endfunction

  // 功能：处理 capture_image：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 cloned 用于执行 capture_image；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：capture_image 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
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
  // 输入/输出及副作用：参数 phase 用于执行 mark_mmio_maybe_submitted；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
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

  // 功能：执行一次受控事务并推进所属状态机；返回结果时保留失败阶段、代际和后端提交证据。
  // 输入/输出及副作用：参数 action, caller_confirmed_no_submit 用于执行 recover；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：事务超时、代际变化或提交证据不完整时不得推进下一阶段。
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
  // 输入/输出及副作用：参数 index, plan 用于执行 mark_wqe_release；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
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

  // 功能：处理 complete：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 phase 用于执行 complete；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：complete 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
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
  // 功能：处理 abort：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 phase 用于执行 abort；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：abort 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function rdma_status abort();
    if (aborted || phase == RDMA_QUEUE_TXN_COMPLETED)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "transaction is terminal");
    aborted = 1'b1;
    return rdma_status::success();
  endfunction
endclass
