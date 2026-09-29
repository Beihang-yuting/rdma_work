// 目录/层次：tests/unit，CMQ 完成事务的公开接口对照测试。
// 职责：验证乱序正常/晚到完成之后，下一 CQE 的成功、未就绪、可重试失败和 poison。
// 依赖：rdma_cmq_engine_test 的 fixture/断言、mock memory/PCIe 和 synthetic profile。
// 所有权/生命周期：每例独占 engine 与 adapter，结束时 shutdown；不改生产账本，
//   wrap 通过真实提交 32 条命令取得，不用 probe 伪造游标。不运行父类 run_phase。

// 设计说明：单项测试不能证明 drain 循环中前一项已提交而后一项失败的边界；
// 此矩阵同时检查 delivery、retained journal、token 与两个游标，防止阶段拆分漏提交。
class rdma_cmq_poll_transaction_test extends rdma_cmq_engine_test;
  `uvm_component_utils(rdma_cmq_poll_transaction_test)

  // 功能：构造独立的 CMQ poll 专项 test，仅复用基类 fixture 与断言。
  // 输入/输出及副作用：name/parent 传给基类；不创建 engine 或外部资源。
  // 失败/边界：对象图由各 case 创建，构造阶段不执行父类矩阵或安装 factory override。
  function new(string name = "rdma_cmq_poll_transaction_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：完成一整圈 32 条真实命令，使后续 CQ owner 和 SQ wrap 都进入第二圈。
  // 输入/输出及副作用：engine/mem/profile/binding 为本例非拥有引用；更新真实
  //   ring/journal，验证全部完成后 publish/retire/consume=32 且 token 全释放。
  // 失败/边界：提交或完成不完整报告 fatal；不 seed counter，不把延迟伪装成 wrap。
  task prime_wrap(rdma_cmq_engine_probe engine, rdma_mock_host_mem mem,
                  rdma_cmq_test_profile profile, rdma_function_binding binding);
    rdma_cmq_command_desc commands[];
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status status;
    rdma_hw_image raw;
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];

    commands = new[32];
    foreach (commands[i])
      commands[i] = make_command($sformatf("prime_%0d", i), binding,
                                32'h10, byte'(i));
    engine.submit_batch(commands, tickets, item_statuses, status);
    expect_status("PRIME_SUBMIT", status, RDMA_SC_OK);
    if (tickets.size() != 32)
      `uvm_fatal("PRIME_SUBMIT", "missing wrap priming tickets")
    foreach (tickets[i])
      write_profile_cqe("PRIME_CQE", mem, engine.mapping_snapshot(), profile,
                        i, 1'b1, tickets[i], 0, raw);
    engine.poll(completions, diagnostics, status);
    expect_status("PRIME_POLL", status, RDMA_SC_OK);
    if (completions.size() != 32 || diagnostics.size() != 0 ||
        engine.published_count() != 32 || engine.retired_count() != 32 ||
        engine.cq_consumed_count() != 32 || engine.tokens_in_use_count() != 0)
      `uvm_fatal("PRIME_POLL", "real ring wrap did not complete")
  endtask

  // 功能：先完成 SQ 后项，再按 mode 处理前项，覆盖部分 drain、连续回收及晚到交付。
  // 输入/输出及副作用：late 令后项先超时；wrapped 先完成一圈；mode=0 正常、1 owner
  //   未就绪、2 inspect INVALID_STATE、3 inspect CODEC_ERROR。通过公开 poll/query
  //   验证 FIFO、journal state/phase、token、registry 与 retire/consume，最后释放 backing。
  // 失败/边界：mode 仅来自本矩阵；非 poison 失败修复后必须仅交付剩余项，poison 不重试。
  //   任何输出缺失先 fatal，避免 null 解引用掩盖原失败；watchdog 由 run_phase 持有。
  task run_case(bit late, bit wrapped, int unsigned mode);
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc commands[];
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status status;
    rdma_hw_image raw_first;
    rdma_hw_image raw_second;
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];
    rdma_cmq_batch_submission_record journal;
    longint unsigned base_sequence;
    bit owner;
    string label;

    label = $sformatf("POLL_L%0d_W%0d_M%0d", late, wrapped, mode);
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
    if (wrapped)
      prime_wrap(engine, mem, profile, active_binding);
    base_sequence = wrapped ? 32 : 0;
    owner = !wrapped;
    commands = new[2];
    commands[0] = make_command("head", active_binding, 32'h10, 8'h10);
    commands[1] = make_command("tail", active_binding, 32'h20, 8'h20,
                               late ? 10ns : 1us);
    engine.submit_batch(commands, tickets, item_statuses, status);
    expect_status({label, "_SUBMIT"}, status, RDMA_SC_OK);
    if (tickets.size() != 2 || tickets[0] == null || tickets[1] == null)
      `uvm_fatal(label, "missing test tickets")
    if (late) begin
      #20ns;
      engine.expire(completions, status);
      expect_status({label, "_EXPIRE"}, status, RDMA_SC_OK);
      if (completions.size() != 1)
        `uvm_fatal(label, "late fixture must expire exactly one command")
      expect_timeout_completion(label, completions[0], tickets[1]);
    end
    write_profile_cqe(label, mem, engine.mapping_snapshot(), profile,
                      base_sequence, owner, tickets[1], 0, raw_first);
    write_profile_cqe(label, mem, engine.mapping_snapshot(), profile,
                      base_sequence + 1, mode == 1 ? !owner : owner,
                      tickets[0], 0, raw_second);
    if (mode >= 2) begin
      profile.inspect_failure_call = profile.inspect_calls + 2;
      profile.inspect_failure_code = mode == 2 ? RDMA_SC_INVALID_STATE :
                                                 RDMA_SC_CODEC_ERROR;
    end
    mem.calls.delete();
    engine.poll(completions, diagnostics, status);
    expect_status(label, status, mode == 2 ? RDMA_SC_INVALID_STATE :
                                 mode == 3 ? RDMA_SC_CODEC_ERROR : RDMA_SC_OK);
    expect_poll_read_geometry(label, mem, base_sequence, 2);
    if (completions.size() != (mode == 0 ? 2 : 1) - int'(late) ||
        diagnostics.size() != int'(late) + int'(mode == 3))
      `uvm_fatal(label, "drain lost or duplicated a terminal/diagnostic delivery")
    if (late)
      expect_late_diagnostic(label, engine, diagnostics[0], tickets[1], raw_first);
    else
      expect_polled_completion(label, engine, completions[0], tickets[1],
                               raw_first, owner, 0, RDMA_SC_OK);
    if (mode == 0)
      expect_polled_completion(label, engine, completions[1-int'(late)], tickets[0],
                               raw_second, owner, 0, RDMA_SC_OK);
    if (mode == 3 && diagnostics[$].kind != RDMA_CMQ_DIAG_MALFORMED_CQE)
      `uvm_error(label, "codec failure did not publish malformed-CQE poison")
    if (engine.cq_consumed_count() != base_sequence + (mode == 0 ? 2 : 1) ||
        engine.retired_count() != base_sequence + (mode == 0 ? 2 : 0) ||
        engine.tokens_in_use_count() != (mode == 0 ? 0 : 1) ||
        engine.command_registry_count() != (mode == 0 ? 0 : 1) ||
        engine.entry_registry_count() != (mode == 0 ? 0 : 2))
      `uvm_error(label, "partial drain changed current entry or lost retired prefix")
    engine.query_submission_journal_by_ticket(tickets[0], journal, status);
    expect_status({label, "_JOURNAL"}, status, RDMA_SC_OK);
    if (journal == null || journal.items.size() != 2)
      `uvm_fatal(label, "retained batch is incomplete")
    if (journal.items[1].state != (late ? RDMA_CMQ_SUBMISSION_LATE_COMPLETED :
                                        RDMA_CMQ_SUBMISSION_COMPLETED) ||
        journal.items[1].completion_phase != (late ? RDMA_CMQ_COMPLETION_DIAGNOSTIC_ONLY :
                                                     RDMA_CMQ_COMPLETION_TERMINAL) ||
        journal.items[0].state != (mode == 0 ? RDMA_CMQ_SUBMISSION_COMPLETED :
                                             RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED) ||
        journal.items[0].completion_phase != (mode == 0 ? RDMA_CMQ_COMPLETION_TERMINAL :
                                                        RDMA_CMQ_COMPLETION_PENDING))
      `uvm_error(label, "journal transition does not match per-entry commit")
    if (mode inside {1, 2}) begin
      profile.inspect_failure_call = 0;
      write_profile_cqe(label, mem, engine.mapping_snapshot(), profile,
                        base_sequence + 1, owner, tickets[0], 0, raw_second);
      mem.calls.delete();
      engine.poll(completions, diagnostics, status);
      expect_status({label, "_RETRY"}, status, RDMA_SC_OK);
      expect_poll_read_geometry(label, mem, base_sequence + 1, 1);
      if (completions.size() != 1 || diagnostics.size() != 0)
        `uvm_fatal(label, "repair must deliver only the pending head")
      expect_polled_completion(label, engine, completions[0], tickets[0],
                               raw_second, owner, 0, RDMA_SC_OK);
      if (engine.retired_count() != base_sequence + 2 ||
          engine.cq_consumed_count() != base_sequence + 2 ||
          engine.tokens_in_use_count() != 0 || engine.entry_registry_count() != 0)
        `uvm_error(label, "repair did not reclaim the contiguous completed prefix")
    end
    engine.shutdown(status);
    expect_status({label, "_SHUTDOWN"}, status, RDMA_SC_OK);
  endtask

  // 功能：运行普通/晚到 × 首圈/第二圈 × 四种后项结果，共 16 个公开流程对照例。
  // 输入/输出及副作用：phase 用于 objection；输出唯一完成标记，不调用父 run_phase。
  // 失败/边界：10us watchdog 防止锁或循环挂死；任一断言进入 UVM 非零报告使 runner 失败。
  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    fork
      begin
        for (int late = 0; late < 2; late++)
          for (int wrapped = 0; wrapped < 2; wrapped++)
            for (int mode = 0; mode < 4; mode++)
              run_case(bit'(late), bit'(wrapped), mode);
      end
      begin
        #10us;
        `uvm_fatal("POLL_WATCHDOG", "completion transaction matrix timed out")
      end
    join_any
    disable fork;
    `uvm_info("POLL_MATRIX", "completed 16 CMQ poll transaction cases", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass
