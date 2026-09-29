// 目录/层次：tests/unit，CMQ RETRY 提交与发布阶段的公开调用对照测试。
// 职责：跨累计 evidence、真实 arm、原始 effect 与畸形 envelope 验证提交/交付顺序。
// 依赖：rdma_cmq_engine_test 的三项 retained fixture、scheduler double 与结果断言。
// 所有权/生命周期：每例独占 engine/adapter；scheduler 仅借用该例 journal/preallocation，
//   factory override 只在本独立仿真进程内生效，不运行父类 run_phase。

// 设计说明：在 transport 回调边界观察已提交的 attempt，可捕捉阶段提取时错误地
// 把 CAS 移到 I/O 之后；记录属于 engine，替身只读，不替代真实 observer 的消费逻辑。
class rdma_cmq_recovery_publish_scheduler extends rdma_cmq_transport_scheduler_double;
  `uvm_object_utils(rdma_cmq_recovery_publish_scheduler)

  rdma_cmq_engine_probe engine;
  rdma_cmq_batch_submission_record record;
  rdma_cmq_preallocated_publish_batch preallocated;
  longint unsigned expected_attempt;

  // 功能：构造尚未绑定 fixture 的发布边界观察器，继承原 scheduler 响应机制。
  // 输入/输出及副作用：name 交给基类；借用引用默认 null，expected_attempt 默认零。
  // 失败/边界：构造不创建 runtime 或接管 journal；调用前必须安装本例非拥有引用。
  function new(string name = "rdma_cmq_recovery_publish_scheduler");
    super.new(name);
    engine = null;
    record = null;
    preallocated = null;
    expected_attempt = 0;
  endfunction

  // 功能：在真实 observer 被调用前检查唯一 CAS、逐项 pending 与 capability 已就绪。
  // 输入/输出及副作用：binding/desc/observer 借用后原样传给父类，result 保留预置响应；
  //   只读 engine/record/preallocated，父类计数并按开关同步触发 observer。
  // 失败/边界：fixture 缺失立即 fatal；attempt、pending 或 registry 未提交时报告错误，
  //   不修复 DUT 状态，不把返回的 MMIO effect 当作真实 arm。
  virtual task submit_observed(
    rdma_function_binding binding,
    rdma_doorbell_desc desc,
    rdma_doorbell_submission_observer observer,
    output rdma_doorbell_submission_result result
  );
    if (engine == null || record == null || preallocated == null)
      `uvm_fatal("RETRY_PUBLISH_FIXTURE", "scheduler fixture is incomplete")
    if (engine.journal_attempt_counter() != expected_attempt ||
        record.attempt_id != expected_attempt ||
        preallocated.attempt_id != expected_attempt ||
        record.state != RDMA_CMQ_SUBMISSION_PENDING_EFFECT ||
        record.attempt_effect != RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE ||
        record.observer_armed || record.publication_retry_safe ||
        engine.mmio_arm_observer_count() != 1 || observer == null)
      `uvm_error("RETRY_PUBLISH_CAS", "transport entered before complete attempt commit")
    foreach (record.items[i]) begin
      if (record.items[i].state != RDMA_CMQ_SUBMISSION_PENDING_EFFECT ||
          record.items[i].attempt_effect != RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE ||
          record.items[i].completion_phase != RDMA_CMQ_COMPLETION_NONE ||
          record.items[i].completion != null || record.items[i].reset_isolation_confirmed ||
          !record.items[i].recovery_required || record.items[i].status == null ||
          !record.items[i].status.ok())
        `uvm_error("RETRY_PUBLISH_ITEM_CAS", "item was not staged before transport")
    end
    super.submit_observed(binding, desc, observer, result);
  endtask
endclass

// 设计说明：预期表只消费测试输入，不调用 DUT 的 decode/classify/fold helper；
// 三项结果必须与 retained evidence 相同且状态对象分离，避免复用实现自证正确。
class rdma_cmq_recovery_publish_test extends rdma_cmq_engine_test;
  `uvm_component_utils(rdma_cmq_recovery_publish_test)

  // 功能：建立独立 RETRY 发布矩阵，只复用父类 fixture 和断言。
  // 输入/输出及副作用：name/parent 交给基类，不创建或持有外部环境资源。
  // 失败/边界：不运行父类矩阵；每个场景自行 prepare、删除 journal 和 shutdown。
  function new(string name = "rdma_cmq_recovery_publish_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：提交一次三项 RETRY，检查调用前 CAS、arm 授权和调用后证据/结果交付。
  // 输入/输出及副作用：prior 取四种可恢复累计值，armed 决定真实 observer 回调；
  //   mode=0..6 为合法 effect，7 null envelope，8 null status，9 spare，10 X，11 Z；
  //   自建 fixture，检查一次 attempt/transport、原 deadline/owner 和独立 status。
  // 失败/边界：夹具或 scheduler cast 失败立即 fatal；畸形 envelope 不撤销已提交的
  //   attempt，不降级累计证据；scheduler 的 null envelope/status 先经过真实
  //   transport 修复，保留其 operation 文案；未 arm 自报 MMIO 禁止重试但保留 fence。
  task run_case(rdma_submission_effect_e prior, bit armed, int unsigned mode);
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_transport_scheduler_double scheduler;
    rdma_cmq_recovery_publish_scheduler checked_scheduler;
    rdma_cmq_journal_tracking_profile profile_service;
    rdma_function_binding binding;
    rdma_cmq cmq;
    rdma_cmq_batch_submission_record source_record;
    rdma_cmq_batch_submission_record record;
    rdma_cmq_preallocated_publish_batch preallocated;
    rdma_cmq_submission_recovery_request request;
    rdma_cmq_execution_result results[];
    rdma_status status;
    rdma_submission_effect_e effects[7];
    rdma_submission_effect_e raw_effect;
    rdma_submission_effect_e expected_attempt_effect;
    rdma_submission_effect_e expected_cumulative;
    rdma_cmq_submission_state_e expected_state;
    rdma_status_code_e operation_code;
    rdma_status_code_e observation_code;
    string operation_message;
    string observation_message;
    string label;
    string fence_key;
    string fence_reason;
    bit fence_active;
    bit retry_safe;
    longint unsigned next_attempt;
    longint unsigned admission_attempt;

    effects = '{RDMA_SUBMIT_EFFECT_UNOBSERVED, RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED,
      RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE, RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN,
      RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED, RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE,
      RDMA_SUBMIT_EFFECT_MMIO_VISIBLE};
    label = $sformatf("RETRY_PUBLISH_%0d_%0d_%0d", prior, armed, mode);
    prepare_recovery_fixture(label, 3, prior, engine, mem, scheduler, profile_service,
      binding, cmq, source_record, request, record, preallocated, status);
    if (status == null || !status.ok() || record == null || preallocated == null ||
        request == null || !$cast(checked_scheduler, scheduler))
      `uvm_fatal(label, "recovery publish fixture is incomplete")
    next_attempt = engine.journal_attempt_counter() + 1;
    admission_attempt = record.items[0].recovery_owner.admission_attempt_id;
    checked_scheduler.engine = engine;
    checked_scheduler.record = record;
    checked_scheduler.preallocated = preallocated;
    checked_scheduler.expected_attempt = next_attempt;

    operation_code = mode[0] ? RDMA_SC_TIMEOUT : RDMA_SC_OK;
    operation_message = $sformatf("transport_mode_%0d", mode);
    raw_effect = mode < 7 ? effects[mode] : RDMA_SUBMIT_EFFECT_UNOBSERVED;
    scheduler.response = make_recovery_transport_response(label, operation_code,
      raw_effect, operation_message);
    scheduler.invoke_observer_before_return = armed;
    observation_code = RDMA_SC_OK;
    observation_message = "";
    case (mode)
      7: begin
        scheduler.return_null_result = 1'b1;
        operation_code = RDMA_SC_INVALID_STATE;
        operation_message = "CMQ transport scheduler returned null result";
      end
      8: begin
        scheduler.response.status = null;
        scheduler.response.submission_effect = RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED;
        raw_effect = RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED;
        operation_code = RDMA_SC_INVALID_STATE;
        operation_message = "CMQ transport scheduler returned null status";
      end
      9, 10, 11: begin
        case (mode)
          9: scheduler.response.submission_effect = rdma_submission_effect_e'(8'hff);
          10: scheduler.response.submission_effect = rdma_submission_effect_e'('x);
          11: scheduler.response.submission_effect = rdma_submission_effect_e'('z);
        endcase
        observation_code = RDMA_SC_INVALID_STATE;
        observation_message = "CMQ recovery transport effect is malformed";
      end
      default: ;
    endcase

    expected_attempt_effect = raw_effect;
    retry_safe = !armed;
    if (armed) begin
      expected_state = raw_effect == RDMA_SUBMIT_EFFECT_MMIO_VISIBLE ?
        RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED : RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS;
      expected_cumulative = raw_effect == RDMA_SUBMIT_EFFECT_MMIO_VISIBLE ?
        RDMA_SUBMIT_EFFECT_MMIO_VISIBLE : RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE;
      if (raw_effect inside {RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED,
            RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE, RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN,
            RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED}) begin
        expected_attempt_effect = RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE;
        observation_code = RDMA_SC_INVALID_STATE;
        observation_message = "CMQ recovery transport effect contradicts authentic MMIO arm";
      end
    end
    else begin
      expected_state = RDMA_CMQ_SUBMISSION_HOST_VISIBLE_NOT_PUBLISHED;
      expected_cumulative = prior;
      if (raw_effect inside {
            RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE, RDMA_SUBMIT_EFFECT_MMIO_VISIBLE}) begin
        expected_attempt_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
        retry_safe = 1'b0;
        observation_code = RDMA_SC_INVALID_STATE;
        observation_message = "CMQ recovery transport reported MMIO without authentic arm";
      end
      else if (raw_effect inside {RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE,
                   RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN,
                   RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED} &&
               raw_effect > prior)
        expected_cumulative = raw_effect;
    end

    engine.recover_submission_observed(request, results, status);
    expect_recovery_attempt_results(label, request, results, status, operation_code,
      expected_cumulative, expected_attempt_effect,
      armed ? RDMA_CMQ_COMPLETION_PENDING : RDMA_CMQ_COMPLETION_NONE, 1'b1, next_attempt);
    if (scheduler.submit_calls != 1 || engine.journal_attempt_counter() != next_attempt ||
        record.attempt_id != next_attempt || preallocated.attempt_id != next_attempt ||
        record.state != expected_state || record.submission_effect != expected_cumulative ||
        record.attempt_effect != expected_attempt_effect || record.observer_armed != armed ||
        record.publication_retry_safe != retry_safe || engine.mmio_arm_observer_count() != 0 ||
        engine.preallocated_publish_batch_count() != (armed ? 0 : 1) ||
        engine.tokens_in_use_count() != (armed ? 3 : 0) || mem.calls.size() != 0)
      `uvm_error(label, "retry commit, observer consumption or evidence differs")
    foreach (results[i]) begin
      if (results[i].status.message != operation_message ||
          results[i].observation_status.code != observation_code ||
          results[i].observation_status.message != observation_message ||
          results[i].status == record.items[i].status ||
          results[i].status == results[i].observation_status ||
          record.items[i].status.code != operation_code ||
          record.items[i].status.message != operation_message ||
          record.items[i].state != expected_state ||
          record.items[i].submission_effect != expected_cumulative ||
          record.items[i].attempt_effect != expected_attempt_effect ||
          record.items[i].recovery_owner.admission_attempt_id != admission_attempt ||
          record.items[i].ticket.absolute_deadline != request.items[i].ticket.absolute_deadline)
        `uvm_error(label, "per-item evidence, diagnostics, owner or deadline differs")
    end
    engine.query_submission_fence(fence_active, fence_key, fence_reason, status);
    expect_status(label, status, RDMA_SC_OK);
    if (fence_active != !armed ||
        (!armed && (fence_key != record.batch_key || fence_reason.len() == 0)) ||
        (armed && (fence_key.len() != 0 || fence_reason.len() != 0)))
      `uvm_error(label, "retry fence did not follow authentic arm")
    status = engine.remove_submission_journal_probe(record.batch_key);
    expect_status(label, status, RDMA_SC_OK);
    engine.shutdown(status);
    expect_status(label, status, RDMA_SC_OK);
  endtask

  // 功能：运行四种历史累计值 × 两种真实 arm × 十二类响应，共 96 个发布场景。
  // 输入/输出及副作用：phase 管理 objection；安装本进程 scheduler override 并输出完成标记。
  // 失败/边界：10us watchdog 捕获锁泄漏；每例独立 teardown，不调用父类 run_phase。
  virtual task run_phase(uvm_phase phase);
    rdma_submission_effect_e priors[4];
    uvm_factory factory;

    priors = '{RDMA_SUBMIT_EFFECT_UNOBSERVED, RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE,
      RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN, RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED};
    phase.raise_objection(this);
    factory = uvm_factory::get();
    factory.set_type_override_by_type(
      rdma_cmq_transport_scheduler_double::get_type(),
      rdma_cmq_recovery_publish_scheduler::get_type());
    fork
      begin
        foreach (priors[p])
          for (int armed = 0; armed < 2; armed++)
            for (int mode = 0; mode < 12; mode++)
              run_case(priors[p], armed != 0, mode);
      end
      begin
        #10us;
        `uvm_fatal("RETRY_PUBLISH_WATCHDOG", "recovery publish matrix timed out")
      end
    join_any
    disable fork;
    `uvm_info("RETRY_PUBLISH_MATRIX", "completed 96 CMQ recovery publish cases", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass
