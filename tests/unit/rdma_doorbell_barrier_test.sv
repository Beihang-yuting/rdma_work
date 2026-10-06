// 目录：测试层 tests/unit，doorbell barrier 的独立时序契约测试。
// 职责：验证四种 barrier policy、总 deadline、失败诊断、取消隔离与超时后的锁复用。
// 依赖：rdma_doorbell_scheduler_test 的 binding/descriptor/断言构造器及 mock PCIe。
// 所有权与生命周期：本测试拥有 scheduler、adapter 和值 fixture；只调用公开 submit_observed，
//   不访问 DUT protected helper，不接管外部资源；watchdog 限制整个矩阵的仿真时间。

// 设计：记录“进入”和“完成”两个时点，才能区分调用超时返回与后台 worker 真正被取消。
// peer_uid 使用独立延迟，使同一 scheduler 的另一个 Function 在超时发生时仍处于 barrier 内。
class rdma_timed_barrier_pcie extends rdma_mock_pcie;
  time dma_delay;
  time mmio_delay;
  longint unsigned peer_uid;
  time peer_delay;
  int unsigned failure_stage;
  bit return_null;
  rdma_status failure;
  int unsigned completions[longint unsigned];

  // 功能：构造无延迟、无故障的 PCIe fixture，并预建携带硬件码的原始错误。
  // 输入/输出及副作用：name 传给 mock；初始化本地配置，拥有 failure 和调用/完成记录。
  // 失败/边界：peer_uid=0 不匹配本测试有效 UID；不使用 factory 注入或修改 DUT 状态。
  function new(string name = "rdma_timed_barrier_pcie");
    super.new(name);
    dma_delay = 0;
    mmio_delay = 0;
    peer_uid = 0;
    peer_delay = 0;
    failure_stage = 0;
    return_null = 1'b0;
    failure = rdma_status::make_direct(RDMA_SC_DMA_TRANSLATION, "timed barrier failure");
    failure.hardware_code_valid = 1'b1;
    failure.hardware_code = 32'h10203040;
    completions.delete();
  endfunction

  // 功能：读取某个 Function 已完成的 barrier 数，供取消后无后台完成的断言使用。
  // 输入/输出及副作用：uid 输入，返回本地计数；不修改关联数组或调用 DUT。
  // 失败/边界：从未完成的 UID 返回零；该计数不包含 MMIO write。
  function int unsigned completed(longint unsigned uid);
    return completions.exists(uid) ? completions[uid] : 0;
  endfunction

  // 功能：记录指定 barrier 的进入，经过可控延迟后记录完成并交付成功/null/原始错误。
  // 输入/输出及副作用：stage=1/2 选择 DMA/MMIO，function_h 为借用引用，status 输出；
  //   peer_uid 仅使用 peer_delay，不注入错误；普通调用使用对应 delay/failure_stage。
  // 失败/边界：function_h 必须非空且 stage 为 1/2；被 DUT 取消的 worker 不得增加完成数。
  protected task respond(int unsigned stage, rdma_function_handle function_h,
                         output rdma_status status);
    void'(record_call(stage == 1 ? "dma_visibility_barrier" : "mmio_ordering_barrier",
                      '0, '0, '0, '0, function_h));
    if (function_h.function_uid == peer_uid)
      #(peer_delay);
    else if (stage == 1)
      #(dma_delay);
    else
      #(mmio_delay);
    completions[function_h.function_uid] = completed(function_h.function_uid) + 1;
    if (function_h.function_uid != peer_uid && failure_stage == stage)
      status = return_null ? null : failure;
    else
      status = rdma_status::make_direct(RDMA_SC_OK);
  endtask

  // 功能：让 DMA visibility barrier 进入可控时序 fixture。
  // 输入/输出及副作用：function_h 传给 stage=1 的 respond，status 输出其结果并记录一次调用。
  // 失败/边界：延迟期间允许 scheduler 取消；本 task 不另建后台线程或补偿副作用。
  virtual task dma_visibility_barrier(rdma_function_handle function_h, output rdma_status status);
    respond(1, function_h, status);
  endtask

  // 功能：让 MMIO ordering barrier 进入可控时序 fixture。
  // 输入/输出及副作用：function_h 传给 stage=2 的 respond，status 输出其结果并记录一次调用。
  // 失败/边界：不是 MMIO write；延迟期间取消后不产生完成记录或 doorbell 可见性。
  virtual task mmio_ordering_barrier(rdma_function_handle function_h, output rdma_status status);
    respond(2, function_h, status);
  endtask
endclass

// 独立 test 只复用现有 fixture 构造器，不重复执行父类 run_phase；旧大矩阵仍由原 test 覆盖。
class rdma_doorbell_barrier_test extends rdma_doorbell_scheduler_test;
  `uvm_component_utils(rdma_doorbell_barrier_test)

  // 功能：注册独立 barrier 时序测试组件，fixture 在 run_phase 中创建。
  // 输入/输出及副作用：name/parent 传给父类；构造不分配 adapter 或持有 Function lock。
  // 失败/边界：parent 可为空；本构造不启动父类测试流程。
  function new(string name = "rdma_doorbell_barrier_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：通过公开 submit_observed 验证一次 barrier 策略的调用前缀、时间和失败证据。
  // 输入/输出及副作用：binding/mem 借用；policy 选择四种策略，mode=0/1 为立即/延迟成功，
  //   2/3/4 为 stage 指定的 null/错误/超时，5 为 DMA+MMIO 共用预算耗尽；每例新建 DUT/PCIe。
  // 失败/边界：故障只选 policy 启用的 stage；失败不得调用 observer/MMIO，超时后再等 10ns
  //   检查无迟到完成；随后同一 Function 再提交成功，证明锁已归还，不验证真实 PCIe 可撤销性。
  task check_case(rdma_function_binding binding, rdma_mock_host_mem mem,
                  rdma_doorbell_barrier_policy_e policy, int unsigned mode, int unsigned stage);
    rdma_timed_barrier_pcie pcie;
    rdma_doorbell_scheduler scheduler;
    rdma_doorbell_counting_observer observer;
    rdma_doorbell_desc desc;
    rdma_doorbell_submission_result result;
    rdma_status status;
    rdma_submission_effect_e effect;
    string expected[$];
    string diagnostic;
    time started_at;
    time duration;
    int unsigned finished;
    bit dma_enabled;
    bit mmio_enabled;
    bit success;

    pcie = new();
    scheduler = new("barrier_case_scheduler");
    observer = new();
    status = scheduler.configure(mem, pcie);
    expect_status("BARRIER_CONFIG", status, RDMA_SC_OK);
    desc = make_desc("barrier_case_desc", binding);
    desc.barrier_policy = policy;
    desc.timeout = 5ns;
    dma_enabled = policy inside {RDMA_DB_BARRIER_DMA, RDMA_DB_BARRIER_DMA_MMIO};
    mmio_enabled = policy inside {RDMA_DB_BARRIER_MMIO, RDMA_DB_BARRIER_DMA_MMIO};
    success = mode < 2;
    pcie.dma_delay = mode == 0 ? 0 : 1ns;
    pcie.mmio_delay = mode == 0 ? 0 : 2ns;
    if (mode inside {2, 3}) begin
      pcie.failure_stage = stage;
      pcie.return_null = mode == 2;
    end
    if (mode == 4) begin
      if (stage == 1) pcie.dma_delay = 9ns;
      else pcie.mmio_delay = 9ns;
    end
    if (mode == 5) begin
      pcie.dma_delay = 3ns;
      pcie.mmio_delay = 3ns;
    end
    if (dma_enabled) expected.push_back("dma_visibility_barrier");
    if (mmio_enabled && (success || stage != 1)) expected.push_back("mmio_ordering_barrier");
    if (success) expected.push_back("mmio_write");
    duration = mode >= 4 ? 5ns :
               (dma_enabled ? pcie.dma_delay : 0) +
               (mmio_enabled && (success || stage != 1) ? pcie.mmio_delay : 0);
    effect = success ? RDMA_SUBMIT_EFFECT_MMIO_VISIBLE : stage == 1 ?
             RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN : RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED;
    started_at = $time;
    scheduler.submit_observed(binding, desc, observer, result);
    if (result == null || result.status == null)
      `uvm_fatal("BARRIER_CASE", "missing observed result/status")
    expect_status("BARRIER_CASE", result.status, success ? RDMA_SC_OK : mode == 2 ?
                  RDMA_SC_INVALID_STATE : mode == 3 ? RDMA_SC_DMA_TRANSLATION : RDMA_SC_TIMEOUT);
    expect_observed_contract("BARRIER_CASE", result, effect, 0, observer, success ? 1 : 0,
                             desc, pcie.failure, success);
    if ($time - started_at != duration || pcie.calls.size() != expected.size())
      `uvm_error("BARRIER_CASE", "wrong total deadline or backend call count")
    foreach (expected[i]) begin
      if (i >= pcie.calls.size() || pcie.calls[i].method_name != expected[i] ||
          pcie.calls[i].function_h == null ||
          !pcie.calls[i].function_h.same_instance(desc.function_h))
        `uvm_error("BARRIER_CASE", "backend order or Function changed")
    end
    if (mode == 2) begin
      diagnostic = stage == 1 ? "PCIe DMA barrier returned null status" :
                               "PCIe MMIO barrier returned null status";
      if (result.status.message != diagnostic)
        `uvm_error("BARRIER_CASE", "null diagnostic changed")
    end
    if (mode == 3 && result.status.convert2string() != pcie.failure.convert2string())
      `uvm_error("BARRIER_CASE", "original backend diagnostic fields changed")
    if (mode >= 4) begin
      diagnostic = {"doorbell submit deadline expired during ",
                    stage == 1 ? "DMA visibility barrier" : "MMIO ordering barrier"};
      if (result.status.message != diagnostic)
        `uvm_error("BARRIER_CASE", "timeout diagnostic changed")
    end
    finished = expected.size() - (success || mode >= 4 ? 1 : 0);
    if (pcie.completed(binding.function_uid) != finished)
      `uvm_error("BARRIER_CASE", "wrong barrier completion count")
    #10ns;
    if (pcie.completed(binding.function_uid) != finished || pcie.calls.size() != expected.size())
      `uvm_error("BARRIER_CASE", "canceled worker completed or issued late I/O")

    pcie.failure_stage = 0;
    pcie.dma_delay = 0;
    pcie.mmio_delay = 0;
    observer.clear();
    scheduler.submit_observed(binding, desc, observer, result);
    if (result == null || result.status == null)
      `uvm_fatal("BARRIER_CASE", "retry omitted result/status")
    expect_status("BARRIER_REUSE", result.status, RDMA_SC_OK);
    expect_observed_contract("BARRIER_REUSE", result, RDMA_SUBMIT_EFFECT_MMIO_VISIBLE,
                             0, observer, 1, desc, null, 1);
    if (mem.calls.size() != 0)
      `uvm_error("BARRIER_CASE", "barrier-only fixture touched Host-memory")
    `uvm_info("BARRIER_MATRIX", $sformatf("completed barrier case policy=%0d mode=%0d stage=%0d",
                                         policy, mode, stage), UVM_LOW)
  endtask

  // 功能：并发运行两个 Function，让 A 在 barrier 超时而 B 继续完成，检查取消仅作用于本次调用。
  // 输入/输出及副作用：a/b/mem 借用，policy 仅为 DMA 或 MMIO；A 延迟 9ns/预算 5ns，
  //   B 在 1ns 后启动并延迟 8ns；独立 sibling 在 6ns 留下存活证据，结束后重用 A 的锁。
  // 失败/边界：A 不得完成后台 barrier 或调用 observer；B 必须成功；再等 10ns 检查无迟到 I/O。
  task check_cancellation(rdma_function_binding a, rdma_function_binding b,
                          rdma_mock_host_mem mem, rdma_doorbell_barrier_policy_e policy);
    rdma_timed_barrier_pcie pcie;
    rdma_doorbell_scheduler scheduler;
    rdma_doorbell_desc a_desc;
    rdma_doorbell_desc b_desc;
    rdma_doorbell_submission_result a_result;
    rdma_doorbell_submission_result b_result;
    rdma_doorbell_counting_observer a_observer;
    rdma_doorbell_counting_observer b_observer;
    rdma_status status;
    time started_at;
    time a_finished_at;
    time b_finished_at;
    bit sibling_finished;

    pcie = new();
    scheduler = new("concurrent_barrier_scheduler");
    a_observer = new();
    b_observer = new();
    status = scheduler.configure(mem, pcie);
    expect_status("BARRIER_PARALLEL", status, RDMA_SC_OK);
    a_desc = make_desc("barrier_timeout_a", a);
    b_desc = make_desc("barrier_success_b", b);
    a_desc.barrier_policy = policy;
    b_desc.barrier_policy = policy;
    a_desc.timeout = 5ns;
    b_desc.timeout = 20ns;
    pcie.dma_delay = 9ns;
    pcie.mmio_delay = 9ns;
    pcie.peer_uid = b.function_uid;
    pcie.peer_delay = 8ns;
    sibling_finished = 1'b0;
    started_at = $time;
    fork
      begin
        scheduler.submit_observed(a, a_desc, a_observer, a_result);
        a_finished_at = $time;
      end
      begin
        #1ns;
        scheduler.submit_observed(b, b_desc, b_observer, b_result);
        b_finished_at = $time;
      end
      begin
        #6ns;
        sibling_finished = 1'b1;
      end
    join
    if (a_result == null || b_result == null)
      `uvm_fatal("BARRIER_PARALLEL", "concurrent submit omitted result")
    expect_status("BARRIER_PARALLEL_A", a_result.status, RDMA_SC_TIMEOUT);
    expect_status("BARRIER_PARALLEL_B", b_result.status, RDMA_SC_OK);
    expect_observed_contract("BARRIER_PARALLEL_A", a_result,
      policy == RDMA_DB_BARRIER_DMA ? RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN :
      RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED, 0, a_observer, 0, a_desc, null, 0);
    expect_observed_contract("BARRIER_PARALLEL_B", b_result,
      RDMA_SUBMIT_EFFECT_MMIO_VISIBLE, 0, b_observer, 1, b_desc, null, 1);
    if (!sibling_finished || a_finished_at - started_at != 5ns ||
        b_finished_at - started_at != 9ns || pcie.calls.size() != 3 ||
        pcie.completed(a.function_uid) != 0 || pcie.completed(b.function_uid) != 1)
      `uvm_error("BARRIER_PARALLEL", "timeout canceled peer/sibling or leaked its worker")
    pcie.dma_delay = 0;
    pcie.mmio_delay = 0;
    scheduler.submit_observed(a, a_desc, a_observer, a_result);
    if (a_result == null)
      `uvm_fatal("BARRIER_PARALLEL", "lock reuse omitted result")
    expect_status("BARRIER_PARALLEL_REUSE", a_result.status, RDMA_SC_OK);
    expect_observed_contract("BARRIER_PARALLEL_REUSE", a_result,
      RDMA_SUBMIT_EFFECT_MMIO_VISIBLE, 0, a_observer, 1, a_desc, null, 1);
    #10ns;
    if (pcie.completed(a.function_uid) != 1 || pcie.completed(b.function_uid) != 1 ||
        pcie.calls.size() != 5 || mem.calls.size() != 0)
      `uvm_error("BARRIER_PARALLEL", "late worker or lock reuse changed I/O")
    `uvm_info("BARRIER_MATRIX",
              $sformatf("completed cancellation case policy=%0d", policy), UVM_LOW)
  endtask

  // 功能：执行 21 个顺序场景和两个并发取消场景，覆盖全部 barrier 策略及单一总预算。
  // 输入/输出及副作用：phase 输入；创建两个 Function 和空 Host-memory fixture，持有 objection。
  // 失败/边界：正常结束校验 23 cases 并 drop objection；超过 2us 触发 fatal，不能把取消误杀当作通过。
  task run_phase(uvm_phase phase);
    rdma_function_binding a;
    rdma_function_binding b;
    rdma_mock_host_mem mem;
    rdma_doorbell_barrier_policy_e policy;
    int unsigned cases;

    phase.raise_objection(this);
    a = make_binding("barrier_a", 64'h23501, 1, 1);
    b = make_binding("barrier_b", 64'h23502, 2, 1);
    mem = new("barrier_unused_memory");
    cases = 0;
    fork
      begin : matrix_scope
        fork
          begin
            for (int unsigned p = 0; p < 4; p++) begin
              policy = rdma_doorbell_barrier_policy_e'(p);
              for (int unsigned mode = 0; mode < 2; mode++) begin
                check_case(a, mem, policy, mode, 0);
                cases++;
              end
              for (int unsigned stage = 1; stage <= 2; stage++) begin
                if ((p & stage) == 0) continue;
                for (int unsigned mode = 2; mode <= 4; mode++) begin
                  check_case(a, mem, policy, mode, stage);
                  cases++;
                end
              end
            end
            check_case(a, mem, RDMA_DB_BARRIER_DMA_MMIO, 5, 2);
            cases++;
            check_cancellation(a, b, mem, RDMA_DB_BARRIER_DMA);
            cases++;
            check_cancellation(a, b, mem, RDMA_DB_BARRIER_MMIO);
            cases++;
          end
          begin
            #2us;
            `uvm_fatal("BARRIER_MATRIX", "barrier matrix watchdog expired")
          end
        join_any
        disable fork;
      end
    join
    if (cases != 23)
      `uvm_error("BARRIER_MATRIX", "barrier case count changed")
    `uvm_info("BARRIER_MATRIX", "completed 23 barrier deadline cases", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass
