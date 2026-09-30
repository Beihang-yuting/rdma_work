// 目录/层次：tests/unit，CMQ wait 的退出、等待窗口与交付对照测试。
// 职责：通过公开 wait_for 区分 retained 重复观察、legacy FIFO 单次转移及等待期间变化。
// 依赖：CMQ engine fixture 与 execute_observation_probe；不调用内部 wait projector。
// 所有权/生命周期：每例独占 engine/adapter；probe 仅在明确的无锁窗口注入，
//   清理时恢复本例 gate/index/state，不替代生产 poll/expiry 或共享外部资源。

// 设计说明：只开放等待窗口中的 gate/index 注入；真实提交、锁和 wait 均使用生产实现。
class rdma_cmq_wait_delivery_probe extends rdma_cmq_execute_observation_probe;
  `uvm_object_utils(rdma_cmq_wait_delivery_probe)

  // 功能：构造默认未配置的等待 probe，不创建额外账本或锁。
  // 输入/输出及副作用：name 传给基类；沿用其 STAGED 模式和零 submit 计数。
  // 失败/边界：业务调用前必须完成真实 prepare/activate，不能用构造绕过 authority。
  function new(string name = "rdma_cmq_wait_delivery_probe");
    super.new(name);
  endfunction

  // 功能：在等待已让出的窗口切换 reset release gate，模拟并发复位准入。
  // 输入/输出及副作用：blocked 直接设置本例 reset_release_in_progress。
  // 失败/边界：仅测试串行准备或 wait 的无锁窗口可调用；清理必须撤销 gate。
  function void set_wait_release_gate(bit blocked);
    reset_release_in_progress = blocked;
  endfunction

  // 功能：恢复本例真实 submit 的 ticket index，撤销等待窗口或 legacy 路径的缺索引注入。
  // 输入/输出及副作用：无参数；从 record 的 canonical ticket 恢复原 batch key。
  // 失败/边界：缺少 record/item/ticket 时 fatal；不创建新行或更换其 identity。
  function void restore_wait_index();
    if (record == null || record.items.size() != 1 || record.items[0].ticket == null)
      `uvm_fatal("WAIT_INDEX", "cannot restore an absent fixture")
    journal_batch_by_ticket[command_key(record.items[0].ticket)] = record.batch_key;
  endfunction
endclass

// 设计说明：独立列出诊断和时间预期，不用 DUT 的分类器推导答案；两等待者共用同一
// retained authority，legacy 则只能转移 FIFO 原对象，二者不能强行统一为一种交付策略。
class rdma_cmq_wait_delivery_test extends rdma_cmq_engine_test;
  `uvm_component_utils(rdma_cmq_wait_delivery_test)

  int unsigned wait_calls;

  // 功能：建立独立 wait 矩阵并清零公开调用次数。
  // 输入/输出及副作用：name/parent 传给基类；本 test 拥有计数，各例自行管理 fixture。
  // 失败/边界：构造不执行父类 run_phase，也不安装全局 factory override。
  function new(string name = "rdma_cmq_wait_delivery_test", uvm_component parent = null);
    super.new(name, parent);
    wait_calls = 0;
  endfunction

  // 功能：调用一次公开 wait，检查准确状态、等待时长、FIFO 余量及 detached/legacy 交付。
  // 输入/输出及副作用：engine/ticket 借用；expected_* 为独立预期，legacy 表示转移 FIFO
  //   原对象；调用递增 wait_calls，不修改返回图或 retained 行。
  // 失败/边界：null status/缺失终态图 fatal；拒绝必须清空 completion，retained status、
  //   ticket/raw/payload 不得泄漏别名，legacy completion 则应保持原引用。
  task check_wait(string label, rdma_cmq_wait_delivery_probe engine, rdma_cmq_ticket ticket,
                  rdma_status_code_e expected_code, string expected_message,
                  bit expected_completion, time expected_delay, int unsigned expected_fifo,
                  bit legacy = 0);
    rdma_status status;
    rdma_cmq_completion completion;
    rdma_cmq_batch_submission_item_record item;
    time started;

    started = $time;
    completion = new("stale_wait_output");
    engine.wait_for(ticket, completion, status);
    wait_calls++;
    if (status == null)
      `uvm_fatal(label, "wait returned null status")
    if (status.code != expected_code || status.message != expected_message ||
        $time - started != expected_delay || engine.terminal_fifo_count() != expected_fifo)
      `uvm_error(label, $sformatf("wait outcome mismatch: %s delay=%0t FIFO=%0d",
        status.convert2string(), $time - started, engine.terminal_fifo_count()))
    if (!expected_completion) begin
      if (completion != null)
        `uvm_error(label, "rejected wait retained completion output")
      return;
    end
    item = engine.record.items[0];
    if (completion == null || completion.ticket == null || completion.status == null)
      `uvm_fatal(label, "wait omitted terminal evidence")
    if (status == completion.status || status == item.status ||
        completion.status.code != status.code || completion.status.message != status.message ||
        completion.ticket.command_id != item.ticket.command_id)
      `uvm_error(label, "wait status or ticket value differs")
    if (legacy) begin
      if (completion != item.completion)
        `uvm_error(label, "legacy wait did not transfer the FIFO object")
    end
    else if (completion == item.completion || completion.ticket == item.ticket ||
             completion.status == item.status ||
             (item.completion.raw_cqe != null && completion.raw_cqe == item.completion.raw_cqe) ||
             (item.completion.decoded_response != null &&
              completion.decoded_response == item.completion.decoded_response))
      `uvm_error(label, "retained wait exposed a canonical graph alias")
  endtask

  // 功能：运行一个 retained/准入/等待窗口/legacy 场景，或终态 payload snapshot 故障。
  // 输入/输出及副作用：mode 0..6 为七类 retained 状态，7 timeout，8 gate，9 null，
  //   10 host 坏 phase，11 非 ACTIVE pending，12 未知 ticket，13 坏 deadline，14 read 故障；
  //   15..19 在 100ps 注入 gate/index/state/terminal/caller-ticket 变化，20/21 为 legacy
  //   成功/非 ACTIVE 拒绝；fault=1/2 为 payload null/nonOK，修复后再查。
  // 失败/边界：每例只 submit 一次；非等待路径不得访问 memory，所有 wait 不重新发布或
  //   推进 attempt；注入仅在 fixture/无锁等待期，完成后恢复 index/state 再真实 shutdown。
  task run_case(int unsigned mode, int unsigned fault = 0);
    rdma_cmq_wait_delivery_probe engine;
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
    rdma_cmq_completion delayed_completion;
    rdma_status status;
    rdma_status saved_status;
    rdma_status_code_e expected_code;
    string expected_message;
    string label;
    bit expected_completion;
    time expected_delay;
    int unsigned expected_fifo;
    int unsigned before_mem;
    int unsigned before_pcie;
    longint unsigned before_attempt;

    label = $sformatf("WAIT_M%0d_F%0d", mode, fault);
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
    engine.mode = mode inside {11, 12, 13, 14, 15, 16, 17, 19} ? 7 :
                  (mode inside {18, 20, 21} ? 3 : mode);
    command = make_command({label, "_command"}, active_binding,
                            rdma_cmq_test_profile::TEST_OPCODE_A, 8'he2, 5ns);
    engine.submit_observed(command, submitted);
    if (submitted == null || submitted.ticket == null || engine.record == null)
      `uvm_fatal(label, "wait fixture lacks submitted authority")
    ticket = mode == 9 ? null : submitted.ticket;
    saved_status = engine.record.items[0].status;
    if (mode inside {11, 21})
      engine.force_observed_engine_state(RDMA_CMQ_ENGINE_QUIESCED);
    if (mode == 12)
      ticket.command_id++;
    if (mode == 13)
      ticket.absolute_deadline = 0;
    if (mode inside {[3:6], 20, 21})
      engine.seed_terminal_completion(engine.record.items[0].completion);
    if (mode inside {20, 21})
      engine.hide_ticket_index();
    if (mode == 18) begin
      delayed_completion = engine.record.items[0].completion;
      engine.record.state = RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED;
      engine.record.items[0].state = RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED;
      engine.record.items[0].completion_phase = RDMA_CMQ_COMPLETION_PENDING;
      engine.record.items[0].completion = null;
    end
    if (fault == 1)
      profile.completion_payload_hook_fault = RDMA_CMQ_TEST_HOOK_NULL_STATUS;
    if (fault == 2)
      profile.completion_payload_hook_fault = RDMA_CMQ_TEST_HOOK_NONOK_STATUS;

    expected_code = RDMA_SC_INVALID_STATE;
    expected_message = "";
    expected_completion = mode inside {[3:7], 18, 19, 20} && fault == 0;
    expected_delay = mode inside {7, 19} ? 5ns : (mode inside {[15:18]} ? 1ns : 0);
    expected_fifo = fault != 0 || mode == 21 ? 1 : 0;
    case (mode)
      0, 1: expected_message = "CMQ wait ticket is not observable yet";
      2, 10: expected_message = "CMQ wait ticket was not published";
      3, 4, 5, 6, 18, 20: begin
        expected_code = saved_status.code;
        expected_message = saved_status.message;
      end
      7, 19: begin
        expected_code = RDMA_SC_TIMEOUT;
        expected_message = "CMQ command deadline expired";
      end
      8, 15: expected_message = "CMQ lifecycle mutation is blocked during reset backing release";
      9: begin
        expected_code = RDMA_SC_INVALID_ARGUMENT;
        expected_message = "CMQ wait ticket is null";
      end
      11: expected_message = "CMQ wait pending ticket belongs to old engine";
      12: begin
        expected_code = RDMA_SC_INVALID_ARGUMENT;
        expected_message = "CMQ wait ticket is unknown or delivered";
      end
      13: begin
        expected_code = RDMA_SC_INVALID_ARGUMENT;
        expected_message = "CMQ wait ticket is invalid";
      end
      14: begin
        expected_code = RDMA_SC_TIMEOUT;
        expected_message = "injected wait CQ read failure";
      end
      16: expected_message = "CMQ wait retained authority changed after unlock";
      17: expected_message = "CMQ wait current runtime authority changed";
      21: expected_message = "CMQ wait requires an ACTIVE engine";
      default: `uvm_fatal(label, "unsupported wait mode")
    endcase
    if (fault != 0) begin
      expected_code = RDMA_SC_INVALID_STATE;
      expected_message = fault == 1 ? "CMQ completion payload snapshot returned null status" :
                                     "injected completion payload snapshot rejection";
    end
    before_mem = mem.calls.size();
    before_pcie = pcie.calls.size();
    before_attempt = engine.journal_attempt_counter();
    if (mode inside {[15:19]}) begin
      fork
        check_wait(label, engine, ticket, expected_code, expected_message,
                   expected_completion, expected_delay, expected_fifo);
        begin
          #100ps;
          case (mode)
            15: engine.set_wait_release_gate(1'b1);
            16: engine.hide_ticket_index();
            17: engine.force_observed_engine_state(RDMA_CMQ_ENGINE_QUIESCED);
            18: begin
              engine.record.state = RDMA_CMQ_SUBMISSION_COMPLETED;
              engine.record.items[0].state = RDMA_CMQ_SUBMISSION_COMPLETED;
              engine.record.items[0].completion_phase = RDMA_CMQ_COMPLETION_TERMINAL;
              engine.record.items[0].completion = delayed_completion;
              engine.seed_terminal_completion(delayed_completion);
            end
            19: ticket.command_id++;
            default: `uvm_fatal(label, "unsupported wait-window injection")
          endcase
        end
      join
    end
    else begin
      for (int query = 0; query < (mode == 20 ? 1 : 2); query++) begin
        if (mode == 14) begin
          status = mem.fail_next("read", rdma_cmq_direct_status(
            RDMA_SC_TIMEOUT, "injected wait CQ read failure"));
          expect_status(label, status, RDMA_SC_OK);
        end
        check_wait(label, engine, ticket, expected_code, expected_message,
                   expected_completion, query == 0 ? expected_delay : 0,
                   expected_fifo, mode == 20);
      end
    end
    if ((!(mode inside {7, 14, [15:19]}) && mem.calls.size() != before_mem) ||
        (mode inside {7, 14, [15:19]} && mem.calls.size() <= before_mem))
      `uvm_error(label, "wait changed the Host-memory access boundary")
    if (fault != 0 || mode == 14) begin
      profile.completion_payload_hook_fault = RDMA_CMQ_TEST_HOOK_GOOD;
      check_wait(label, engine, ticket, mode == 14 ? RDMA_SC_TIMEOUT : saved_status.code,
        mode == 14 ? "CMQ command deadline expired" : saved_status.message,
        1'b1, mode == 14 ? 5ns : 0, 0);
    end
    if (engine.submit_calls != 1 || pcie.calls.size() != before_pcie ||
        engine.journal_attempt_counter() != before_attempt)
      `uvm_error(label, "wait republished or advanced attempt authority")
    engine.force_observed_engine_state(RDMA_CMQ_ENGINE_ACTIVE);
    engine.restore_wait_index();
    engine.restore_fixture();
    engine.shutdown(status);
    expect_status(label, status, RDMA_SC_OK);
  endtask

  // 功能：让两个真实 wait 并发等待同一 pending ticket，验证 timeout retained 可重复交付。
  // 输入/输出及副作用：独立 ACTIVE fixture；两调用同时等待 5ns，分别获得 detached
  //   completion/status，最终 FIFO 为空且 submit/attempt 不增加。
  // 失败/边界：不得死锁、互相取消或只允许一个 waiter 成功；清理使用真实 shutdown。
  task check_concurrent_waiters();
    rdma_cmq_wait_delivery_probe engine;
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
    rdma_cmq_completion first_completion;
    rdma_cmq_completion second_completion;
    rdma_status first_status;
    rdma_status second_status;
    rdma_status status;
    time started;
    longint unsigned attempt_before;

    engine = new("dual_wait_engine");
    engine.mode = 7;
    mem = new("dual_wait_mem");
    pcie = new("dual_wait_pcie");
    scheduler = new("dual_wait_scheduler");
    profile = new("dual_wait_profile");
    prepared_binding = make_binding("dual_wait_prepared", RDMA_BIND_PREPARED);
    active_binding = make_binding("dual_wait_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("dual_wait_cmq", prepared_binding);
    prepare_active("DUAL_WAIT", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    command = make_command("dual_wait_command", active_binding,
                            rdma_cmq_test_profile::TEST_OPCODE_A, 8'he3, 5ns);
    engine.submit_observed(command, submitted);
    if (submitted == null || submitted.ticket == null)
      `uvm_fatal("DUAL_WAIT", "submit did not produce a ticket")
    attempt_before = engine.journal_attempt_counter();
    started = $time;
    fork
      engine.wait_for(submitted.ticket, first_completion, first_status);
      engine.wait_for(submitted.ticket, second_completion, second_status);
    join
    wait_calls += 2;
    expect_status("DUAL_WAIT_FIRST", first_status, RDMA_SC_TIMEOUT);
    expect_status("DUAL_WAIT_SECOND", second_status, RDMA_SC_TIMEOUT);
    if (first_completion == null || second_completion == null)
      `uvm_fatal("DUAL_WAIT", "a waiter lost retained timeout evidence")
    if ($time - started != 5ns || first_completion == second_completion ||
        first_completion.ticket == second_completion.ticket || first_status == second_status ||
        first_completion.status == second_completion.status ||
        engine.terminal_fifo_count() != 0 || engine.submit_calls != 1 ||
        engine.journal_attempt_counter() != attempt_before)
      `uvm_error("DUAL_WAIT", "concurrent waits changed timing, ownership or attempt")
    engine.restore_fixture();
    engine.shutdown(status);
    expect_status("DUAL_WAIT_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  // 功能：执行 22 类等待/拒绝场景、8 类终态快照故障及一次双等待者场景。
  // 输入/输出及副作用：phase 管理 objection；31 场景共 65 次 wait，输出唯一完成标记。
  // 失败/边界：10us watchdog 捕捉丢锁/取消/无限等待；调用数或任何非零 UVM severity 失败。
  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    fork
      begin
        for (int mode = 0; mode < 22; mode++)
          run_case(mode);
        for (int mode = 3; mode <= 6; mode++)
          for (int fault = 1; fault <= 2; fault++)
            run_case(mode, fault);
        check_concurrent_waiters();
      end
      begin
        #10us;
        `uvm_fatal("WAIT_WATCHDOG", "wait delivery matrix timed out")
      end
    join_any
    disable fork;
    if (wait_calls != 65)
      `uvm_error("WAIT_COUNT", $sformatf("expected 65 waits, got %0d", wait_calls))
    `uvm_info("WAIT_MATRIX", "completed 31 CMQ wait scenarios and 65 calls", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass
