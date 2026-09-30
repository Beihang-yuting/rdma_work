// 目录/层次：tests/unit，queue runtime 恢复结束的四入口对照测试。
// 职责：固定完成/中止后的证据清理、游标/账本保留、拒绝原子性与 factory 锁窗口。
// 依赖：rdma_queue_runtime_test 的身份/route fixture、断言和真实 consumer 流程。
// 所有权/生命周期：每例独占 runtime；probe 借用 pending 的测试别名以观察末次 marker，
//   不接入外部资源。observer 只在同步被测调用内借用 probe，结束即解除绑定。

// 设计说明：公开 configure 建立真实 attachment/ledger；其后只注入恢复末阶段，
// 以覆盖所有 gate 组合及不可达坏状态，不把这张矩阵称为完整 admission 验证。
class rdma_runtime_retirement_probe extends rdma_queue_runtime;
  `uvm_object_utils(rdma_runtime_retirement_probe)

  // 功能：构造未配置 probe，沿用生产默认 DETACHED 状态和唯一 semaphore。
  // 输入/输出及副作用：name 传给基类；不创建 pending 或外部资源。
  // 失败/边界：测试必须先 configure 再注入恢复末阶段。
  function new(string name = "rdma_runtime_retirement_probe");
    super.new(name);
  endfunction

  // 功能：stage_terminal 注入完成入口需要的 cursor/ledger 与待清理恢复位。
  // 输入/输出及副作用：pending 为借用引用，role=0/1/2 表示 consumer/host/device
  //   producer；flags 写入 commit/release/retry，保留非空 reservation 以检验清理。
  // 失败/边界：仅用于已 configure 的独占 fixture；device producer 的 valid 位须为零，
  //   其余方向故意保留有效 reservation，不代表合法 admission 会产生这些组合。
  function void stage_terminal(rdma_queue_pending_operation pending,
                               int role, bit [2:0] flags);
    pending_operation_state = pending;
    device_reservation = new("retained_reservation");
    device_reservation_valid = role != 2;
    {recovery_commit_allowed, consumer_release_gate_active,
     recovery_retry_confirmed} = flags;
    state = RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED;
    producer_index = role == 0 ? 2 : 1;
    consumer_index = role == 0 ? 1 : 0;
    used = 1;
    if (role == 1) begin
      slots[0].index = 0;
      slots[0].wrap = 1'b0;
      slots[0].posted = 1'b1;
      slots[0].consumed = 1'b0;
    end
  endfunction

  // 功能：recovery_bits 直接观察六项恢复引用/标志，检验一次性清理和失败保留。
  // 输入/输出及副作用：无参数；返回 pending/reservation-valid/reservation/三 gate，只读。
  // 失败/边界：只用于同步测试和 factory 回调，不替代生产带锁查询。
  function bit [5:0] recovery_bits();
    return {pending_operation_state != null, device_reservation_valid,
            device_reservation != null, recovery_commit_allowed,
            consumer_release_gate_active, recovery_retry_confirmed};
  endfunction

  // 功能：preserved_values 记录结束恢复不应改写的身份、authority、ring 和 slot 值/对象身份。
  // 输入/输出及副作用：无参数；返回包含所有 slot 身份与账本字段的字符串，不调用 factory。
  // 失败/边界：仅在 configure 成功后调用；不包含预期会变更的恢复字段和 state。
  function string preserved_values();
    string result;
    result = $sformatf("%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d",
      queue_h.get_inst_id(), queue_h.kind, queue_h.function_uid, queue_h.object_id,
      queue_h.generation, kind, host_produced, initial_polarity, depth, producer_index,
      consumer_index, producer_wrap, consumer_wrap, used, route, route_valid, reset_epoch);
    result = {result, $sformatf("/%0d/%0d", epoch_valid, slots.size())};
    foreach (slots[i])
      result = {result, $sformatf("/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d",
        slots[i].get_inst_id(), slots[i].index, slots[i].wrap, slots[i].posted,
        slots[i].consumed, slots[i].wr_id, slots[i].signaled,
        slots[i].request_snapshot == null ? 0 : slots[i].request_snapshot.get_inst_id(),
        slots[i].image == null ? 0 : slots[i].image.get_inst_id(),
        slots[i].completion_status == null ? 0 : slots[i].completion_status.get_inst_id())};
    return result;
  endfunction

  // 功能：lock_tokens 检查锁恰有 expected 个 token，防止丢锁或重复归还。
  // 输入/输出及副作用：expected 为 0/1；最多取两次并原数归还，不构造 status。
  // 失败/边界：null 锁视为零；多于一个 token 始终与有效 fixture 预期不符。
  function bit lock_tokens(int expected);
    int count;
    count = 0;
    if (lock != null) begin
      repeat (2) if (lock.try_get(1)) count++;
      if (count != 0) lock.put(count);
    end
    return count == expected;
  endfunction

  // 功能：inject_boundary 建立缺 pending、错误 state、null lock 或真实占锁的拒绝条件。
  // 输入/输出及副作用：fault=0/1/2/3 分别清 pending、设 ACTIVE、清 lock、取走 token。
  // 失败/边界：只用于本例结束即丢弃的 fixture；占锁失败报 fatal，不伪造 busy。
  function void inject_boundary(int fault);
    case (fault)
      0: pending_operation_state = null;
      1: state = RDMA_QUEUE_RUNTIME_ACTIVE;
      2: lock = null;
      3: if (!lock.try_get(1)) `uvm_fatal("RETIRE_LOCK", "cannot hold fixture lock")
      default: `uvm_fatal("RETIRE_FIXTURE", "unknown fault")
    endcase
  endfunction
endclass

// 设计说明：raw factory observer 保留正常/null/错型三种返回，直接 new 避免回调递归；
// 既观察 acquire 的锁内旧值，也观察解锁后最终状态，noalloc 则必须零次回调。
class rdma_runtime_retirement_observer extends uvm_object_wrapper;
  rdma_runtime_retirement_probe observed;
  int mode;
  bit locked[$];
  bit [5:0] recovery[$];
  rdma_queue_runtime_state_e states[$];

  // 功能：返回独立 observer 类型名，供本专项安装 raw status override。
  // 输入/输出及副作用：无参数；返回常量，不修改 runtime 或 factory。
  // 失败/边界：该名称不是生产类型 authority。
  virtual function string get_type_name();
    return "rdma_runtime_retirement_observer";
  endfunction

  // 功能：create_object 捕获当前锁与恢复字段，然后返回正常、null 或错型对象。
  // 输入/输出及副作用：name 传给直接构造；observed 非空时追加三份观测队列。
  // 失败/边界：mode=1/2 注入 null/错型，生产 fallback 仍须交付原状态码；不递归 factory。
  virtual function uvm_object create_object(string name = "");
    rdma_status status;
    rdma_queue_runtime_wrong_factory_object wrong;
    if (observed != null) begin
      locked.push_back(observed.lock_tokens(0));
      recovery.push_back(observed.recovery_bits());
      states.push_back(observed.state);
    end
    if (mode == 1) begin
      return null;
    end
    if (mode == 2) begin
      wrong = new(name);
      return wrong;
    end
    status = new(name);
    return status;
  endfunction
endclass

// 设计说明：显式期望固定四个公开入口的不同拒绝文本和最终状态；不调用内部清理。
// 继承仅复用 fixture/断言，不执行父 run_phase，不扩大既有 logical test 的运行次数。
class rdma_runtime_recovery_retirement_test extends rdma_queue_runtime_test;
  `uvm_component_utils(rdma_runtime_recovery_retirement_test)
  rdma_runtime_retirement_observer observer;
  int cases;

  // 功能：构造独立恢复结束专项，计数默认零，observer 留待 run_phase 安装。
  // 输入/输出及副作用：name/parent 传给父类，不持有外部 adapter 或资源。
  // 失败/边界：未进入 run_phase 前不安装工厂 override。
  function new(string name = "rdma_runtime_recovery_retirement_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：fixture 建立真实配置后注入 host/device/consumer 的恢复末阶段。
  // 输入/输出及副作用：k/role/flags 选择方向与 gate；runtime/pending 输出归本例拥有，
  //   pending 别名用于拒绝故障与末次 CQ release marker 观察。
  // 失败/边界：configure/authority/activate 失败立即 fatal；不以坏 fixture 继续测试清理。
  function void fixture(rdma_queue_runtime_kind_e k, int role, bit [2:0] flags,
                        output rdma_runtime_retirement_probe runtime,
                        output rdma_queue_pending_operation pending);
    rdma_resource_kind_e resource_kind;
    rdma_handle qh;
    rdma_status status;
    case (k)
      RDMA_QUEUE_RUNTIME_CQ: resource_kind = RDMA_RESOURCE_CQ;
      RDMA_QUEUE_RUNTIME_CEQ: resource_kind = RDMA_RESOURCE_CEQ;
      RDMA_QUEUE_RUNTIME_AEQ: resource_kind = RDMA_RESOURCE_AEQ;
      RDMA_QUEUE_RUNTIME_SRQ: resource_kind = RDMA_RESOURCE_SRQ;
      default: resource_kind = RDMA_RESOURCE_QP;
    endcase
    runtime = new("retirement_runtime");
    qh = queue_handle("retirement_queue", resource_kind, 43);
    status = runtime.configure(qh, k, 4, 0, 0, 0, 0, role == 1, 1'b1);
    if (status == null || !status.ok()) `uvm_fatal("RETIRE_FIXTURE", "configure failed")
    status = runtime.set_route_epoch(fixture_route(8'h43), 64'h443);
    if (status == null || !status.ok()) `uvm_fatal("RETIRE_FIXTURE", "authority failed")
    status = runtime.activate();
    if (status == null || !status.ok()) `uvm_fatal("RETIRE_FIXTURE", "activate failed")
    pending = new("terminal_pending");
    pending.queue_h = qh;
    pending.kind = k;
    pending.producer = role == 1;
    pending.device_producer = role == 2;
    pending.device_write_attempted = role == 2;
    pending.cursor = new("old_cursor");
    pending.next_cursor = new("next_cursor");
    pending.next_cursor.index = 1;
    pending.entry_size = 64;
    pending.entry_offset = 0;
    pending.mmio_evidence = role == 2 ? RDMA_QUEUE_MMIO_NOT_APPLICABLE : RDMA_QUEUE_MMIO_SUCCESS;
    pending.consumer_doorbell_succeeded = role == 0;
    pending.consumer_committed = role == 0;
    pending.cq_consumer_committed = k == RDMA_QUEUE_RUNTIME_CQ && role == 0;
    pending.committed_consumer_cursor = role == 0 ? pending.next_cursor : null;
    pending.failure_status = new("failure_slot");
    runtime.stage_terminal(pending, role, flags);
  endfunction

  // 功能：check_call 调用四个公开完成/中止入口之一，核对精确诊断、状态、锁与 factory 时序。
  // 输入/输出及副作用：api=0/1/2/3 对应 complete/noalloc/abort/recover；code/message、
  //   bits/final_state 为显式期望；slot 可与 pending.failure_status 别名，busy 指示不应归还锁。
  // 失败/边界：noalloc 零 factory，普通 busy 一次否则两次；非恢复字段变化、回调提前清理、
  //   重复解锁或 status 残留 authority 均报错；返回 bool 必须等于期望 code 是否 OK。
  function void check_call(rdma_runtime_retirement_probe runtime, int api,
                           rdma_status_code_e code, string message,
                           bit [5:0] bits, rdma_queue_runtime_state_e final_state,
                           rdma_status slot, bit release_now = 1'b0, bit busy = 1'b0);
    rdma_status status;
    bit ok;
    bit [5:0] before_bits;
    rdma_queue_runtime_state_e before_state;
    string before_values;
    before_bits = runtime.recovery_bits();
    before_state = runtime.state;
    before_values = runtime.preserved_values();
    status = slot;
    status.hardware_code_valid = 1'b1;
    status.function_uid = '1;
    status.retryable = 1'b1;
    observer.locked.delete();
    observer.recovery.delete();
    observer.states.delete();
    observer.observed = runtime;
    case (api)
      0: status = runtime.complete_recovery_retry();
      1: ok = runtime.complete_consumer_recovery_noalloc(release_now, status);
      2: status = runtime.abort_recovery();
      3: status = runtime.recover(RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH);
      default: `uvm_fatal("RETIRE_API", "unknown API")
    endcase
    observer.observed = null;
    if (api != 1) ok = status != null && status.ok();
    expect_code("RETIRE_STATUS", status, code);
    if (status == null) begin
      return;
    end
    if (ok != (code == RDMA_SC_OK) || status.message != message ||
        status.hardware_code_valid || status.function_uid != 0 || status.retryable ||
        status.category != rdma_status::category_for(code) || (api == 1 && status != slot))
      `uvm_error("RETIRE_STATUS", status.convert2string())
    if (runtime.recovery_bits() != bits || runtime.state != final_state ||
        runtime.preserved_values() != before_values || !runtime.lock_tokens(busy ? 0 : 1))
      `uvm_error("RETIRE_STATE", "recovery, attachment, ledger or lock contract changed")
    if (observer.locked.size() != (api == 1 ? 0 : (busy ? 1 : 2)))
      `uvm_error("RETIRE_FACTORY", "wrong factory count")
    if (api != 1 && observer.locked.size() == (busy ? 1 : 2)) begin
      if (!observer.locked[0] || observer.recovery[0] != before_bits ||
          observer.states[0] != before_state)
        `uvm_error("RETIRE_FACTORY", "admission callback moved outside lock or after clearing")
      if (!busy && (observer.locked[1] || observer.recovery[1] != bits ||
                    observer.states[1] != final_state))
        `uvm_error("RETIRE_FACTORY", "result callback moved before unlock or commit")
    end
    cases++;
  endfunction

  // 功能：successful_pair 验证完成/中止成功及再次调用的非幂等 INVALID_STATE。
  // 输入/输出及副作用：runtime/pending 为当前 fixture，api 决定 ACTIVE/DETACHED；
  //   noalloc 使用 pending.failure_status 原对象，release_now 合并旧别名的末次 release 位。
  // 失败/边界：成功不擦写旧 pending 内容，唯有 noalloc 明确要求的 CQ release marker 可置位。
  function void successful_pair(rdma_runtime_retirement_probe runtime,
                                rdma_queue_pending_operation pending, int api,
                                bit release_now = 1'b0);
    rdma_queue_runtime_state_e final_state;
    final_state = api < 2 ? RDMA_QUEUE_RUNTIME_ACTIVE : RDMA_QUEUE_RUNTIME_DETACHED;
    check_call(runtime, api, RDMA_SC_OK, "", 6'b0, final_state,
               pending.failure_status, release_now);
    if (pending.completion_released != release_now || pending.next_cursor.index != 1)
      `uvm_error("RETIRE_ALIAS", "retained pending alias lost final marker or cursor")
    check_call(runtime, api, RDMA_SC_INVALID_STATE,
      api == 1 ? "consumer recovery stages are incomplete" :
                 "queue runtime has no pending recovery",
      6'b0, final_state, pending.failure_status);
  endfunction

  // 功能：matrix 穷举四入口、三种 status factory、八组 gate，并覆盖六 queue kind 的终止方向。
  // 输入/输出及副作用：无参数；每例独占 fixture，CQ noalloc 合并 release_now 并检查旧别名。
  // 失败/边界：仅测试恢复结束，不代替 host/device 外部传输和全部 admission；失败立即由断言报告。
  task matrix();
    rdma_runtime_retirement_probe runtime;
    rdma_queue_pending_operation pending;
    rdma_queue_runtime_kind_e kinds[6] = '{RDMA_QUEUE_RUNTIME_SQ, RDMA_QUEUE_RUNTIME_RQ,
      RDMA_QUEUE_RUNTIME_SRQ, RDMA_QUEUE_RUNTIME_CQ,
      RDMA_QUEUE_RUNTIME_CEQ, RDMA_QUEUE_RUNTIME_AEQ};
    for (int mode = 0; mode < 3; mode++)
      for (int api = 0; api < 4; api++)
        for (int flags = 0; flags < 8; flags++) begin
          observer.mode = 0;
          fixture(RDMA_QUEUE_RUNTIME_CQ, 0, 3'(flags), runtime, pending);
          pending.completion_target_valid = api == 1;
          observer.mode = mode;
          successful_pair(runtime, pending, api, api == 1);
        end
    observer.mode = 0;
    foreach (kinds[i]) begin
      fixture(kinds[i], i < 3 ? 1 : 0, 3'b111, runtime, pending);
      successful_pair(runtime, pending, 0);
      if (i >= 3) begin
        fixture(kinds[i], 2, 3'b111, runtime, pending);
        successful_pair(runtime, pending, 0);
        fixture(kinds[i], 0, 3'b111, runtime, pending);
        successful_pair(runtime, pending, 1);
      end
    end
  endtask

  // 功能：boundaries 验证缺 pending/错误 state/null 或 busy 锁、未完成 CQ release 与 null slot。
  // 输入/输出及副作用：无参数；拒绝后保留全部恢复位，修复 release 证据后用原 fixture 重试。
  // 失败/边界：noalloc null slot 必须在任何锁操作/factory 之前拒绝；占锁 fixture 随例丢弃，
  //   不以人工归还掩盖入口误归还；缺 release 的普通和 noalloc 均不得提前丢失 pending。
  task boundaries();
    rdma_runtime_retirement_probe runtime;
    rdma_queue_pending_operation pending;
    for (int api = 0; api < 4; api++)
      for (int fault = 0; fault < 4; fault++) begin
        fixture(RDMA_QUEUE_RUNTIME_CQ, 0, 3'b111, runtime, pending);
        runtime.inject_boundary(fault);
        check_call(runtime, api, fault >= 2 ? RDMA_SC_RESOURCE_BUSY : RDMA_SC_INVALID_STATE,
          fault >= 2 ? "queue runtime is busy" :
            (api == 1 ? "consumer recovery stages are incomplete" :
                        "queue runtime has no pending recovery"),
          runtime.recovery_bits(), runtime.state, pending.failure_status, 0, fault >= 2);
      end
    for (int api = 0; api < 2; api++) begin
      fixture(RDMA_QUEUE_RUNTIME_CQ, 0, 3'b111, runtime, pending);
      pending.completion_target_valid = 1'b1;
      check_call(runtime, api, RDMA_SC_INVALID_STATE, "CQ completion release is incomplete",
        runtime.recovery_bits(), runtime.state, pending.failure_status);
      pending.completion_target_valid = 1'b0;
      successful_pair(runtime, pending, api);
    end
    fixture(RDMA_QUEUE_RUNTIME_CQ, 0, 3'b111, runtime, pending);
    observer.locked.delete();
    observer.observed = runtime;
    if (runtime.complete_consumer_recovery_noalloc(1'b1, null) ||
        runtime.recovery_bits() != 6'b111111 || !runtime.lock_tokens(1) ||
        observer.locked.size() != 0)
      `uvm_error("RETIRE_NULL", "null slot mutated runtime or entered factory")
    observer.observed = null;
    cases++;
  endtask

  // 功能：public_flow 从真实 device publication、prepared admission 和 consumer CI commit 验证两种完成。
  // 输入/输出及副作用：无参数；复用父 fixture 但不注入 runtime 末阶段；完成后公开查询 pending/used。
  // 失败/边界：fixture 失败立即 fatal，其余步骤失败由断言报告；noalloc CQ 额外确认兼容
  //   CI marker；不得重复消费 occupancy。
  task public_flow();
    rdma_queue_runtime runtime;
    rdma_queue_pending_operation pending;
    rdma_status status;
    bit present;
    for (int api = 0; api < 2; api++) begin
      status = make_consumer_recovery_fixture("retire_public", 44, 8'h44,
        RDMA_QUEUE_MMIO_SUCCESS, runtime, pending);
      if (status == null || !status.ok()) `uvm_fatal("RETIRE_PUBLIC", "fixture failed")
      expect_ok("RETIRE_PUBLIC_ENTER", runtime.enter_recovery_prepared(pending));
      expect_ok("RETIRE_PUBLIC_GATE", runtime.enable_recovery_commit());
      expect_ok("RETIRE_PUBLIC_CI", runtime.commit_consumer(pending.cursor));
      if (api == 0) status = runtime.complete_recovery_retry();
      else begin
        expect_ok("RETIRE_PUBLIC_MARKER", runtime.mark_pending_cq_consumer_committed());
        if (!runtime.complete_consumer_recovery_noalloc(1'b0, status))
          `uvm_error("RETIRE_PUBLIC", "noalloc completion refused")
      end
      expect_ok("RETIRE_PUBLIC_COMPLETE", status);
      expect_ok("RETIRE_PUBLIC_QUERY", runtime.query_has_pending(present));
      if (present || runtime.used != 0 || runtime.consumer_index != 1 ||
          runtime.state != RDMA_QUEUE_RUNTIME_ACTIVE)
        `uvm_error("RETIRE_PUBLIC", "public completion did not preserve committed CI")
      cases++;
    end
  endtask

  // 功能：run_phase 安装 observer，执行独立恢复结束矩阵并以完成计数交付结果。
  // 输入/输出及副作用：phase objection 包围测试；结束解除观测，observer 恢复普通直接构造模式。
  // 失败/边界：1us watchdog 阻止挂死；不得运行父 run_phase 或保留故障/借用引用到下一阶段。
  task run_phase(uvm_phase phase);
    uvm_factory factory;
    phase.raise_objection(this);
    observer = new();
    factory = uvm_factory::get();
    factory.set_type_override_by_type(rdma_status::get_type(), observer, 1);
    fork
      begin
        matrix();
        boundaries();
        public_flow();
        if (cases != 241) `uvm_error("RETIRE_MATRIX", $sformatf("wrong count %0d", cases))
        `uvm_info("RETIRE_MATRIX", $sformatf(
          "completed %0d recovery retirement calls", cases), UVM_LOW)
      end
      begin
        #1us;
        `uvm_fatal("RETIRE_WATCHDOG", "retirement matrix timed out")
      end
    join_any
    disable fork;
    observer.observed = null;
    observer.mode = 0;
    phase.drop_objection(this);
  endtask
endclass
