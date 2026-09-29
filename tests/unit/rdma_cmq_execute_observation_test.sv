// 目录/层次：tests/unit，CMQ execute 的 retained observation 对照测试。
// 职责：在真实 submit 返回边界注入 journal 生命周期，检查立即交付、等待与失败回退。
// 依赖：rdma_cmq_engine_test 的 ACTIVE fixture、mock adapter、profile 和状态断言。
// 所有权/生命周期：每例独占 engine/adapter；probe 只在串行窗口借用 journal 注入，
//   验证后撤销注入并 shutdown；不运行父类 run_phase，不创建跨例 factory override。

// 设计说明：只替换可委托的 submit 返回边界，execute/build/wait 均运行生产实现。
// submitted 保留旧快照，retained 行独立改变，防止测试把 delegated status 当作 authority。
class rdma_cmq_execute_observation_probe extends rdma_cmq_engine_probe;
  `uvm_object_utils(rdma_cmq_execute_observation_probe)

  int unsigned mode;
  int unsigned submit_calls;
  bit submitted_ready;
  rdma_cmq_execution_result submitted;
  rdma_cmq_batch_submission_record record;
  rdma_status original_status;

  // 功能：构造默认 STAGED 场景的 probe，保留基类未配置状态。
  // 输入/输出及副作用：name 交给基类；计数/ready 清零，所有借用引用置 null。
  // 失败/边界：构造不申请 backing；必须先由本例 prepare_active 完成真实配置。
  function new(string name = "rdma_cmq_execute_observation_probe");
    super.new(name);
    mode = 0;
    submit_calls = 0;
    submitted_ready = 1'b0;
    submitted = null;
    record = null;
    original_status = null;
  endfunction

  // 功能：真实提交一次后改变 retained lifecycle；另提供 null/PRE 委托返回故障。
  // 输入/输出及副作用：command 原样交给 super，result 为 detached submitted；mode
  //   0..6 设置七类 journal 状态，7 原样等待超时，8 阻止 wait，9 供异步索引故障，
  //   10 坏 host phase，11 坏 attempt，12 缺索引，13 null，14 合法 PRE，15 畸形 PRE。
  // 失败/边界：真实提交缺行直接 fatal；只注入本例持有的行，原 status 留给清理恢复；
  //   ready 在注入结束后发布，不替换生产 execute/wait 或直接调用其快照 helper。
  virtual task submit_observed(input rdma_cmq_command_desc command,
                              output rdma_cmq_execution_result result);
    rdma_cmq_batch_submission_item_record item;
    rdma_hw_cmq_completion payload;

    submit_calls++;
    if (mode >= 13) begin
      result = mode == 13 ? null : new_submit_result_direct("delegated_pre");
      if (mode == 15)
        result.batch_id = 1;
      submitted = result;
      submitted_ready = 1'b1;
      return;
    end
    super.submit_observed(command, result);
    if (result == null || result.ticket == null)
      `uvm_fatal("EXECUTE_FIXTURE", "real submit did not produce a ticket")
    submitted = result;
    record = journal_record_fault_reference(result.batch_key);
    if (record == null || record.items.size() != 1 || record.items[0] == null)
      `uvm_fatal("EXECUTE_FIXTURE", "real submit did not retain one item")
    item = record.items[0];
    original_status = item.status;
    result.status = rdma_cmq_direct_status(RDMA_SC_INVALID_STATE, "old delegated status");
    if (mode <= 6 || mode == 10) begin
      item.status = rdma_cmq_direct_status(RDMA_SC_TIMEOUT, "retained operation");
      item.completion_phase = RDMA_CMQ_COMPLETION_NONE;
      item.submission_effect = RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED;
      item.attempt_effect = RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED;
      item.recovery_required = 1'b1;
      case (mode)
        0: begin
          item.state = RDMA_CMQ_SUBMISSION_STAGED;
          item.submission_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
          item.attempt_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
        end
        1: item.state = RDMA_CMQ_SUBMISSION_PENDING_EFFECT;
        2: item.state = RDMA_CMQ_SUBMISSION_HOST_VISIBLE_NOT_PUBLISHED;
        3: begin
          item.state = RDMA_CMQ_SUBMISSION_COMPLETED;
          item.completion_phase = RDMA_CMQ_COMPLETION_TERMINAL;
          item.status = rdma_cmq_direct_status(RDMA_SC_OK, "retained completion");
          item.recovery_required = 1'b0;
        end
        4: begin
          item.state = RDMA_CMQ_SUBMISSION_TIMED_OUT_QUARANTINED;
          item.completion_phase = RDMA_CMQ_COMPLETION_TIMEOUT;
        end
        5: begin
          item.state = RDMA_CMQ_SUBMISSION_LATE_COMPLETED;
          item.completion_phase = RDMA_CMQ_COMPLETION_DIAGNOSTIC_ONLY;
          item.status = rdma_cmq_direct_status(RDMA_SC_OK, "retained late completion");
          item.recovery_required = 1'b0;
        end
        6: begin
          item.state = RDMA_CMQ_SUBMISSION_RESET_QUARANTINED;
          item.completion_phase = RDMA_CMQ_COMPLETION_RESET_CANCELLED;
          item.status = rdma_cmq_direct_status(RDMA_SC_RESET_CANCELLED, "retained reset");
        end
        10: begin
          item.state = RDMA_CMQ_SUBMISSION_HOST_VISIBLE_NOT_PUBLISHED;
          item.completion_phase = RDMA_CMQ_COMPLETION_TERMINAL;
        end
        default: `uvm_fatal("EXECUTE_MODE", "unsupported retained lifecycle mode")
      endcase
      if (mode inside {[3:6]}) begin
        item.submission_effect = RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
        item.attempt_effect = RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
        item.completion = new("retained_completion");
        item.completion.ticket = item.ticket;
        item.completion.status = item.status;
        // 正常/晚到硬件完成必须保留原始 CQE；timeout/reset 则允许没有硬件图像。
        if (mode inside {3, 5}) begin
          item.completion.raw_cqe = new("retained_raw_cqe");
          item.completion.raw_cqe.length = 64;
          item.completion.raw_cqe.alignment = 64;
          item.completion.raw_cqe.image_kind = RDMA_IMAGE_CMQ_CQE;
          item.completion.raw_cqe.hardware_version = RDMA_HW_VERSION;
          item.completion.raw_cqe.function_generation = item.ticket.function_h.generation;
          repeat (64)
            item.completion.raw_cqe.bytes.push_back(0);
        end
        payload = new("retained_payload");
        payload.opcode = item.ticket.opcode_key.opcode;
        payload.wqe_index = item.ticket.sq_index;
        payload.wrap = item.ticket.sq_wrap;
        payload.object_payload = new[1];
        payload.object_payload[0] = 8'ha5;
        item.completion.decoded_response = payload;
      end
      record.state = item.state;
    end
    if (mode == 8)
      reset_release_in_progress = 1'b1;
    if (mode == 11)
      result.attempt_id++;
    if (mode == 12)
      hide_ticket_index();
    submitted_ready = 1'b1;
  endtask

  // 功能：移除当前 ticket 的索引，模拟 wait 解锁后 retained authority 消失。
  // 输入/输出及副作用：无参数，只删除本例 record 对应索引；主行保留供清理恢复。
  // 失败/边界：record 缺失 fatal；调用必须位于 submit 串行窗口或 wait 的解锁等待期。
  function void hide_ticket_index();
    if (record == null)
      `uvm_fatal("EXECUTE_INDEX", "index fault has no retained record")
    journal_batch_by_ticket.delete(command_key(record.items[0].ticket));
  endfunction

  // 功能：验证 execute 已释放锁，再撤销本例 journal/gate/index 注入供真实 shutdown。
  // 输入/输出及副作用：无参数；try_get 成功后立即归还锁，恢复原 pending status/effect。
  // 失败/边界：锁泄漏 fatal；mode 7 的真实 timeout 不撤销，null/PRE 场景无行可恢复。
  function void restore_fixture();
    if (!engine_lock.try_get(1))
      `uvm_fatal("EXECUTE_LOCK", "execute left the engine locked")
    engine_lock.put(1);
    reset_release_in_progress = 1'b0;
    if (record == null || mode == 7)
      return;
    journal_batch_by_ticket[command_key(record.items[0].ticket)] = record.batch_key;
    record.state = RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED;
    record.items[0].state = RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED;
    record.items[0].status = original_status;
    record.items[0].completion = null;
    record.items[0].completion_phase = RDMA_CMQ_COMPLETION_PENDING;
    record.items[0].submission_effect = RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
    record.items[0].attempt_effect = RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
    record.items[0].recovery_required = 1'b1;
  endfunction
