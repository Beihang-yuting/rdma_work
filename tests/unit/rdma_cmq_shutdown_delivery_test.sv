// 目录/层次：tests/unit，CMQ shutdown 的关闭、释放失败和重试对照测试。
// 职责：通过公开 shutdown 检查四种合法状态、准入拒绝、两种释放方式及失败恢复。
// 依赖：CMQ engine_test 的真实 prepare/submit fixture 与 mock Host-memory/PCIe。
// 所有权/生命周期：每例独占 engine 和 adapter；probe 仅在串行测试窗口注入，
//   保存的 authority/诊断为非拥有引用，结束前恢复缺失 authority 并释放真实 allocation。

// 设计说明：只观测锁和内部引用，不覆盖 shutdown/cancel/retain 的生产实现。
class rdma_cmq_shutdown_probe extends rdma_cmq_engine_probe;
  `uvm_object_utils(rdma_cmq_shutdown_probe)

  rdma_dma_mapping saved_mapping;
  rdma_cmq_diagnostic saved_poison;
  rdma_cmq_batch_submission_record saved_record;
  int unsigned saved_journal_size;
  longint unsigned saved_attempt;

  // 功能：构造未配置的关闭 probe，尚不保存任何资源或诊断。
  // 输入/输出及副作用：name 传给基类；借用引用置 null，journal 数量与 attempt 置零。
  // 失败/边界：构造不分配 backing；seed 只能在本例完成 prepare 后或空引擎上调用。
  function new(string name = "rdma_cmq_shutdown_probe");
    super.new(name);
    saved_mapping = null;
    saved_poison = null;
    saved_record = null;
    saved_journal_size = 0;
    saved_attempt = 0;
  endfunction

  // 功能：保存原 backing/journal 行及 attempt，放入三种待丢弃 FIFO，并注入关闭模式。
  // 输入/输出及副作用：mode 0..3 选合法状态，4 空引擎，5/6 gate，7 非法状态，
  //   8 缺 adapter，9 缺 mapping；opaque 控制释放方式，last_poison 保存原对象。
  // 失败/边界：只用于串行夹具；不创建假 allocation，8/9 的 authority 由 restore 恢复。
  function void seed(int unsigned mode, bit opaque);
    rdma_cmq_completion completion;
    rdma_cmq_diagnostic diagnostic;

    saved_mapping = backing_mapping;
    saved_journal_size = submission_journal.num();
    foreach (submission_journal[key])
      saved_record = submission_journal[key];
    if (saved_record != null)
      saved_attempt = saved_record.attempt_id;
    completion = new("discarded_completion");
    diagnostic = new("discarded_diagnostic");
    terminal_fifo.push_back(completion);
    late_final_fifo.push_back(completion);
    diagnostic_fifo.push_back(diagnostic);
    last_poison = diagnostic;
    saved_poison = diagnostic;
    backing_release_opaque = opaque;
    case (mode)
      2: engine_state = RDMA_CMQ_ENGINE_QUIESCED;
      3: engine_state = RDMA_CMQ_ENGINE_POISONED;
      5, 6: reset_release_in_progress = 1'b1;
      7: engine_state = rdma_cmq_engine_state_e'(3'd7);
      8: host_mem = null;
      9: backing_mapping = null;
      default: begin end
    endcase
  endfunction

  // 功能：撤销本例 gate/非法状态/丢失 authority 注入，允许真实 shutdown 回收。
  // 输入/输出及副作用：mode 和 mem 为原夹具；仅修复相应字段，不回填已清理账本。
  // 失败/边界：8/9 恢复 saved_mapping 和 mem；不能视为生产支持的丢失 authority 恢复 API。
  function void restore(int unsigned mode, rdma_host_mem_api mem);
    reset_release_in_progress = 1'b0;
    if (mode == 7)
      engine_state = RDMA_CMQ_ENGINE_ACTIVE;
    if (mode inside {8, 9}) begin
      backing_mapping = saved_mapping;
      host_mem = mem;
    end
  endfunction

  // 功能：无阻塞检查 semaphore 当前恰好有 expected 个 token。
  // 输入/输出及副作用：expected 为 0 或 1；临时 try_get 两次后原数归还，返回匹配结果。
  // 失败/边界：不等待持锁调用；双重解锁产生两个 token 或漏解锁都会返回 0。
  function bit lock_tokens(int unsigned expected);
    bit first_token;
    bit second_token;

    first_token = engine_lock.try_get(1);
    second_token = engine_lock.try_get(1);
    if (first_token)
      engine_lock.put(1);
    if (second_token)
      engine_lock.put(1);
    return int'(first_token) + int'(second_token) == expected;
  endfunction

  // 功能：检查三种交付 FIFO 的数量，区分准入拒绝保留与开始关闭后的丢弃。
  // 输入/输出及副作用：expected 为每个 FIFO 的预期条数；只读返回 bit。
  // 失败/边界：任一队列数量不同即返回 0，不主动消费或修补输出。
  function bit fifo_counts(int unsigned expected);
    return terminal_fifo.size() == expected && diagnostic_fifo.size() == expected &&
           late_final_fifo.size() == expected;
  endfunction

  // 功能：核对失败后保留的是原 mapping/adapter/poison，而非克隆或新 allocation。
  // 输入/输出及副作用：mem/opaque 为预期引用与模式；只读，返回全部匹配结果。
  // 失败/边界：只用于已有完整 authority 的释放失败；缺 authority 场景另行检查。
  function bit retained_authority(rdma_host_mem_api mem, bit opaque);
    return retry_only_poisoned() && backing_mapping == saved_mapping && host_mem == mem &&
           backing_release_opaque == opaque && last_poison == saved_poison;
  endfunction

  // 功能：检查 shutdown 没有删除本例 retained journal 或把 pending 伪造成终态。
  // 输入/输出及副作用：无参数；按 seed 保存的行身份、数量以及真实 submit 的状态校验。
  // 失败/边界：本例至多提交一行；存在行时要求一项、原 attempt 及 PUBLISH_CONFIRMED，
  //   不把 runtime 清理误认为 observed reset proof，也不遍历外部账本。
  function bit journal_preserved();
    if (submission_journal.num() != saved_journal_size)
      return 0;
    if (saved_record == null)
      return saved_journal_size == 0;
    return submission_journal.exists(saved_record.batch_key) &&
           submission_journal[saved_record.batch_key] == saved_record &&
           saved_record.items.size() == 1 && saved_record.attempt_id == saved_attempt &&
           saved_record.items[0].state == RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED &&
           saved_record.reset_isolation_proof == null;
  endfunction
endclass

// 设计说明：在 adapter 边界检查仍持锁且 FIFO 已丢弃；故障不改变 allocation，
// 非 OK 直接返回 fixture 原 status，锁定 shutdown 不快照/重建错误的历史语义。
class rdma_cmq_shutdown_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_cmq_shutdown_mem)

  rdma_cmq_shutdown_probe engine;
  int unsigned fault;
  rdma_status failure;

  // 功能：构造无故障 adapter，并预建可检验对象身份的失败 status。
  // 输入/输出及副作用：name 传给 mock；engine 非拥有引用置 null，fault 置零。
  // 失败/边界：释放前必须绑定 engine；构造不申请或释放任何区域。
  function new(string name = "rdma_cmq_shutdown_mem");
    super.new(name);
    engine = null;
    fault = 0;
    failure = rdma_status::make(RDMA_SC_UNKNOWN_HW_ERROR, "shutdown injected release failure");
  endfunction

  // 功能：断言 adapter 调用发生在原锁窗口、原 mapping 上且没有待交付 FIFO。
  // 输入/输出及副作用：mapping 为释放参数；只读取 probe，错误通过 UVM_ERROR 发布。
  // 失败/边界：缺 engine fatal；不获取阻塞锁、不重入 shutdown、不修改外部资源。
  function void observe_release(rdma_dma_mapping mapping);
    if (engine == null)
      `uvm_fatal("SHUTDOWN_ADAPTER", "missing engine fixture")
    if (!engine.lock_tokens(0) || !engine.fifo_counts(0) || mapping != engine.saved_mapping)
      `uvm_error("SHUTDOWN_ADAPTER", "release lock, FIFO or mapping contract changed")
  endfunction

  // 功能：从普通 release 入口注入 null/非 OK，或委托真实 mock 回收 allocation。
  // 输入/输出及副作用：mapping 为待释放 authority；fault 1/2 只记调用并返回 null/failure。
  // 失败/边界：故障不修改 allocation；fault 0 的验证和释放失败由 super 原样返回。
  virtual function rdma_status \release (rdma_dma_mapping mapping);
    observe_release(mapping);
    if (fault != 0) begin
      record_call("release", null, mapping);
      return fault == 1 ? null : failure;
    end
    return super.\release (mapping);
  endfunction

  // 功能：从 opaque release 入口注入同类故障，并保留独立的调用方式记录。
  // 输入/输出及副作用：mapping 为 opaque authority；fault 1/2 只记 release_opaque 调用。
  // 失败/边界：不回退到普通 release；fault 0 委托 super，失败保持原 allocation。
  virtual function rdma_status release_opaque(rdma_dma_mapping mapping);
    observe_release(mapping);
    if (fault != 0) begin
      record_call("release_opaque", null, mapping);
      return fault == 1 ? null : failure;
    end
    return super.release_opaque(mapping);
  endfunction
endclass

// 设计说明：矩阵直接进入公开 shutdown；四种状态乘两种 release 乘三种结果，
// 另验六种准入/authority 边界。恢复及幂等调用同时检查每个出口只归还一个锁 token。
class rdma_cmq_shutdown_delivery_test extends rdma_cmq_engine_test;
  `uvm_component_utils(rdma_cmq_shutdown_delivery_test)

  // 功能：建立独立 shutdown 测试，不运行父类的大矩阵。
  // 输入/输出及副作用：name/parent 传给 UVM；各例自行拥有夹具和验证对象。
  // 失败/边界：构造不 prepare，不注册全局 factory override。
  function new(string name = "rdma_cmq_shutdown_delivery_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：执行一次 shutdown 并检查状态、精确诊断、锁 token 和零时间完成。
  // 输入/输出及副作用：engine/预期 code/message 为输入，status 返回 DUT 原对象供身份检查。
  // 失败/边界：status 为空 fatal；锁丢失/双重释放或发生额外等待均报告 UVM_ERROR。
  task call_shutdown(rdma_cmq_shutdown_probe engine, rdma_status_code_e code,
                     string message, output rdma_status status);
    time started;

    started = $time;
    engine.shutdown(status);
    if (status == null)
      `uvm_fatal("SHUTDOWN_STATUS", "null shutdown status")
    if (status.code != code || status.message != message ||
        !engine.lock_tokens(1) || $time != started)
      `uvm_error("SHUTDOWN_STATUS", status.convert2string())
  endtask

  // 功能：构造真实 backing/可选 pending 命令，检查关闭或拒绝，再撤销故障重试并幂等关闭。
  // 输入/输出及副作用：mode 0..9 与 seed 同义；opaque/fault 选择释放矩阵，产生 UVM 断言。
  // 失败/边界：gate/非法状态不得触及 FIFO 或 adapter；释放失败须保留原 authority/诊断；
  //   缺 authority 不得调用 adapter，恢复是测试专用注入，不声称生产能够找回丢失引用。
  task run_case(int unsigned mode, bit opaque = 0, int unsigned fault = 0);
    rdma_cmq_shutdown_probe engine;
    rdma_cmq_shutdown_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_execution_result submitted;
    rdma_cmq_command_desc command;
    rdma_status status;
    rdma_status_code_e code;
    string message;
    string label;
    string release_method;
    int unsigned before_mem;
    int unsigned before_pcie;
    int unsigned expected_release;

    label = $sformatf("SHUTDOWN_M%0d_O%0b_F%0d", mode, opaque, fault);
    engine = new({label, "_engine"});
    mem = new({label, "_mem"});
    mem.engine = engine;
    pcie = new({label, "_pcie"});
    scheduler = new({label, "_scheduler"});
    profile = new({label, "_profile"});
    if (!(mode inside {4, 5})) begin
      prepared_binding = make_binding({label, "_prepared"}, RDMA_BIND_PREPARED);
      active_binding = make_binding({label, "_active"}, RDMA_BIND_ACTIVE);
      cmq = make_cmq({label, "_cmq"}, prepared_binding);
      if (mode == 0)
        prepare_defaults(label, engine, mem, prepared_binding, cmq,
                         scheduler, profile, runtime_desc);
      else begin
        prepare_active(label, engine, mem, pcie, scheduler, profile,
                       prepared_binding, active_binding, cmq, runtime_desc);
        command = make_command({label, "_command"}, active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A, 8'h31, 100ns);
        engine.submit_observed(command, submitted);
        if (submitted == null || submitted.ticket == null)
          `uvm_fatal(label, "real submit omitted ticket")
      end
    end
    engine.seed(mode, opaque);
    mem.fault = fault;
    before_mem = mem.calls.size();
    before_pcie = pcie.calls.size();
    code = RDMA_SC_OK;
    message = "";
    if (mode inside {5, 6, 7, 8, 9} || fault == 1)
      code = RDMA_SC_INVALID_STATE;
    if (mode inside {5, 6})
      message = "CMQ lifecycle mutation is blocked during reset backing release";
    else if (mode == 7)
      message = "CMQ engine state cannot be shut down";
    else if (mode inside {8, 9})
      message = "CMQ shutdown release authority is missing";
    else if (fault == 1)
      message = "CMQ shutdown release returned null status";
    else if (fault == 2) begin
      code = RDMA_SC_UNKNOWN_HW_ERROR;
      message = "shutdown injected release failure";
    end
    call_shutdown(engine, code, message, status);
    expected_release = mode < 4 ? 1 : 0;
    release_method = opaque ? "release_opaque" : "release";
    if (mem.calls.size() != before_mem + expected_release || pcie.calls.size() != before_pcie ||
        count_host_calls(mem, release_method) != expected_release ||
        !engine.fifo_counts(mode inside {5, 6, 7} ? 1 : 0) || !engine.journal_preserved())
      `uvm_error(label, "shutdown reordered FIFO cleanup or adapter effects")
    if (fault != 0) begin
      if (!engine.retained_authority(mem, opaque) ||
          mem.regions[0].mapping.state != RDMA_MAPPING_ACTIVE ||
          (fault == 2 && status != mem.failure))
        `uvm_error(label, "failed release lost original retry authority or status")
    end
    if (mode inside {8, 9} && engine.state() != RDMA_CMQ_ENGINE_POISONED)
      `uvm_error(label, "missing release authority did not poison engine")
    if (mode == 8 && !engine.missing_host_mem_poisoned())
      `uvm_error(label, "missing adapter lost mapping or retained live runtime")
    if (mode == 9 && engine.mapping_snapshot() != null)
      `uvm_error(label, "missing mapping fabricated release authority")
    if (code == RDMA_SC_OK)
      expect_unconfigured(label, engine);
    engine.restore(mode, mem);
    mem.fault = 0;
    call_shutdown(engine, RDMA_SC_OK, "", status);
    expect_unconfigured(label, engine);
    if (fault != 0 || mode inside {6, 7, 8, 9})
      expected_release++;
    if (count_host_calls(mem, release_method) != expected_release ||
        count_host_calls(mem, opaque ? "release" : "release_opaque") != 0)
      `uvm_error(label, "retry changed release mode or call count")
    before_mem = mem.calls.size();
    call_shutdown(engine, RDMA_SC_OK, "", status);
    if (mem.calls.size() != before_mem || !engine.fifo_counts(0) || !engine.journal_preserved() ||
        (!(mode inside {4, 5}) && mem.regions[0].mapping.state != RDMA_MAPPING_RELEASED))
      `uvm_error(label, "retry/idempotent shutdown did not release exactly once")
  endtask

  // 功能：运行 24 个释放组合和 6 个边界场景，并发布唯一完成标记。
  // 输入/输出及副作用：phase 管理 objection；不调用父 run_phase，每例完成后释放 backing。
  // 失败/边界：10us watchdog 捕获漏解锁；任一 UVM_ERROR/FATAL 都由 runner 判失败。
  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    fork
      begin
        for (int mode = 0; mode < 4; mode++)
          for (int opaque = 0; opaque < 2; opaque++)
            for (int fault = 0; fault < 3; fault++)
              run_case(mode, bit'(opaque), fault);
        for (int mode = 4; mode < 10; mode++)
          run_case(mode);
      end
      begin
        #10us;
        `uvm_fatal("SHUTDOWN_WATCHDOG", "shutdown matrix timed out")
      end
    join_any
    disable fork;
    `uvm_info("SHUTDOWN_MATRIX", "completed 30 CMQ shutdown scenarios", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass
