// 目录/层次：tests/unit，runtime 恢复提交授权的双入口契约测试。
// 职责：对照普通/noalloc 的证据矩阵、授权消费、拒绝原子性与 factory 锁窗口。
// 依赖：rdma_queue_runtime_test 的断言和公开 consumer fixture、UVM raw factory。
// 所有权/生命周期：各 case 独占 runtime/pending/status；probe 只注入防御式状态，
//   不连接外部 adapter。工厂 observer 只借用当前 probe，调用结束即解除观测。

// 设计说明：公开 admission 会排除损坏 shadow、已开 gate 配坏证据等组合；
// probe 专用于检验 gate 自身的防御边界，正向 CI 提交另用公开 fixture 验证。
class rdma_runtime_commit_gate_probe extends rdma_queue_runtime;
  `uvm_object_utils(rdma_runtime_commit_gate_probe)

  // 功能：构造未配置 runtime，沿用生产唯一 semaphore 与默认关闭的授权位。
  // 输入/输出及副作用：name 传给基类；不建立 queue、pending 或外部资源。
  // 失败/边界：必须 seed 测试证据或通过公开 configure 后才能进行对应测试。
  function new(string name = "rdma_runtime_commit_gate_probe");
    super.new(name);
  endfunction

  // 功能：seed 组合 runtime state、pending 及两个授权位，覆盖公开 admission 不可达状态。
  // 输入/输出及副作用：phase、pending、confirmed、allowed 写入当前独占 fixture；
  //   pending 为测试借用引用，函数不复制或改变其字段。
  // 失败/边界：仅允许没有其它线程访问的测试对象；不伪装成合法生产 admission。
  function void seed(rdma_queue_runtime_state_e phase,
                     rdma_queue_pending_operation pending,
                     bit confirmed, bit allowed);
    state = phase;
    pending_operation_state = pending;
    recovery_retry_confirmed = confirmed;
    recovery_commit_allowed = allowed;
  endfunction

  // 功能：flags 返回 commit/retry 两个位，验证成功只消费指定授权、失败保持原值。
  // 输入/输出及副作用：无输入；返回 {allowed, confirmed}，只读本地 fixture。
  // 失败/边界：此无锁 probe 仅供同步函数测试及 factory 回调观察，不能替代生产查询。
  function bit [1:0] flags();
    return {recovery_commit_allowed, recovery_retry_confirmed};
  endfunction

  // 功能：lock_free 探测唯一 semaphore 是否可取，并立即归还取得的 token。
  // 输入/输出及副作用：无输入；返回锁可用性，不分配 status，避免 factory 回调递归。
  // 失败/边界：null 或已占用返回 0；成功探测不会额外增加 token。
  function bit lock_free();
    if (lock == null || !lock.try_get(1)) return 1'b0;
    lock.put(1);
    return 1'b1;
  endfunction

  // 功能：remove_lock 注入未构造 semaphore，验证两个入口的忙状态拒绝优先级。
  // 输入/输出及副作用：无输入输出；只把独占 fixture 的 lock 清空。
  // 失败/边界：仅可用于本 case 结束即丢弃的对象，禁止持锁时调用。
  function void remove_lock();
    lock = null;
  endfunction

  // 功能：hold_lock 暂时持有 token，构造真实并发调用的 RESOURCE_BUSY 窗口。
  // 输入/输出及副作用：无参数；取得 token 后等待 2ns 并归还，不改业务字段。
  // 失败/边界：测试要求初始锁可用，否则报告 fatal；不能取消本 task 造成锁泄漏。
  task hold_lock();
    if (lock == null || !lock.try_get(1))
      `uvm_fatal("GATE_LOCK", "fixture lock unavailable")
    #2ns;
    lock.put(1);
  endtask
endclass

// 设计说明：raw wrapper 可同时记录 factory 调用时的锁/授权，并返回 null/错型；
// 由生产 fallback 决定最终 status，不在测试中实现被测状态构造逻辑。
class rdma_runtime_gate_status_observer extends uvm_object_wrapper;
  rdma_runtime_commit_gate_probe observed;
  int unsigned mode;
  bit free_at_create[$];
  bit [1:0] flags_at_create[$];

  // 功能：返回 observer 的固定类型名，供 UVM factory 登记非致命 wrapper。
  // 输入/输出及副作用：无输入；返回字符串，不修改 factory 或 probe。
  // 失败/边界：该名称仅用于测试识别，不作为 RDMA authority。
  virtual function string get_type_name();
    return "rdma_runtime_gate_status_observer";
  endfunction

  // 功能：create_object 记录当前 probe 的锁/授权，再按 mode 创建正常、null 或错型结果。
  // 输入/输出及副作用：name 传给直接 new 的对象；observed 非空时追加两份观测队列。
  // 失败/边界：mode=1 返回 null、mode=2 返回既有 wrong_factory_object；不递归调用 factory。
  virtual function uvm_object create_object(string name = "");
    rdma_status status;
    rdma_queue_runtime_wrong_factory_object wrong;

    if (observed != null) begin
      free_at_create.push_back(observed.lock_free());
      flags_at_create.push_back(observed.flags());
    end
    if (mode == 1)
      return null;
    if (mode == 2) begin
      wrong = new(name);
      return wrong;
    end
    status = new(name);
    return status;
  endfunction
endclass

// 设计说明：继承只复用断言与 consumer fixture，不调用父 run_phase；
// 一张显式期望表固定已有语义，包括失败不关闭已经打开的 gate。
class rdma_runtime_commit_gate_test extends rdma_queue_runtime_test;
  `uvm_component_utils(rdma_runtime_commit_gate_test)

  int unsigned cases;
  rdma_runtime_gate_status_observer observer;

  // 功能：构造独立授权测试 component，cases 默认为零，observer 留到 run_phase 安装。
  // 输入/输出及副作用：name/parent 传给父类，不安装父类 factory fault wrappers。
  // 失败/边界：本 test 不运行父类大矩阵，避免完整 core 重复执行同一组测试。
  function new(string name = "rdma_runtime_commit_gate_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：check_call 对两个公开入口执行同一断言，核对诊断、授权、锁归还及 factory 时机。
  // 输入/输出及副作用：runtime/noalloc、期望 code/message/flags 及 busy 描述本 case；
  //   noalloc 使用预建且带脏字段的 status，普通入口接收新对象；成功递增 cases。
  // 失败/边界：code/text、状态字段清理、锁/回调次数或授权不符均报 UVM_ERROR；
  //   忙分支只产生一次普通 factory 调用，noalloc 永远不得调用 factory。
  function void check_call(rdma_runtime_commit_gate_probe runtime, bit noalloc,
                          rdma_status_code_e code, string message,
                          bit [1:0] expected_flags, bit busy = 1'b0);
    rdma_status status;
    bit ok;
    bit [1:0] before_flags;

    before_flags = runtime.flags();
    status = new("preallocated_status");
    status.hardware_code_valid = 1'b1;
    status.function_uid = '1;
    status.retryable = 1'b1;
    observer.free_at_create.delete();
    observer.flags_at_create.delete();
    observer.observed = runtime;
    if (noalloc)
      ok = runtime.enable_recovery_commit_noalloc(status);
    else begin
      status = runtime.enable_recovery_commit();
      ok = status != null && status.ok();
    end
    observer.observed = null;
    expect_code("GATE_STATUS", status, code);
    if (status == null)
      return;
    if (ok != (code == RDMA_SC_OK) || status.message != message ||
        status.hardware_code_valid || status.function_uid != 0 || status.retryable ||
        status.category != rdma_status::category_for(code))
      `uvm_error("GATE_DIAGNOSTIC", status.convert2string())
    if (runtime.flags() != expected_flags || runtime.lock_free() == busy)
      `uvm_error("GATE_ATOMIC", "authorization or lock state changed incorrectly")
    if (observer.free_at_create.size() != (noalloc ? 0 : (busy ? 1 : 2)))
      `uvm_error("GATE_FACTORY", "factory count differs from legacy contract")
    if (!noalloc && observer.free_at_create.size() != 0) begin
      if (observer.free_at_create[0] || observer.flags_at_create[0] != before_flags)
        `uvm_error("GATE_FACTORY", "lock admission callback moved after mutation")
      if (!busy && (!observer.free_at_create[1] ||
                    observer.flags_at_create[1] != expected_flags))
        `uvm_error("GATE_FACTORY", "result callback moved inside lock or before commit")
    end
    cases++;
  endfunction

  // 功能：evidence_matrix 穷举两入口、五种 evidence、四种 shadow 状态和初始授权组合，
  //   每个组合再次调用，验证 no-submit 的 confirmation 只能消费一次。
  // 输入/输出及副作用：无参数；每 case 新建独占 probe/pending，期望由显式 evidence 表给出。
  // 失败/边界：shadow=2/3 代表 published 合法/坏长度；只有 NO_SUBMIT 的合法 shadow
  //   可绕过 retry confirmation，其余 published 组合必须优先报 shadow 不完整。
  task evidence_matrix();
    rdma_queue_mmio_evidence_e evidence[5] = '{RDMA_QUEUE_MMIO_NONE,
      RDMA_QUEUE_MMIO_NOT_APPLICABLE, RDMA_QUEUE_MMIO_NO_SUBMIT,
      RDMA_QUEUE_MMIO_SUCCESS, RDMA_QUEUE_MMIO_AMBIGUOUS};
    rdma_runtime_commit_gate_probe runtime;
    rdma_queue_pending_operation pending;
    rdma_status_code_e code;
    string message;
    bit next_confirmed;

    for (int api = 0; api < 2; api++)
      for (int ev = 0; ev < 5; ev++)
        for (int shadow = 0; shadow < 4; shadow++)
          for (int confirmed = 0; confirmed < 2; confirmed++)
            for (int allowed = 0; allowed < 2; allowed++) begin
              runtime = new("matrix_runtime");
              pending = new("matrix_pending");
              pending.kind = RDMA_QUEUE_RUNTIME_CQ;
              pending.mmio_evidence = evidence[ev];
              pending.consumer_shadow_required = shadow != 0;
              pending.consumer_shadow_attempted = shadow >= 2;
              pending.consumer_shadow_published = shadow >= 2;
              pending.consumer_shadow_offset = RDMA_CQC_RUNTIME_SHADOW_BYTE_OFFSET;
              pending.consumer_shadow_length = shadow == 3 ? 0 :
                RDMA_CQC_RUNTIME_SHADOW_BYTE_LENGTH;
              runtime.seed(RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED, pending,
                           bit'(confirmed), bit'(allowed));
              code = RDMA_SC_OK;
              message = "";
              next_confirmed = bit'(confirmed);
              if (shadow >= 2) begin
                if (shadow == 3 || ev != 2) begin
                  code = RDMA_SC_INVALID_STATE;
                  message = "CQ shadow publication is incomplete";
                end
              end
              else begin
                case (ev)
                  0, 4: begin
                    code = RDMA_SC_RECOVERY_REQUIRED;
                    message = "recovery commit lacks definitive MMIO evidence";
                  end
                  1, 2: begin
                    if (!confirmed) begin
                      code = RDMA_SC_INVALID_STATE;
                      message = "recovery commit lacks retry confirmation";
                    end
                    else next_confirmed = 1'b0;
                  end
                  default:;
                endcase
              end
              check_call(runtime, bit'(api), code, message,
                         {code == RDMA_SC_OK ? 1'b1 : bit'(allowed), next_confirmed});
              if (pending.mmio_evidence != evidence[ev] || runtime.used != 0 ||
                  runtime.consumer_index != 0 || runtime.producer_index != 0 ||
                  runtime.state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED)
                `uvm_error("GATE_EVIDENCE", "gate changed evidence, cursor or lifecycle")
              if (code == RDMA_SC_OK && shadow < 2 && (ev == 1 || ev == 2))
                check_call(runtime, bit'(api), RDMA_SC_INVALID_STATE,
                           "recovery commit lacks retry confirmation", 2'b10);
              else
                check_call(runtime, bit'(api), code, message,
                           {code == RDMA_SC_OK ? 1'b1 : bit'(allowed), next_confirmed});
            end
  endtask

  // 功能：boundary_matrix 验证缺 pending/错误状态、null/busy lock、null slot 和三种 factory 结果。
  // 输入/输出及副作用：无参数；短时并发持锁后复用同一 runtime；模式窗口结束恢复 observer。
  // 失败/边界：null slot 优先返回 0 且不触碰锁/授权；故障 factory 仍须返回原错误/成功码。
  task boundary_matrix();
    rdma_runtime_commit_gate_probe runtime;
    rdma_queue_pending_operation pending;

    for (int api = 0; api < 2; api++) begin
      pending = new("boundary_pending");
      pending.mmio_evidence = RDMA_QUEUE_MMIO_SUCCESS;
      for (int missing = 0; missing < 2; missing++) begin
        runtime = new("absent_runtime");
        runtime.seed(missing ? RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED : RDMA_QUEUE_RUNTIME_ACTIVE,
                     missing ? null : pending, 1'b1, 1'b1);
        check_call(runtime, bit'(api), RDMA_SC_INVALID_STATE,
                   "queue runtime has no pending recovery", 2'b11);
      end
      runtime = new("null_lock_runtime");
      runtime.seed(RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED, pending, 1'b1, 1'b0);
      runtime.remove_lock();
      check_call(runtime, bit'(api), RDMA_SC_RESOURCE_BUSY, "queue runtime is busy", 2'b01, 1'b1);
      runtime = new("busy_runtime");
      runtime.seed(RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED, pending, 1'b1, 1'b0);
      fork
        runtime.hold_lock();
        begin
          #1ns;
          check_call(runtime, bit'(api), RDMA_SC_RESOURCE_BUSY,
                     "queue runtime is busy", 2'b01, 1'b1);
        end
      join
      check_call(runtime, bit'(api), RDMA_SC_OK, "", 2'b11);
      for (int mode = 0; mode < 3; mode++) begin
        observer.mode = mode;
        runtime.seed(RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED, pending, 1'b1, 1'b0);
        check_call(runtime, bit'(api), RDMA_SC_OK, "", 2'b11);
        runtime.seed(RDMA_QUEUE_RUNTIME_ACTIVE, null, 1'b1, 1'b0);
        check_call(runtime, bit'(api), RDMA_SC_INVALID_STATE,
                   "queue runtime has no pending recovery", 2'b01);
      end
      observer.mode = 0;
    end
    runtime = new("null_slot_runtime");
    runtime.seed(RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED, pending, 1'b1, 1'b0);
    if (runtime.enable_recovery_commit_noalloc(null) ||
        runtime.flags() != 2'b01 || !runtime.lock_free())
      `uvm_error("GATE_NULL_SLOT", "null slot touched authorization or lock")
    cases++;
  endtask

  // 功能：public_consumer_commit 用公开 admission→授权→CI commit→complete 验证真实 consumer 流程。
  // 输入/输出及副作用：无参数；两入口各运行一个 CQ，预留一条 device entry 后消费并恢复 ACTIVE。
  // 失败/边界：任何阶段失败报错；完成必须清空 pending、仅推进一次 CI，并归还唯一 credit。
  task public_consumer_commit();
    rdma_queue_runtime runtime;
    rdma_queue_pending_operation pending;
    rdma_status status;

    for (int api = 0; api < 2; api++) begin
      status = make_consumer_recovery_fixture("public_gate", 90 + api, 8'h45,
        RDMA_QUEUE_MMIO_SUCCESS, runtime, pending);
      expect_ok("GATE_FIXTURE", status);
      if (status == null || !status.ok()) return;
      expect_ok("GATE_ENTER", runtime.enter_recovery_prepared(pending));
      if (api) begin
        status = new("public_gate_status");
        if (!runtime.enable_recovery_commit_noalloc(status))
          `uvm_error("GATE_PUBLIC", "noalloc gate rejected valid consumer")
      end
      else status = runtime.enable_recovery_commit();
      expect_ok("GATE_PUBLIC", status);
      expect_ok("GATE_COMMIT", runtime.commit_consumer(pending.cursor));
      expect_ok("GATE_COMPLETE", runtime.complete_recovery_retry());
      if (runtime.state != RDMA_QUEUE_RUNTIME_ACTIVE || runtime.used != 0 ||
          runtime.consumer_index != 1 || runtime.pending_operation() != null)
        `uvm_error("GATE_PUBLIC", "consumer did not finish exactly once")
      cases++;
    end
  endtask

  // 功能：run_phase 安装 status observer，执行 345 个授权案例并发布完成标记。
  // 输入/输出及副作用：phase 管理 objection；只运行本 test 的三组矩阵，不执行父 run_phase。
  // 失败/边界：用 1us watchdog 捕获锁泄漏/挂起；计数不足或任一断言失败不能视为通过。
  task run_phase(uvm_phase phase);
    uvm_factory factory;

    phase.raise_objection(this);
    observer = new();
    factory = uvm_factory::get();
    factory.set_type_override_by_type(rdma_status::get_type(), observer, 1'b1);
    fork
      begin
        evidence_matrix();
        boundary_matrix();
        public_consumer_commit();
        if (cases != 345)
          `uvm_error("GATE_MATRIX", $sformatf("unexpected count %0d", cases))
        `uvm_info("GATE_MATRIX", $sformatf(
          "completed %0d recovery commit gate cases", cases), UVM_LOW)
      end
      begin
        #1us;
        `uvm_fatal("GATE_WATCHDOG", "recovery gate matrix timed out")
      end
    join_any
    disable fork;
    phase.drop_objection(this);
  endtask
endclass