endclass

// 设计说明：固定各分支的诊断预期，另外逐字段检查 snapshot 分离；所有调用均从
// 公共 execute 进入，只有真实 timeout/索引竞争场景允许消耗仿真时间。
class rdma_cmq_execute_observation_test extends rdma_cmq_engine_test;
  `uvm_component_utils(rdma_cmq_execute_observation_test)

  // 功能：建立独立 observation 矩阵，仅复用基类配置 helper。
  // 输入/输出及副作用：name/parent 交给 UVM 基类；不安装全局 override 或外部依赖。
  // 失败/边界：构造不运行场景；每例必须独立创建并释放 backing。
  function new(string name = "rdma_cmq_execute_observation_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：运行一个生命周期/委托场景，验证 retained 优先、独立结果或精确 fallback。
  // 输入/输出及副作用：mode 对应 probe 场景，fault=0 正常，1 payload null status，
  //   2 payload 明确拒绝；创建 ACTIVE engine，执行一次 execute 后检查输出并 shutdown。
  // 失败/边界：fault 仅用于 mode 3..6；ready 后 100ps 注入索引丢失，watchdog 捕获
  //   意外等待；正常立即分支不得耗时，等待只信 retained completion，不信旧 result。
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
    rdma_cmq_execution_result result;
    rdma_cmq_batch_submission_item_record item;
    rdma_status status;
    rdma_status_code_e expected_code;
    string expected_message;
    string label;
    bit fallback;
    time started;

    label = $sformatf("EXECUTE_M%0d_F%0d", mode, fault);
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
    engine.mode = mode;
    if (fault == 1)
      profile.completion_payload_hook_fault = RDMA_CMQ_TEST_HOOK_NULL_STATUS;
    if (fault == 2)
      profile.completion_payload_hook_fault = RDMA_CMQ_TEST_HOOK_NONOK_STATUS;
    command = make_command({label, "_command"}, active_binding,
                            rdma_cmq_test_profile::TEST_OPCODE_A, 8'hd1, 5ns);
    started = $time;
    fork
      engine.execute_observed(command, result);
      begin
        if (mode == 9) begin
          wait (engine.submitted_ready);
          #100ps;
          engine.hide_ticket_index();
        end
      end
    join
    if (result == null || result.status == null || result.observation_status == null)
      `uvm_fatal(label, "execute omitted required result/status")
    if (engine.submit_calls != 1 ||
        (!(mode inside {7, 9}) && $time != started) ||
        (mode == 7 && $time < started + 5ns))
      `uvm_error(label, "submit count or wait boundary changed")

    expected_code = RDMA_SC_OK;
    fallback = mode inside {9, 10, 11, 12, 14, 15} || fault != 0;
    case (mode)
      0, 1: begin
        expected_code = RDMA_SC_INVALID_STATE;
        expected_message = "CMQ observed item has pending external effect";
      end
      2: expected_message = "CMQ retained host-visible journal observed";
      3, 4, 5, 6: expected_message = "CMQ retained journal completion observed";
      7: expected_message = "CMQ retained journal completion observed after wait";
      8: begin
        expected_code = RDMA_SC_INVALID_STATE;
        expected_message = "CMQ observed wait produced no retained completion";
      end
      9: expected_message = "CMQ observed wait produced no retained snapshot";
      10: expected_message = "CMQ observed host-visible lifecycle mismatch";
      11: expected_message = "CMQ observed journal identity mismatch";
      12: expected_message = "CMQ observed journal lookup failed";
      13: expected_message = "CMQ observed submit returned null result";
      14: expected_message = "";
      15: expected_message = "CMQ observed submit returned malformed zero-identity envelope";
      default: `uvm_fatal(label, "unsupported observation mode")
    endcase
    if (mode >= 9 && mode != 14)
      expected_code = RDMA_SC_INVALID_STATE;
    if (fault != 0) begin
      expected_code = RDMA_SC_INVALID_STATE;
      expected_message = fault == 1 ? "CMQ completion payload snapshot returned null status" :
                                     "injected completion payload snapshot rejection";
    end
    if (result.observation_status.code != expected_code ||
        result.observation_status.message != expected_message)
      `uvm_error(label, $sformatf("observation mismatch: %s, expected %s",
        result.observation_status.convert2string(), expected_message))
    if (fallback && result != engine.submitted)
      `uvm_error(label, "failed observation did not retain delegated result")
    if (mode <= 8 && fault == 0) begin
      item = engine.record.items[0];
      if (result == engine.submitted || result.ticket == item.ticket ||
          result.status == item.status || result.dma_context == item.dma_context ||
          result.recovery_owner == item.recovery_owner ||
          result.status.code != item.status.code || result.status.message != item.status.message ||
          result.batch_key != engine.record.batch_key ||
          result.batch_id != engine.record.batch_id ||
          result.attempt_id != engine.record.attempt_id ||
          result.submission_effect != item.submission_effect ||
          result.attempt_effect != item.attempt_effect ||
          result.completion_phase != item.completion_phase ||
          result.recovery_required != item.recovery_required ||
          result.ticket.absolute_deadline != item.ticket.absolute_deadline)
        `uvm_error(label, "retained values or detached ownership changed")
      if (item.completion != null &&
          (result.completion == null || result.completion == item.completion ||
           result.completion.ticket != result.ticket || result.completion.status != result.status))
        `uvm_error(label, "completion aliases were not preserved within detached graph")
      if (mode == 7 && (result.status.code != RDMA_SC_TIMEOUT ||
                       result.completion_phase != RDMA_CMQ_COMPLETION_TIMEOUT))
        `uvm_error(label, "wait did not deliver real retained timeout")
    end
    if (mode inside {13, 15} &&
        (result.submission_effect != RDMA_SUBMIT_EFFECT_UNOBSERVED ||
         result.attempt_effect != RDMA_SUBMIT_EFFECT_UNOBSERVED ||
         result.completion_phase != RDMA_CMQ_COMPLETION_UNOBSERVED || !result.recovery_required))
      `uvm_error(label, "malformed delegation was not conservatively unobserved")
    profile.completion_payload_hook_fault = RDMA_CMQ_TEST_HOOK_GOOD;
    engine.restore_fixture();
    engine.shutdown(status);
    expect_status(label, status, RDMA_SC_OK);
  endtask

  // 功能：运行 16 个分支场景及四种终态的两种 payload 故障，共 24 例。
  // 输入/输出及副作用：phase 管理 objection，完成后输出唯一矩阵标记；不调用父矩阵。
  // 失败/边界：10us watchdog 捕获锁泄漏或错误进入 wait；任一非零 UVM severity 使 runner 失败。
  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    fork
      begin
        for (int mode = 0; mode < 16; mode++)
          run_case(mode);
        for (int mode = 3; mode <= 6; mode++)
          for (int fault = 1; fault <= 2; fault++)
            run_case(mode, fault);
      end
      begin
        #10us;
        `uvm_fatal("EXECUTE_OBSERVATION_WATCHDOG", "observation matrix timed out")
      end
    join_any
    disable fork;
    `uvm_info("EXECUTE_OBSERVATION_MATRIX", "completed 24 CMQ execute observation cases", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass
