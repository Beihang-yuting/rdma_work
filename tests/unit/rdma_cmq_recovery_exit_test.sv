// 目录/层次：tests/unit，CMQ 恢复失败出口的公开调用对照测试。
// 职责：连续拒绝同一请求并修复后重试，检查 aligned 结果、首错优先级和锁释放。
// 依赖：rdma_cmq_engine_test 的 retained journal fixture、断言和 scheduler double。
// 所有权/生命周期：每例独占 engine/adapter，借用 fixture 的 retained row 注入故障；
//   结束前删除本例 journal 并 shutdown，不运行父类 run_phase 或建立跨例状态。

// 设计说明：统一出口不能让 owner foreach 的 break 只退出内层，也不能把未定位
// 请求变为 aligned failure；每例连续失败两次、再成功提交可同时检查这两个边界。
class rdma_cmq_recovery_exit_test extends rdma_cmq_engine_test;
  `uvm_component_utils(rdma_cmq_recovery_exit_test)

  // 功能：建立独立 recovery exit test，只复用父类 fixture/断言。
  // 输入/输出及副作用：name/parent 传给 UVM 基类；不创建或接管外部资源。
  // 失败/边界：构造不执行 recovery；每例必须由 prepare_recovery_fixture 建立 authority。
  function new(string name = "rdma_cmq_recovery_exit_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：对三个 retained item 注入一个拒绝点，重复拒绝后修复并执行一次真实 retry。
  // 输入/输出及副作用：mode=0 未定位，1 result staging，2 stale+坏 action，3 坏 action，
  //   4 profile，5..7 首/中/末 owner 无 RETRY 权限，8 live state，9 counter 耗尽，
  //   10 observer staging，11 CONFIRM lifecycle；检查双次拒绝零 CAS/I/O 和第三次提交。
  // 失败/边界：fixture 不全立即 fatal；失败必须保持 aligned/current-attempt/recovery
  //   证据，未定位例必须为空。修复仅撤销本例故障，不清除被测函数错误产生的副作用。
  task run_case(int unsigned mode);
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_transport_scheduler_double scheduler;
    rdma_cmq_journal_tracking_profile profile_service;
    rdma_function_binding binding;
    rdma_cmq cmq;
    rdma_cmq_batch_submission_record source_record;
    rdma_cmq_batch_submission_record record;
    rdma_cmq_preallocated_publish_batch preallocated;
    rdma_cmq_submission_recovery_request request;
    rdma_cmq_recovery_owner saved_request_owner;
    rdma_cmq_recovery_owner saved_record_owner;
    rdma_cmq_execution_result results[];
    rdma_status status;
    rdma_status_code_e expected_code;
    string expected_message;
    string label;
    longint unsigned saved_counter;
    int unsigned owner_index;

    label = $sformatf("RECOVERY_EXIT_%0d", mode);
    prepare_recovery_fixture(label, 3, RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN,
      engine, mem, scheduler, profile_service, binding, cmq, source_record,
      request, record, preallocated, status);
    if (status == null || !status.ok() || request == null || record == null ||
        preallocated == null || request.items.size() != 3)
      `uvm_fatal(label, "recovery exit fixture is incomplete")
    saved_counter = engine.journal_attempt_counter();
    expected_code = RDMA_SC_INVALID_STATE;
    expected_message = "";
    case (mode)
      1: engine.set_recovery_stage_fault(RDMA_CMQ_RECOVERY_STAGE_RESULT_NULL);
      2: begin
        request.expected_attempt_id++;
        request.action = RDMA_CMQ_RECOVERY_INVALID;
        expected_message = "stale CMQ recovery attempt";
      end
      3: begin
        request.action = RDMA_CMQ_RECOVERY_INVALID;
        expected_code = RDMA_SC_INVALID_ARGUMENT;
        expected_message = "CMQ recovery action is invalid or unsupported";
      end
      4: begin
        profile_service.reject_journal_values = 1'b1;
        expected_code = RDMA_SC_INVALID_ARGUMENT;
      end
      5, 6, 7: begin
        owner_index = mode - 5;
        saved_request_owner = request.items[owner_index].recovery_owner;
        saved_record_owner = record.items[owner_index].recovery_owner;
        request.items[owner_index].recovery_owner = make_frozen_recovery_owner(
          "request_confirm_only", RDMA_CMQ_WORKFLOW_QUEUE, RDMA_RESOURCE_CQ,
          record.function_identity, saved_record_owner.admission_attempt_id, 3'b100);
        record.items[owner_index].recovery_owner = make_frozen_recovery_owner(
          "record_confirm_only", RDMA_CMQ_WORKFLOW_QUEUE, RDMA_RESOURCE_CQ,
          record.function_identity, saved_record_owner.admission_attempt_id, 3'b100);
        request.items[owner_index].command.recovery_owner =
          request.items[owner_index].recovery_owner;
        record.items[owner_index].command.recovery_owner =
          record.items[owner_index].recovery_owner;
        status = recompute_recovery_request_digests(profile_service, request);
        expect_status(label, status, RDMA_SC_OK);
        status = recompute_recovery_record_digests(profile_service, record);
        expect_status(label, status, RDMA_SC_OK);
        expected_code = RDMA_SC_INVALID_ARGUMENT;
        expected_message = "CMQ recovery owner does not authorize this action";
      end
      8: engine.force_observed_engine_state(RDMA_CMQ_ENGINE_QUIESCED);
      9: begin
        engine.seed_journal_counters(engine.journal_engine_incarnation(),
          engine.journal_batch_counter(), 64'hffff_ffff_ffff_ffff,
          engine.journal_reset_proof_counter());
        expected_code = RDMA_SC_RESOURCE_EXHAUSTED;
        expected_message = "CMQ attempt IDs are exhausted";
      end
      10: engine.set_recovery_stage_fault(RDMA_CMQ_RECOVERY_STAGE_OBSERVER_NULL);
      11: begin
        request.action = RDMA_CMQ_RECOVERY_CONFIRM_RESET_ISOLATION;
        expected_message = "CMQ reset confirmation requires a quarantined batch";
      end
      default: ;
    endcase
    repeat (2) begin
      if (mode == 0)
        expect_recovery_structural_rejected(label, engine, scheduler, null,
                                            record, preallocated);
      else
        expect_recovery_rejected(label, engine, scheduler, request, record,
          preallocated, 0, expected_message, "", expected_code);
      if (mem.calls.size() != 0)
        `uvm_error(label, "rejection performed Host-memory I/O")
    end

    engine.set_recovery_stage_fault(RDMA_CMQ_RECOVERY_STAGE_NONE);
    profile_service.reject_journal_values = 1'b0;
    request.expected_attempt_id = record.attempt_id;
    request.action = RDMA_CMQ_RECOVERY_RETRY_PUBLISH;
    if (mode inside {5, 6, 7}) begin
      request.items[owner_index].recovery_owner = saved_request_owner;
      request.items[owner_index].command.recovery_owner = saved_request_owner;
      record.items[owner_index].recovery_owner = saved_record_owner;
      record.items[owner_index].command.recovery_owner = saved_record_owner;
      status = recompute_recovery_request_digests(profile_service, request);
      expect_status(label, status, RDMA_SC_OK);
      status = recompute_recovery_record_digests(profile_service, record);
      expect_status(label, status, RDMA_SC_OK);
    end
    if (mode == 8)
      engine.force_observed_engine_state(RDMA_CMQ_ENGINE_ACTIVE);
    if (mode == 9)
      engine.seed_journal_counters(engine.journal_engine_incarnation(),
        engine.journal_batch_counter(), saved_counter, engine.journal_reset_proof_counter());
    engine.recover_submission_observed(request, results, status);
    expect_recovery_attempt_results(label, request, results, status,
      RDMA_SC_INVALID_STATE, RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN,
      RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED, RDMA_CMQ_COMPLETION_NONE,
      1'b1, saved_counter + 1);
    if (scheduler.submit_calls != 1 || record.attempt_id != saved_counter + 1)
      `uvm_error(label, "repair did not perform exactly one retry")
    status = engine.remove_submission_journal_probe(record.batch_key);
    expect_status(label, status, RDMA_SC_OK);
    engine.shutdown(status);
    expect_status(label, status, RDMA_SC_OK);
  endtask

  // 功能：运行 12 种退出/修复场景，共 36 次 recovery 调用。
  // 输入/输出及副作用：phase 用于 objection，输出唯一矩阵完成标记；不调用父 run_phase。
  // 失败/边界：10us watchdog 捕获锁泄漏或循环未退出；任一 UVM 非零 severity 使 runner 失败。
  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    fork
      begin
        for (int mode = 0; mode < 12; mode++)
          run_case(mode);
      end
      begin
        #10us;
        `uvm_fatal("RECOVERY_EXIT_WATCHDOG", "recovery exit matrix timed out")
      end
    join_any
    disable fork;
    `uvm_info("RECOVERY_EXIT_MATRIX", "completed 36 CMQ recovery exit calls", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass
