// 目录/层次：tests/unit，CMQ reconcile 查询交付的公开入口对照测试。
// 职责：重复观察 retained 状态，验证单次 poll、失败后可重试及 FIFO 不被查询消费。
// 依赖：rdma_cmq_engine_test 的 ACTIVE fixture 和 execute_observation_probe 的
//   单条真实 submit/retained 注入；不运行其 execute 流程，也不调用内部 projector。
// 所有权/生命周期：每例独占 engine、mock memory/PCIe/profile；只在串行窗口注入，
//   撤销注入后真实 shutdown；不运行父类 run_phase 或安装全局 factory override。

// 设计说明：沿用已验证的 retained 图夹具，不再复制 raw-CQE、状态和 owner 的构造；
// 预期诊断独立列出，重复查询和修复后查询可同时检查解锁、幂等和结果分离。
class rdma_cmq_reconcile_delivery_test extends rdma_cmq_engine_test;
  `uvm_component_utils(rdma_cmq_reconcile_delivery_test)

  int unsigned query_calls;

  // 功能：建立独立 reconcile 矩阵并清零实际查询次数。
  // 输入/输出及副作用：name/parent 交给 UVM 基类；本 test 仅拥有计数和各例夹具。
  // 失败/边界：构造不 prepare 或运行父矩阵，业务 authority 必须由真实 submit 创建。
  function new(string name = "rdma_cmq_reconcile_delivery_test", uvm_component parent = null);
    super.new(name, parent);
    query_calls = 0;
  endfunction

  // 功能：从公开 reconcile 读取一次结果，断言诊断、终态、detached 图及 FIFO 增量。
  // 输入/输出及副作用：engine/ticket 借用；expected_* 为独立预期，fifo_delta 默认零；
  //   调用递增 query_calls，检查 status 与 canonical/returned completion 的 status 分离。
  // 失败/边界：空 status 立即 fatal；拒绝或非终态必须清空 completion/terminal_known，
  //   查询不得等待；只有实际 expiry 的调用允许增加一条 FIFO，任何路径都不消费 FIFO。
  task check_query(string label, rdma_cmq_execute_observation_probe engine,
                   rdma_cmq_ticket ticket, rdma_status_code_e expected_code,
                   string expected_message, bit expected_terminal,
                   int unsigned fifo_delta = 0);
    rdma_status status;
    rdma_cmq_completion completion;
    rdma_cmq_batch_submission_item_record item;
    bit terminal_known;
    int unsigned before_fifo;
    time started;

    before_fifo = engine.terminal_fifo_count();
    started = $time;
    terminal_known = 1'b1;
    completion = new("caller_stale_completion");
    engine.reconcile_ticket(ticket, terminal_known, completion, status);
    query_calls++;
    if (status == null)
      `uvm_fatal(label, "reconcile returned null status")
    if (status.code != expected_code || status.message != expected_message ||
        terminal_known != expected_terminal ||
        engine.terminal_fifo_count() != before_fifo + fifo_delta || $time != started)
      `uvm_error(label, $sformatf("reconcile outcome mismatch: %s terminal=%0b FIFO=%0d",
        status.convert2string(), terminal_known, engine.terminal_fifo_count()))
    item = engine.record.items[0];
    if (status == item.status)
      `uvm_error(label, "query exposed canonical operation status")
    if (!expected_terminal) begin
      if (completion != null)
        `uvm_error(label, "nonterminal/rejected query retained a completion")
      return;
    end
    if (completion == null || completion.ticket == null || completion.status == null)
      `uvm_fatal(label, "terminal query omitted a required node")
    if (completion == item.completion || completion.ticket == item.ticket ||
        completion.status == item.status || status == completion.status ||
        completion.status.code != status.code || completion.status.message != status.message ||
        completion.ticket.command_id != item.ticket.command_id ||
        completion.ticket.absolute_deadline != item.ticket.absolute_deadline ||
        (item.completion.raw_cqe != null && completion.raw_cqe == item.completion.raw_cqe) ||
        (item.completion.decoded_response != null &&
         completion.decoded_response == item.completion.decoded_response))
      `uvm_error(label, "terminal query changed values or leaked retained graph aliases")
  endtask

  // 功能：重复观察一个状态/拒绝点；payload/status/read 故障修复后再次查询，pending
  //   场景到期后经真实 expire/poll 生成并再次观察 timeout completion。
  // 输入/输出及副作用：mode 0..6 为七类 retained 状态，7 当前 pending，8 reset gate，
  //   9 null ticket，10 host 坏 phase，11 非 ACTIVE pending，12 缺索引，13 坏 deadline，
  //   14 CQ read 失败；fault 1/2 为终态 payload null/nonOK，3/4 为 host status null/保留编码。
  // 失败/边界：每例仅一次 submit；只有 mode 7/14 可以读 Host-memory，查询不发布 MMIO
  //   或推进 attempt。重复失败不得遗留锁；清理只撤销本例注入，不伪造成功结果。
  task run_case(int unsigned mode, int unsigned fault = 0);
    rdma_cmq_execute_observation_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc command;
    rdma_cmq_execution_result submitted;
    rdma_cmq_ticket ticket;
    rdma_status status;
    rdma_status saved_status;
    rdma_status_code_e expected_code;
    string expected_message;
    string label;
    bit expected_terminal;
    int unsigned before_mem;
    int unsigned before_pcie;
    longint unsigned before_attempt;

    label = $sformatf("RECONCILE_M%0d_F%0d", mode, fault);
    engine = new({label, "_engine"});
    mem = new({label, "_mem"});
    pcie = new({label, "_pcie"});
    scheduler = new({label, "_scheduler"});
    profile = new({label, "_profile"});
    prepared_binding = make_binding({label, "_prepared"}, RDMA_BIND_PREPARED);
    active_binding = make_binding({label, "_active"}, RDMA_BIND_ACTIVE);
    cmq = make_cmq({label, "_cmq"}, prepared_binding);
    prepare_active(label, engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    engine.mode = mode inside {11, 13, 14} ? 7 : mode;
    command = make_command({label, "_command"}, active_binding,
                            rdma_cmq_test_profile::TEST_OPCODE_A, 8'hd1, 5ns);
    engine.submit_observed(command, submitted);
    if (submitted == null || submitted.ticket == null || engine.record == null)
      `uvm_fatal(label, "reconcile fixture lacks submitted authority")
    ticket = mode == 9 ? null : submitted.ticket;
    if (mode == 11)
      engine.force_observed_engine_state(RDMA_CMQ_ENGINE_QUIESCED);
    if (mode == 13)
      ticket.absolute_deadline = 0;
    if (mode inside {[3:6]})
      engine.seed_terminal_completion(engine.record.items[0].completion);
    saved_status = engine.record.items[0].status;
    if (fault == 1)
      profile.completion_payload_hook_fault = RDMA_CMQ_TEST_HOOK_NULL_STATUS;
    if (fault == 2)
      profile.completion_payload_hook_fault = RDMA_CMQ_TEST_HOOK_NONOK_STATUS;
    if (fault == 3)
      engine.record.items[0].status = null;
    if (fault == 4) begin
      engine.record.items[0].status = rdma_cmq_direct_status(RDMA_SC_OK);
      engine.record.items[0].status.code = rdma_status_code_e'(5'd31);
    end

    expected_code = RDMA_SC_INVALID_STATE;
    expected_terminal = mode inside {[3:6]} && fault == 0;
    case (mode)
      0, 1: expected_message = "CMQ reconcile item is staged or has a pending external effect";
      2, 3, 4, 5, 6, 7: begin
        expected_code = saved_status.code;
        expected_message = saved_status.message;
      end
      8: expected_message = "CMQ lifecycle mutation is blocked during reset backing release";
      9: begin
        expected_code = RDMA_SC_INVALID_ARGUMENT;
        expected_message = "CMQ reconcile ticket is null";
      end
      10: expected_message = "CMQ unarmed reconcile item has terminal evidence";
      11: expected_message = "CMQ reconcile pending ticket lacks current runtime authority";
      12: begin
        expected_code = RDMA_SC_INVALID_ARGUMENT;
        expected_message = "CMQ journal ticket is not installed";
      end
      13: begin
        expected_code = RDMA_SC_INVALID_ARGUMENT;
        expected_message = "CMQ reconcile ticket is invalid";
      end
      14: begin
        expected_code = RDMA_SC_TIMEOUT;
        expected_message = "injected reconcile CQ read failure";
      end
      default: `uvm_fatal(label, "unsupported reconcile scenario")
    endcase
    if (fault != 0) begin
      expected_code = RDMA_SC_INVALID_STATE;
      case (fault)
        1: expected_message = "CMQ completion payload snapshot returned null status";
        2: expected_message = "injected completion payload snapshot rejection";
        3, 4: expected_message = "CMQ retained operation status is null or malformed";
        default: `uvm_fatal(label, "unsupported reconcile fault")
      endcase
    end
    before_mem = mem.calls.size();
    before_pcie = pcie.calls.size();
    before_attempt = engine.journal_attempt_counter();
    repeat (2) begin
      if (mode == 14) begin
        status = mem.fail_next("read", rdma_cmq_direct_status(
          RDMA_SC_TIMEOUT, "injected reconcile CQ read failure"));
        expect_status(label, status, RDMA_SC_OK);
      end
      check_query(label, engine, ticket, expected_code, expected_message, expected_terminal);
    end
    if ((!(mode inside {7, 14}) && mem.calls.size() != before_mem) ||
        (mode inside {7, 14} && mem.calls.size() <= before_mem))
      `uvm_error(label, "reconcile changed the Host-memory access boundary")
    if (fault != 0 || mode == 14) begin
      profile.completion_payload_hook_fault = RDMA_CMQ_TEST_HOOK_GOOD;
      engine.record.items[0].status = saved_status;
      check_query(label, engine, ticket, saved_status.code, saved_status.message,
                  mode inside {[3:6]});
    end
    if (mode == 7) begin
      #5ns;
      // 到期前还没有 retained timeout 文案；精确文案由既有 timeout 构造契约固定。
      check_query(label, engine, ticket, RDMA_SC_TIMEOUT, "CMQ command deadline expired", 1'b1, 1);
      check_query(label, engine, ticket, RDMA_SC_TIMEOUT, "CMQ command deadline expired", 1'b1);
    end
    if (engine.submit_calls != 1 || pcie.calls.size() != before_pcie ||
        engine.journal_attempt_counter() != before_attempt)
      `uvm_error(label, "query republished a command or advanced attempt authority")
    if (mode == 11)
      engine.force_observed_engine_state(RDMA_CMQ_ENGINE_ACTIVE);
    engine.restore_fixture();
    engine.shutdown(status);
    expect_status(label, status, RDMA_SC_OK);
  endtask

  // 功能：执行 15 类正常/拒绝场景、8 类终态快照故障和 2 类非终态 status 故障。
  // 输入/输出及副作用：phase 管理 objection；25 场景共 63 次公开查询，输出唯一完成标记。
  // 失败/边界：10us watchdog 捕获解锁遗漏；实际调用数不符或任何 UVM 非零 severity 失败。
  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    fork
      begin
        for (int mode = 0; mode < 15; mode++)
          run_case(mode);
        for (int mode = 3; mode <= 6; mode++)
          for (int fault = 1; fault <= 2; fault++)
            run_case(mode, fault);
        run_case(2, 3);
        run_case(2, 4);
      end
      begin
        #10us;
        `uvm_fatal("RECONCILE_WATCHDOG", "reconcile matrix timed out")
      end
    join_any
    disable fork;
    if (query_calls != 63)
      `uvm_error("RECONCILE_COUNT", $sformatf("expected 63 queries, got %0d", query_calls))
    `uvm_info("RECONCILE_MATRIX", "completed 25 CMQ reconcile scenarios and 63 queries", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass
