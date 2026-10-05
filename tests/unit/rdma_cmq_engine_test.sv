// 目录：单元测试 tests/unit/rdma_cmq_engine_test.sv。
// 职责：按 rdma-driver-0.1.34 cmq.c 的语义验证 rdma_cmq_engine：SQE/doorbell/CQE 环几何与 polarity、
//   回绕、满环时的 pending 链表、CQE wrap/opcode/ecode 错误、TB 看门狗、提交前拒绝与 reset/shutdown。
// 依赖：生产 rdma_hw_cmq_hw_profile、rdma_doorbell_scheduler、rdma_mock_host_mem 与共享的
//   rdma_cmq_device_responder（按驱动协议回写 CQE）。
// 设计说明：本类同时为 rdma_cmq_port_test 提供 binding/CMQ/命令构造与 status 断言辅助函数。

// 一套 engine 及其设备侧依赖。
class rdma_cmq_engine_fixture;
  rdma_mock_host_mem mem;
  rdma_cmq_device_responder device;
  rdma_doorbell_scheduler scheduler;
  rdma_hw_cmq_hw_profile profile;
  rdma_cmq_engine engine;
  rdma_function_binding prepared;
  rdma_function_binding active;
  rdma_cmq cmq;
endclass

class rdma_cmq_engine_test extends uvm_test;
  `uvm_component_utils(rdma_cmq_engine_test)

  localparam longint unsigned TEST_FUNCTION_UID = 64'h1020_3040_5060_7080;
  localparam int unsigned TEST_FUNCTION_ID = 32'h1020_3040;
  localparam int unsigned TEST_GENERATION = 32'd9;
  localparam int unsigned TEST_CMQ_ID = 32'h5566_7788;
  localparam int unsigned CMQ_DEPTH = 32;

  // 功能：构造测试组件。
  // 输入/输出及副作用：name/parent 透传给 uvm_test。
  // 失败/边界：无。
  function new(string name = "rdma_cmq_engine_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------- 共享辅助

  // 功能：断言 status 的 code 等于期望值。
  // 输入/输出及副作用：label 用于报告；只读 status。
  // 失败/边界：status 为 null 或 code 不符时报告 UVM_ERROR。
  function automatic void expect_status(string label, rdma_status status,
                                        rdma_status_code_e expected);
    if (status == null) begin
      `uvm_error(label, "operation returned a null status")
      return;
    end
    if (status.code != expected)
      `uvm_error(label, $sformatf("expected %s, got %s (%s)", expected.name(),
                                  status.code.name(), status.convert2string()))
  endfunction

  // 功能：构造测试用 Function binding（固定 uid/BDF/BAR/notify 窗口与队列能力）。
  // 输入/输出及副作用：返回新 binding，调用方独占。
  // 失败/边界：identity 配置失败时报告 UVM_ERROR。
  function automatic rdma_function_binding make_binding(string name,
                                                        rdma_binding_state_e binding_state);
    rdma_function_binding binding;
    rdma_interrupt_vector_binding vector;

    binding = rdma_function_binding::type_id::create(name);
    binding.function_uid = TEST_FUNCTION_UID;
    binding.global_function_id = TEST_FUNCTION_ID;
    binding.generation = TEST_GENERATION;
    binding.pcie.bdf = '{segment:16'h0001, bus:8'h42, device:5'h03, function_num:3'h1};
    if (!binding.configure_identity_from_legacy_mirrors(16'h0, 32'h1, RDMA_FUNCTION_PF).ok())
      `uvm_error("BINDING", "legacy binding identity configuration failed")
    binding.pcie.bar[0].base.value = 64'h0000_0000_8000_0000;
    binding.pcie.bar[0].size = 64'h0001_0000;
    binding.pcie.bar[0].enabled = 1'b1;
    binding.notify_bar_id = 0;
    binding.notify_base.value = 64'h0000_0000_8000_2000;
    binding.notify_size = 64'h2000;
    binding.state = binding_state;
    binding.owner_h = binding.make_handle();
    binding.queue_dma.requester_bdf = binding.pcie.bdf;
    binding.queue_dma.pasid_valid = 1'b1;
    binding.queue_dma.pasid = 20'h34567;
    binding.queue_dma.dma_domain_valid = 1'b1;
    binding.queue_dma.dma_domain_id = 32'h1122_3344;
    binding.queue_caps.min_cq_depth = 16;
    binding.queue_caps.max_cq_depth = 32768;
    binding.queue_caps.min_srq_depth = 16;
    binding.queue_caps.max_srq_depth = 32768;
    binding.queue_caps.max_ceq_depth = 4096;
    binding.queue_caps.max_aeq_depth = 4096;
    binding.queue_caps.max_wq_sge = 8;
    binding.queue_caps.max_queue_ring_bytes = 32'h0020_0000;
    binding.queue_caps.max_sgb_bytes = 32'h0040_0000;
    vector = '{default:'0};
    vector.function_local_vector = 3;
    vector.hardware_eq_vector = 17;
    vector.msix_table_index = 5;
    vector.enabled = 1'b1;
    binding.interrupt_vectors.push_back(vector);
    binding.pcie.mse = 1'b1;
    binding.pcie.bme = 1'b1;
    binding.notify_valid = 1'b1;
    binding.notify_ready = 1'b1;
    binding.dmi_valid = 1'b1;
    binding.dmi_ready = 1'b1;
    binding.vft_valid = 1'b1;
    binding.vft_ready = 1'b1;
    return binding;
  endfunction

  // 功能：构造属于 binding 的 32 深度 CMQ 资源描述。
  // 输入/输出及副作用：返回新 rdma_cmq，调用方独占。
  // 失败/边界：无。
  function automatic rdma_cmq make_cmq(string name, rdma_function_binding binding);
    rdma_cmq cmq;

    cmq = rdma_cmq::type_id::create(name);
    cmq.handle = rdma_handle::type_id::create({name, "_handle"});
    cmq.handle.kind = RDMA_RESOURCE_CMQ;
    cmq.handle.function_uid = binding.function_uid;
    cmq.handle.object_id = TEST_CMQ_ID;
    cmq.handle.generation = binding.generation;
    cmq.owner = binding.make_handle();
    cmq.state = RDMA_RESOURCE_ALLOCATED;
    cmq.depth = CMQ_DEPTH;
    return cmq;
  endfunction

  // 功能：构造 core SQE model body 的通用命令，供 mock port 测试使用。
  // 输入/输出及副作用：返回新命令；marker 写入 body 以区分实例。
  // 失败/边界：不校验；生产 profile 不能编码该 body。
  function automatic rdma_cmq_command_desc make_command(string name, rdma_function_binding binding,
                                                        bit [31:0] opcode, byte unsigned marker,
                                                        time timeout_value = 1us);
    rdma_cmq_command_desc command;
    rdma_cmq_sqe_model body;
    rdma_handle target_h;

    command = rdma_cmq_command_desc::type_id::create(name);
    command.function_h = binding.make_handle();
    command.opcode_key = rdma_cmq_opcode_key::type_id::create({name, "_key"});
    command.opcode_key.profile_name = "cmq_engine_test";
    command.opcode_key.opcode = opcode;
    command.opcode_key.variant = $sformatf("variant_%02h", opcode[7:0]);
    target_h = rdma_handle::type_id::create({name, "_target"});
    target_h.kind = RDMA_RESOURCE_CMQ;
    target_h.function_uid = binding.function_uid;
    target_h.object_id = TEST_CMQ_ID;
    target_h.generation = binding.generation;
    body = rdma_cmq_sqe_model::type_id::create({name, "_body"});
    body.opcode = RDMA_CMQ_QUERY;
    body.command_id = longint'(marker) + 1'b1;
    body.function_h = binding.make_handle();
    body.target_h = target_h;
    body.flags = marker;
    command.body = body;
    command.timeout = timeout_value;
    return command;
  endfunction

  // 功能：构造生产 profile 可编码的命令：TQ_FLUSH、OCC_FLUSH 或 MR_DEREGISTER。
  // 输入/输出及副作用：返回新命令，Function 句柄取自 binding。
  // 失败/边界：其它 opcode 按 TQ_FLUSH 空 body 构造。
  function automatic rdma_cmq_command_desc make_hw_command(string name,
                                                           rdma_function_binding binding,
                                                           bit [7:0] opcode,
                                                           time timeout_value = 1us);
    rdma_hw_occ_flush_body occ_body;
    rdma_hw_mr_deregister_body mr_body;
    rdma_hw_model body;
    string variant;

    if (opcode == RDMA_OP_OCC_FLUSH) begin
      occ_body = rdma_hw_occ_flush_body::type_id::create({name, "_body"});
      occ_body.mr_serial_flush = 1'b1;
      occ_body.pble = 1'b1;
      occ_body.mr_serial = 12'h123;
      body = occ_body;
      variant = "occ_flush";
    end
    else if (opcode == RDMA_OP_MR_DEREGISTER) begin
      mr_body = rdma_hw_mr_deregister_body::type_id::create({name, "_body"});
      mr_body.mr_h = rdma_handle::type_id::create({name, "_mr"});
      mr_body.mr_h.kind = RDMA_RESOURCE_MR;
      mr_body.mr_h.function_uid = binding.function_uid;
      mr_body.mr_h.object_id = 32'h42;
      mr_body.mr_h.generation = binding.generation;
      mr_body.stag_key = 8'h5a;
      mr_body.next_state = RDMA_CONTEXT_INVALID;
      body = mr_body;
      variant = "deregister";
    end
    else begin
      body = rdma_hw_cmq_empty_body::type_id::create({name, "_body"});
      variant = "tq_flush";
    end
    return rdma_make_cmq_command(binding.make_handle(), opcode, variant, body, timeout_value,
                                 name);
  endfunction

  // 功能：构造未 prepare 的 engine 与设备侧依赖。
  // 输入/输出及副作用：fx 输出新 fixture；scheduler 绑定 mem 与 responder。
  // 失败/边界：scheduler 配置失败时报告 UVM_ERROR。
  function automatic void build_fixture(string label, output rdma_cmq_engine_fixture fx);
    fx = new();
    fx.mem = rdma_mock_host_mem::type_id::create({label, "_mem"});
    fx.device = rdma_cmq_device_responder::type_id::create({label, "_device"});
    fx.scheduler = rdma_doorbell_scheduler::type_id::create({label, "_scheduler"});
    fx.profile = rdma_hw_cmq_hw_profile::type_id::create({label, "_profile"});
    fx.engine = rdma_cmq_engine::type_id::create({label, "_engine"});
    fx.prepared = make_binding({label, "_prepared"}, RDMA_BIND_PREPARED);
    fx.active = make_binding({label, "_active"}, RDMA_BIND_ACTIVE);
    fx.cmq = make_cmq({label, "_cmq"}, fx.prepared);
    expect_status({label, "_SCHEDULER"}, fx.scheduler.configure(fx.mem, fx.device), RDMA_SC_OK);
  endfunction

  // 功能：PREPARED→ACTIVE，并让 responder 接管 engine 的 backing。
  // 输入/输出及副作用：修改 fx.engine 状态与 responder 配置。
  // 失败/边界：任一步骤失败时报告 UVM_ERROR。
  task automatic start_fixture(string label, rdma_cmq_engine_fixture fx);
    rdma_cmq_runtime_desc runtime_desc;
    rdma_status status;

    fx.engine.prepare(fx.prepared, fx.cmq, 1'b1, 20'h34567, fx.mem, fx.scheduler, fx.profile,
                      runtime_desc, status);
    expect_status({label, "_PREPARE"}, status, RDMA_SC_OK);
    if (runtime_desc == null)
      `uvm_error({label, "_PREPARE"}, "prepare returned no runtime descriptor")
    fx.engine.activate(fx.active, status);
    expect_status({label, "_ACTIVATE"}, status, RDMA_SC_OK);
    expect_status({label, "_RESPONDER"},
                  fx.device.configure_responder(fx.mem, fx.engine.mapping_snapshot(), fx.active),
                  RDMA_SC_OK);
  endtask

  // 功能：提交一条生产命令并断言其终态 status。
  // 输入/输出及副作用：result 输出 engine 的 execution result。
  // 失败/边界：result 为空或 status 不符时报告 UVM_ERROR。
  task automatic run_command(string label, rdma_cmq_engine_fixture fx, bit [7:0] opcode,
                             rdma_status_code_e expected,
                             output rdma_cmq_execution_result result,
                             input time timeout_value = 1us);
    fx.engine.execute_observed(make_hw_command(label, fx.active, opcode, timeout_value), result);
    if (result == null) begin
      `uvm_error(label, "engine returned no execution result")
      return;
    end
    expect_status(label, result.status, expected);
  endtask

  // 功能：断言 result 是带 raw CQE 的 TERMINAL 完成。
  // 输入/输出及副作用：只读 result。
  // 失败/边界：任一证据缺失时报告 UVM_ERROR。
  function automatic void expect_terminal(string label, rdma_cmq_execution_result result);
    if (result == null || result.ticket == null || result.completion == null ||
        result.completion.raw_cqe == null || result.completion.ticket != result.ticket ||
        result.completion.status != result.status ||
        result.completion_phase != RDMA_CMQ_COMPLETION_TERMINAL ||
        result.submission_effect != RDMA_SUBMIT_EFFECT_MMIO_VISIBLE ||
        result.recovery_required)
      `uvm_error(label, "result is not a terminal CQE-backed completion")
  endfunction

  // 功能：断言 result 为提交前拒绝且 status 为期望值。
  // 输入/输出及副作用：只读 result。
  // 失败/边界：effect/phase/ticket 不符时报告 UVM_ERROR。
  function automatic void expect_pre_rejected(string label, rdma_cmq_execution_result result,
                                              rdma_status_code_e expected);
    if (result == null) begin
      `uvm_error(label, "engine returned no execution result")
      return;
    end
    expect_status(label, result.status, expected);
    if (result.submission_effect != RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED ||
        result.completion_phase != RDMA_CMQ_COMPLETION_NONE || result.ticket != null ||
        result.recovery_required)
      `uvm_error(label, "rejection was not reported as PRE_SUBMIT_REJECTED")
  endfunction

  // 功能：shutdown engine 并确认 QUIESCED 且 backing 已释放。
  // 输入/输出及副作用：修改 fx.engine 状态。
  // 失败/边界：shutdown 失败或仍有分配时报告 UVM_ERROR。
  task automatic stop_fixture(string label, rdma_cmq_engine_fixture fx);
    rdma_status status;

    fx.engine.shutdown(status);
    expect_status({label, "_SHUTDOWN"}, status, RDMA_SC_OK);
    if (fx.engine.state() != RDMA_CMQ_ENGINE_QUIESCED || fx.mem.live_allocations() != 0)
      `uvm_error({label, "_SHUTDOWN"}, "shutdown did not quiesce and release the backing")
  endtask

  // ---------------------------------------------------------------- 场景

  // 功能：三种生产 opcode 依次提交：SQE 索引/wrap、doorbell PI/polarity、CQ owner 与驱动初值一致。
  // 输入/输出及副作用：无参数；独占一套 fixture。
  // 失败/边界：envelope、计数或 status 不符时报告 UVM_ERROR。
  task automatic check_basic_opcodes();
    rdma_cmq_engine_fixture fx;
    rdma_cmq_execution_result result;
    bit [7:0] opcodes[3];

    opcodes = '{RDMA_OP_TQ_FLUSH, RDMA_OP_OCC_FLUSH, RDMA_OP_MR_DEREGISTER};
    build_fixture("basic", fx);
    start_fixture("BASIC", fx);
    foreach (opcodes[i]) begin
      run_command($sformatf("BASIC_%0d", i), fx, opcodes[i], RDMA_SC_OK, result);
      expect_terminal($sformatf("BASIC_%0d", i), result);
      if (result != null && result.ticket != null &&
          (result.ticket.sq_index != i || result.ticket.sq_wrap != 1'b0))
        `uvm_error("BASIC_TICKET", $sformatf("command %0d ticket slot is wrong", i))
    end
    if (fx.device.observed_opcodes.size() != 3) begin
      `uvm_error("BASIC_DEVICE", "device did not observe three commands")
    end
    else begin
      foreach (opcodes[i])
        if (fx.device.observed_opcodes[i] != opcodes[i] ||
            fx.device.observed_wqe_indices[i] != i || fx.device.observed_wqe_wraps[i] != 1'b0 ||
            fx.device.observed_doorbell_pis[i] != i + 1 ||
            fx.device.observed_doorbell_polarities[i] != 1'b0 ||
            fx.device.observed_cq_owners[i] != 1'b1)
          `uvm_error("BASIC_DEVICE", $sformatf("command %0d envelope is wrong", i))
    end
    if (fx.engine.published_count() != 3 || fx.engine.cq_consumed_count() != 3 ||
        fx.engine.retired_count() != 3 || fx.engine.outstanding_count() != 0)
      `uvm_error("BASIC_COUNTS", "engine counters do not match three completed commands")
    stop_fixture("BASIC", fx);
  endtask

  // 功能：70 条命令跨过两次回绕：SQE wrap、doorbell polarity 与 CQ owner 每 32 条翻转一次。
  // 输入/输出及副作用：无参数；独占一套 fixture。
  // 失败/边界：任一命令几何不符时报告 UVM_ERROR。
  task automatic check_ring_wrap();
    int unsigned commands;
    rdma_cmq_engine_fixture fx;
    rdma_cmq_execution_result result;

    commands = 70;
    build_fixture("wrap", fx);
    start_fixture("WRAP", fx);
    for (int unsigned i = 0; i < commands; i++) begin
      run_command($sformatf("WRAP_%0d", i), fx, RDMA_OP_TQ_FLUSH, RDMA_SC_OK, result);
      expect_terminal($sformatf("WRAP_%0d", i), result);
    end
    if (fx.device.observed_wqe_indices.size() != commands ||
        fx.device.observed_cq_owners.size() != commands) begin
      `uvm_error("WRAP_DEVICE", "device did not observe every command")
    end
    else begin
      for (int unsigned i = 0; i < commands; i++)
        if (fx.device.observed_wqe_indices[i] != i % CMQ_DEPTH ||
            fx.device.observed_wqe_wraps[i] != (i / CMQ_DEPTH) % 2 ||
            fx.device.observed_doorbell_pis[i] != (i + 1) % CMQ_DEPTH ||
            fx.device.observed_doorbell_polarities[i] != ((i + 1) / CMQ_DEPTH) % 2 ||
            fx.device.observed_cq_owners[i] != !((i / CMQ_DEPTH) % 2))
          `uvm_error("WRAP_DEVICE", $sformatf("command %0d ring geometry is wrong", i))
    end
    stop_fixture("WRAP", fx);
  endtask

  // 功能：设备扣留完成时并发 34 条命令：32 条占满 SQ，2 条进入 pending；释放后按序补发并全部成功。
  // 输入/输出及副作用：无参数；并发 fork 34 个 execute 并等待全部返回。
  // 失败/边界：pending 未形成、补发缺失或任一命令失败时报告 UVM_ERROR。
  task automatic check_ring_full_pending();
    int unsigned commands;
    rdma_cmq_engine_fixture fx;
    rdma_cmq_execution_result results[];
    bit settled;

    commands = CMQ_DEPTH + 2;
    results = new[commands];
    build_fixture("full", fx);
    start_fixture("FULL", fx);
    fx.device.hold = 1'b1;
    for (int unsigned i = 0; i < commands; i++) begin
      fork
        automatic int unsigned index = i;
        fx.engine.execute_observed(
          make_hw_command($sformatf("FULL_%0d", index), fx.active, RDMA_OP_TQ_FLUSH, 10us),
          results[index]);
      join_none
    end
    settled = 1'b0;
    for (int unsigned t = 0; t < 100 && !settled; t++) begin
      #10ns;
      settled = fx.engine.outstanding_count() == commands;
    end
    if (!settled || fx.engine.published_count() != CMQ_DEPTH ||
        fx.device.held_count() != CMQ_DEPTH)
      `uvm_error("FULL_PENDING", $sformatf(
                 "expected 32 published + 2 pending, got published=%0d outstanding=%0d held=%0d",
                 fx.engine.published_count(), fx.engine.outstanding_count(),
                 fx.device.held_count()))
    expect_status("FULL_RELEASE", fx.device.release_held(), RDMA_SC_OK);
    wait fork;
    foreach (results[i]) begin
      if (results[i] == null) begin
        `uvm_error("FULL_RESULT", $sformatf("command %0d returned no result", i))
        continue;
      end
      expect_status($sformatf("FULL_RESULT_%0d", i), results[i].status, RDMA_SC_OK);
      expect_terminal($sformatf("FULL_RESULT_%0d", i), results[i]);
    end
    if (fx.engine.published_count() != commands || fx.engine.outstanding_count() != 0 ||
        fx.device.observed_wqe_indices.size() != commands ||
        fx.device.observed_wqe_indices[CMQ_DEPTH] != 0 ||
        fx.device.observed_wqe_wraps[CMQ_DEPTH] != 1'b1)
      `uvm_error("FULL_DRAIN", "pending commands were not submitted after the ring drained")
    stop_fixture("FULL", fx);
  endtask

  // 功能：驱动 get_cqe_common_info 的三种错误：ecode 非 0、opcode 不符、wrap 不符；engine 保持 ACTIVE。
  // 输入/输出及副作用：无参数；按次注入 responder 故障。
  // 失败/边界：错误未被报告或 engine 停止时报告 UVM_ERROR。
  task automatic check_cqe_errors();
    rdma_cmq_engine_fixture fx;
    rdma_cmq_execution_result result;

    build_fixture("cqe_error", fx);
    start_fixture("CQE_ERROR", fx);

    fx.device.next_ecode = 8'h05;
    fx.engine.execute_observed(make_hw_command("CQE_ECODE", fx.active, RDMA_OP_TQ_FLUSH),
                               result);
    if (result == null || result.status == null || result.status.ok())
      `uvm_error("CQE_ECODE", "non-zero CQE ecode completed successfully")
    expect_terminal("CQE_ECODE", result);

    fx.device.override_next_opcode = 1'b1;
    fx.device.next_opcode = RDMA_OP_OCC_FLUSH;
    run_command("CQE_OPCODE", fx, RDMA_OP_TQ_FLUSH, RDMA_SC_INVALID_STATE, result);
    expect_terminal("CQE_OPCODE", result);

    fx.device.flip_next_wrap = 1'b1;
    run_command("CQE_WRAP", fx, RDMA_OP_TQ_FLUSH, RDMA_SC_INVALID_STATE, result);
    expect_terminal("CQE_WRAP", result);

    if (fx.engine.state() != RDMA_CMQ_ENGINE_ACTIVE)
      `uvm_error("CQE_ERROR_STATE", "a failed CQE must not stop the CMQ")
    run_command("CQE_AFTER", fx, RDMA_OP_TQ_FLUSH, RDMA_SC_OK, result);
    expect_terminal("CQE_AFTER", result);
    stop_fixture("CQE_ERROR", fx);
  endtask

  // 功能：设备丢弃完成：看门狗到期返回 TIMEOUT 并使 engine POISONED；之后的命令被拒绝；
  //   reset 回到 UNCONFIGURED 并释放 backing，重新 prepare/activate 后恢复工作。
  // 输入/输出及副作用：无参数；reset 后重新 prepare/activate。
  // 失败/边界：状态迁移或恢复后提交不符时报告 UVM_ERROR。
  task automatic check_watchdog_and_reset();
    rdma_cmq_engine_fixture fx;
    rdma_cmq_execution_result result;
    rdma_cmq_completion completions[$];
    rdma_status status;

    build_fixture("watchdog", fx);
    start_fixture("WATCHDOG", fx);
    fx.device.drop_next = 1'b1;
    run_command("WATCHDOG_TIMEOUT", fx, RDMA_OP_TQ_FLUSH, RDMA_SC_TIMEOUT, result, 200ns);
    if (result == null || result.completion_phase != RDMA_CMQ_COMPLETION_TIMEOUT ||
        result.ticket == null || result.completion == null || result.completion.raw_cqe != null ||
        result.recovery_required)
      `uvm_error("WATCHDOG_TIMEOUT", "watchdog result is not a TIMEOUT completion")
    if (fx.engine.state() != RDMA_CMQ_ENGINE_POISONED)
      `uvm_error("WATCHDOG_STATE", "watchdog timeout did not poison the engine")
    run_command("WATCHDOG_AFTER", fx, RDMA_OP_TQ_FLUSH, RDMA_SC_INVALID_STATE, result);
    expect_pre_rejected("WATCHDOG_AFTER", result, RDMA_SC_INVALID_STATE);

    fx.engine.reset(completions, status);
    expect_status("WATCHDOG_RESET", status, RDMA_SC_OK);
    if (fx.engine.state() != RDMA_CMQ_ENGINE_UNCONFIGURED || fx.mem.live_allocations() != 0 ||
        fx.engine.outstanding_count() != 0)
      `uvm_error("WATCHDOG_RESET", "reset did not return to UNCONFIGURED and release the backing")
    start_fixture("WATCHDOG_REPREPARE", fx);
    run_command("WATCHDOG_RECOVERED", fx, RDMA_OP_TQ_FLUSH, RDMA_SC_OK, result);
    expect_terminal("WATCHDOG_RECOVERED", result);
    if (result != null && result.ticket != null && result.ticket.sq_index != 0)
      `uvm_error("WATCHDOG_RECOVERED", "re-prepared engine did not restart at PI 0")
    stop_fixture("WATCHDOG", fx);
  endtask

  // 功能：提交前拒绝：未 ACTIVE、空命令、Function 不符；均不写 SQ、不打 doorbell。
  // 输入/输出及副作用：无参数；独占一套 fixture。
  // 失败/边界：拒绝未被报告为 PRE_SUBMIT_REJECTED 或命令触达 SQ 时报告 UVM_ERROR。
  task automatic check_pre_submit_rejection();
    rdma_cmq_engine_fixture fx;
    rdma_cmq_execution_result result;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_function_binding other;
    rdma_status status;

    build_fixture("reject", fx);
    fx.engine.execute_observed(make_hw_command("REJECT_UNCONFIGURED", fx.active,
                                               RDMA_OP_TQ_FLUSH), result);
    expect_pre_rejected("REJECT_UNCONFIGURED", result, RDMA_SC_INVALID_STATE);
    fx.engine.prepare(fx.prepared, fx.cmq, 1'b1, 20'h34567, fx.mem, fx.scheduler, fx.profile,
                      runtime_desc, status);
    expect_status("REJECT_PREPARE", status, RDMA_SC_OK);
    fx.engine.execute_observed(make_hw_command("REJECT_PREPARED", fx.active,
                                               RDMA_OP_TQ_FLUSH), result);
    expect_pre_rejected("REJECT_PREPARED", result, RDMA_SC_INVALID_STATE);
    fx.engine.activate(fx.active, status);
    expect_status("REJECT_ACTIVATE", status, RDMA_SC_OK);
    expect_status("REJECT_RESPONDER",
                  fx.device.configure_responder(fx.mem, fx.engine.mapping_snapshot(), fx.active),
                  RDMA_SC_OK);

    fx.engine.execute_observed(null, result);
    expect_pre_rejected("REJECT_NULL", result, RDMA_SC_INVALID_ARGUMENT);
    other = make_binding("reject_other", RDMA_BIND_ACTIVE);
    other.generation++;
    other.owner_h = other.make_handle();
    fx.engine.execute_observed(make_hw_command("REJECT_FUNCTION", other, RDMA_OP_TQ_FLUSH),
                               result);
    expect_pre_rejected("REJECT_FUNCTION", result, RDMA_SC_INVALID_ARGUMENT);
    if (fx.engine.published_count() != 0 || fx.device.observed_opcodes.size() != 0)
      `uvm_error("REJECT_EFFECTS", "a rejected command reached the SQ")
    stop_fixture("REJECT", fx);
    fx.engine.execute_observed(make_hw_command("REJECT_QUIESCED", fx.active,
                                               RDMA_OP_TQ_FLUSH), result);
    expect_pre_rejected("REJECT_QUIESCED", result, RDMA_SC_INVALID_STATE);
  endtask

  // 功能：doorbell 写失败：PI 已推进，engine 进入 POISONED；看门狗使环内请求超时后，
  //   pending 请求立即以 INVALID_STATE 结束，不等待自己的截止时间。
  // 输入/输出及副作用：无参数；注入一次 mmio_write 失败并 fork 33 条命令。
  // 失败/边界：未 POISONED、pending 等待自身看门狗或状态不符时报告 UVM_ERROR。
  task automatic check_poison_paths();
    rdma_cmq_engine_fixture fx;
    rdma_cmq_execution_result result;
    rdma_cmq_execution_result results[];
    rdma_status status;
    rdma_cmq_completion completions[$];
    time started;

    build_fixture("poison", fx);
    start_fixture("POISON", fx);
    status = rdma_status::make(RDMA_SC_PCIE_COMPLETION, "injected doorbell failure");
    expect_status("POISON_INJECT", fx.device.fail_next("mmio_write", status), RDMA_SC_OK);
    fx.engine.execute_observed(make_hw_command("POISON_DOORBELL", fx.active, RDMA_OP_TQ_FLUSH),
                               result);
    if (result == null || result.status == null || result.status.ok() ||
        result.submission_effect == RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED)
      `uvm_error("POISON_DOORBELL", "doorbell failure was not reported as a submitted failure")
    if (fx.engine.state() != RDMA_CMQ_ENGINE_POISONED)
      `uvm_error("POISON_DOORBELL", "doorbell failure did not poison the engine")
    fx.engine.reset(completions, status);
    expect_status("POISON_RESET", status, RDMA_SC_OK);
    start_fixture("POISON_RESTART", fx);

    results = new[CMQ_DEPTH + 1];
    fx.device.hold = 1'b1;
    started = $time;
    for (int unsigned i = 0; i <= CMQ_DEPTH; i++) begin
      fork
        automatic int unsigned index = i;
        fx.engine.execute_observed(
          make_hw_command($sformatf("POISON_%0d", index), fx.active, RDMA_OP_TQ_FLUSH,
                          index == CMQ_DEPTH ? 10us : 200ns),
          results[index]);
      join_none
    end
    wait fork;
    if ($time - started >= 10us)
      `uvm_error("POISON_PENDING", "pending request waited for its own watchdog")
    foreach (results[i]) begin
      if (results[i] == null) begin
        `uvm_error("POISON_PENDING", $sformatf("command %0d returned no result", i))
        continue;
      end
      if (i < CMQ_DEPTH)
        expect_status($sformatf("POISON_RING_%0d", i), results[i].status, RDMA_SC_TIMEOUT);
      else
        expect_pre_rejected("POISON_PENDING", results[i], RDMA_SC_INVALID_STATE);
    end
    stop_fixture("POISON", fx);
  endtask

  // 功能：reconcile_ticket 恒报告无终态：驱动语义下没有歧义 ticket。
  // 输入/输出及副作用：无参数；使用未配置 engine。
  // 失败/边界：报告终态时报告 UVM_ERROR。
  task automatic check_reconcile_has_no_terminal();
    rdma_cmq_engine engine;
    rdma_cmq_completion completion;
    rdma_status status;
    bit terminal_known;

    engine = rdma_cmq_engine::type_id::create("reconcile_engine");
    engine.reconcile_ticket(null, terminal_known, completion, status);
    expect_status("RECONCILE", status, RDMA_SC_INVALID_STATE);
    if (terminal_known || completion != null)
      `uvm_error("RECONCILE", "engine reported a reconciled terminal completion")
  endtask

  // 功能：依次运行全部 engine 场景。
  // 输入/输出及副作用：持有一次 objection。
  // 失败/边界：子检查以 UVM_ERROR 报告失败。
  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    check_basic_opcodes();
    check_ring_wrap();
    check_ring_full_pending();
    check_cqe_errors();
    check_watchdog_and_reset();
    check_poison_paths();
    check_pre_submit_rejection();
    check_reconcile_has_no_terminal();
    phase.drop_objection(this);
  endtask
endclass
