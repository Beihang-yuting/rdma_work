// 目录/层次：tests/unit；职责：固定公开 recover_queue 的 unclaimed 移交/中止边界。
// 依赖：runtime 单测的 identity/route 与断言、真实 runtime reservation/admission、UVM factory。
// 所有权/生命周期：每例拥有独立 engine/runtime；只注入 engine 索引和防御坏状态，
//   不构造外部 backing，不把合成索引视为真实 publish 流程；完整发布由既有回归覆盖。

// 只开放同步占锁和 token 计数，不覆盖生产的 query/cancel/abort/recover 方法。
class rdma_handoff_runtime_probe extends rdma_queue_runtime;
  // 功能：创建未配置 runtime，沿用基类唯一锁与 DETACHED 初态。
  // 输入/输出及副作用：name 传给基类；不建立外部资源或预置恢复证据。
  // 失败/边界：必须经 configure/activate/reserve 后才用于 handoff 测试。
  function new(string name = "handoff_runtime");
    super.new(name);
  endfunction

  // 功能：同步占用或归还一个 runtime token，模拟查询窗口锁忙。
  // 输入/输出及副作用：hold=1 取锁，hold=0 归还；不改变账本。
  // 失败/边界：重复占锁 fatal；测试仅在已持有一个 token 时归还。
  function void set_busy(bit hold);
    if (hold) begin
      if (!lock.try_get(1))
        `uvm_fatal("HANDOFF", "fixture lock already held")
    end
    else
      lock.put(1);
  endfunction

  // 功能：注入 CQ 被错误标记为 host-produced 的防御坏状态，检查 reservation 查询拒绝。
  // 输入/输出及副作用：无输入；只设置本 fixture 的 protected 方向位，不改生产可见性。
  // 失败/边界：只在真实 device reservation 已建立后使用；不是合法配置入口。
  function void corrupt_direction();
    host_produced = 1'b1;
  endfunction

  // 功能：观察可用 runtime token 数，约束所有退出路径不丢锁或多归还。
  // 输入/输出及副作用：无输入；最多获取两个 token 后原数归还。
  // 失败/边界：只在同步测试调用后检查；返回 2 即违反单 token 契约。
  function int tokens();
    int count = 0;
    repeat (2) if (lock.try_get(1)) count++;
    if (count != 0)
      lock.put(count);
    return count;
  endfunction
endclass

// 将坏 pair/attachment 注入限制在 test-only 索引；被测入口及 detach 提交都使用生产实现。
class rdma_handoff_engine_probe extends rdma_queue_data_engine;
  rdma_handoff_runtime_probe observed_runtime;
  rdma_queue_data_attachment observed_attachment;
  rdma_queue_pending_operation observed_pending;
  int unsigned admission_mode;
  int unsigned admission_calls;
  bit pair_visible_at_admission;
  string fixture_key;

  // 功能：创建未配置 engine，默认注入一次性查询可观察的 admission 错误。
  // 输入/输出及副作用：name 传基类；计数清零，观察引用为空，由测试负责寿命。
  // 失败/边界：构造不安装 factory，不开放新的生产恢复入口。
  function new(string name = "handoff_engine");
    super.new(name);
    admission_mode = 1;
    admission_calls = 0;
    pair_visible_at_admission = 0;
  endfunction

  // 功能：安装一个合成 CQ attachment 与 unclaimed pair，按 fault 注入缺失/换代/锁忙。
  // 输入/输出及副作用：handle/runtime/pending 输入均由测试拥有；索引只借用它们，
  //   fault=1..6 破坏 pair/authority，7 无 pair，8..15 破坏 abort 前提或 detach 条件。
  // 失败/边界：不是合法 publish/admission 生成器；pending/runtime 必须先建立真实 reservation。
  function void stage(rdma_handle handle, rdma_handoff_runtime_probe runtime,
                      rdma_queue_pending_operation pending, int unsigned fault);
    rdma_status status;

    configured = 1'b1;
    binding = new("handoff_binding");
    binding.function_uid = handle.function_uid;
    binding.generation = handle.generation;
    observed_runtime = runtime;
    observed_pending = pending;
    observed_attachment = new("handoff_attachment");
    observed_attachment.queue_h = new("attachment_handle");
    observed_attachment.queue_h.copy(handle);
    observed_attachment.runtime = runtime;
    observed_attachment.kind = RDMA_QUEUE_RUNTIME_CQ;
    observed_attachment.entry_size = pending.entry_size;
    fixture_key = value_ops::identity_key(handle);
    attachments["handoff"] = observed_attachment;
    unclaimed_device_recoveries[fixture_key] = pending;
    unclaimed_recovery_attachments[fixture_key] = observed_attachment;
    case (fault)
      1: unclaimed_device_recoveries.delete(fixture_key);
      2: unclaimed_recovery_attachments.delete(fixture_key);
      3: unclaimed_device_recoveries[fixture_key] = null;
      4: unclaimed_recovery_attachments[fixture_key] = null;
      5: observed_attachment.runtime = null;
      6: observed_attachment.queue_h.generation++;
      7: begin
        unclaimed_device_recoveries.delete(fixture_key);
        unclaimed_recovery_attachments.delete(fixture_key);
      end
      8: pending.cursor = null;
      9: pending.cursor.index++;
      10: runtime.state = RDMA_QUEUE_RUNTIME_QUIESCING;
      11: begin
        status = runtime.cancel_device_producer(pending.cursor);
        if (status == null || !status.ok())
          `uvm_fatal("HANDOFF", "fixture cancellation failed")
      end
      12: runtime.set_busy(1'b1);
      13: begin
        if (!resize_lock.try_get(1))
          `uvm_fatal("HANDOFF", "fixture resize lock already held")
      end
      14: attachments.delete("handoff");
      15: runtime.corrupt_direction();
      default: begin end
    endcase
  endfunction

  // 功能：记录 admission 时 pair 仍完整；mode=0 用真实接管，1/2 返回错误/null，
  //   mode=3 在真实接管后占锁，使公开 retry 在 query_pending 阶段停止而不触碰 I/O。
  // 输入/输出及副作用：attachment/pending 为被测入口传入的借用；累计调用次数。
  // 失败/边界：不覆盖 recover_queue 或新 helper；真实 admission 失败原样返回。
  protected virtual function rdma_status admit_device_publish_recovery(
    rdma_queue_data_attachment attachment, rdma_queue_pending_operation prepared_pending
  );
    rdma_status status;

    admission_calls++;
    pair_visible_at_admission = pair_bits() == 4'b1111 &&
      attachment == observed_attachment && prepared_pending == observed_pending;
    if (admission_mode == 1)
      return rdma_status::make_direct(RDMA_SC_RESOURCE_BUSY, "injected admission failure");
    if (admission_mode == 2)
      return null;
    status = super.admit_device_publish_recovery(attachment, prepared_pending);
    if (admission_mode == 3 && status != null && status.ok())
      observed_runtime.set_busy(1'b1);
    return status;
  endfunction

  // 功能：观察两张 unclaimed 表的存在位与原对象身份，防止失败后半删或换对象。
  // 输入/输出及副作用：无输入；返回 pending存在/attachment存在/原pending/原attachment 四位。
  // 失败/边界：缺键不读取 associative array；null 条目仍保留其存在位。
  function bit [3:0] pair_bits();
    bit p = unclaimed_device_recoveries.exists(fixture_key);
    bit a = unclaimed_recovery_attachments.exists(fixture_key);
    bit same_pending = 0;
    bit same_attachment = 0;

    if (p)
      same_pending = unclaimed_device_recoveries[fixture_key] == observed_pending;
    if (a)
      same_attachment = unclaimed_recovery_attachments[fixture_key] == observed_attachment;
    return {p, a, same_pending, same_attachment};
  endfunction

  // 功能：观察主 attachment 是否仍是本例原对象，约束 abort 的删除与失败保留。
  // 输入/输出及副作用：无输入；只读索引，不触发查询或 factory。
  // 失败/边界：missing-registry fixture 初始即返回 0，不把它当成 abort 已发生。
  function bit attached();
    return attachments.exists("handoff") && attachments["handoff"] == observed_attachment;
  endfunction

  // 功能：归还 stage 故意占用的 resize token，结束失败保留场景。
  // 输入/输出及副作用：无输入；仅 put 一个 token，不改变索引或 runtime。
  // 失败/边界：只能在 fault=13 的被测调用结束后调用一次。
  function void release_resize();
    resize_lock.put(1);
  endfunction
endclass

// 只在 reservation 查询的 raw factory 边界注入故障，不改变 status factory 的默认行为。
class rdma_handoff_cursor_factory extends uvm_default_factory;
  bit wrong_type;
  int unsigned calls;

  // 功能：建立指定 null/错型模式的 cursor factory，初始未安装。
  // 输入/输出及副作用：wrong 决定故障类型；calls 清零。
  // 失败/边界：只匹配 device_reservation_query；其它请求交原 default factory。
  function new(bit wrong);
    super.new();
    wrong_type = wrong;
    calls = 0;
  endfunction

  // 功能：在 abort 的 reservation 快照创建处返回 null 或不兼容对象。
  // 输入/输出及副作用：type/path/name 输入；命中时累计 calls，普通请求透传。
  // 失败/边界：不抑制 fatal，生产 raw factory 必须将错型转换为 RESOURCE_EXHAUSTED。
  virtual function uvm_object create_object_by_type(
    uvm_object_wrapper requested_type, string parent_inst_path = "", string name = ""
  );
    rdma_queue_runtime_wrong_factory_object wrong;

    if (name != "device_reservation_query")
      return super.create_object_by_type(requested_type, parent_inst_path, name);
    calls++;
    if (!wrong_type)
      return null;
    wrong = new();
    return wrong;
  endfunction
endclass

// 复用 runtime 测试的身份/route 与断言，不调用父 run_phase 或新生产 helper。
class rdma_unclaimed_recovery_handoff_test extends rdma_queue_runtime_test;
  `uvm_component_utils(rdma_unclaimed_recovery_handoff_test)
  int unsigned cases;

  // 功能：建立独立恢复移交测试，初始化公开 recover_queue 调用计数。
  // 输入/输出及副作用：name/parent 透传；不安装全局 type override。
  // 失败/边界：父测试场景不自动执行，fixture 均在本类显式创建。
  function new(string name = "rdma_unclaimed_recovery_handoff_test", uvm_component parent = null);
    super.new(name, parent);
    cases = 0;
  endfunction

  // 功能：通过真实 configure/route/activate/reserve 构造一条 device pending，再注入 engine 表。
  // 输入/输出及副作用：fault/mode 选择故障；engine/handle 输出由本测试持有，image 为 16 bytes。
  // 失败/边界：任何基础 runtime 步骤失败即 fatal，不让不完整 fixture 进入断言矩阵。
  function void setup(int unsigned fault, int unsigned mode,
                      output rdma_handoff_engine_probe engine, output rdma_handle handle);
    rdma_handoff_runtime_probe runtime;
    rdma_queue_pending_operation pending;
    rdma_queue_cursor_snapshot cursor;
    rdma_route_key_t route;
    rdma_status status;

    handle = queue_handle("handoff_queue", RDMA_RESOURCE_CQ, 246);
    runtime = new();
    route = fixture_route(8'd46);
    status = runtime.configure(handle, RDMA_QUEUE_RUNTIME_CQ, 4, 0, 0, 0, 0, 0);
    if (status == null || !status.ok())
      `uvm_fatal("HANDOFF", "runtime configuration failed")
    status = runtime.set_route_epoch(route, 246);
    if (status == null || !status.ok())
      `uvm_fatal("HANDOFF", "runtime route setup failed")
    status = runtime.activate();
    if (status == null || !status.ok())
      `uvm_fatal("HANDOFF", "runtime activation failed")
    status = runtime.reserve_device_producer(cursor);
    if (status == null || !status.ok() || cursor == null)
      `uvm_fatal("HANDOFF", "reservation setup failed")
    pending = new("handoff_pending");
    pending.queue_h = handle;
    pending.kind = RDMA_QUEUE_RUNTIME_CQ;
    pending.device_producer = 1'b1;
    pending.cursor = cursor;
    pending.next_cursor = new("next_cursor");
    pending.next_cursor.index = 1;
    pending.entry_size = 16;
    pending.image = new("handoff_image");
    pending.image.length = 16;
    repeat (16) pending.image.bytes.push_back(8'h46);
    pending.failure_status = rdma_status::make_direct(RDMA_SC_DMA_TRANSLATION, "write failed");
    pending.mmio_evidence = RDMA_QUEUE_MMIO_NO_SUBMIT;
    pending.route = route;
    pending.route_valid = 1'b1;
    pending.reset_epoch = 246;
    pending.epoch_valid = 1'b1;
    engine = new();
    engine.admission_mode = mode;
    engine.stage(handle, runtime, pending, fault);
  endfunction

  // 功能：96 组公开调用固定 control gate、pair/authority、reservation 与 detach 的首错。
  // 输入/输出及副作用：无输入；16 fault × 2 admission 故障 × abort/确认retry/未确认retry。
  // 失败/边界：失败必须保留原 pair/attachment/游标，成功 abort 必须清空索引且不推进 PI/CI。
  task check_matrix();
    rdma_handoff_engine_probe engine;
    rdma_handle handle;
    rdma_status status;
    rdma_status_code_e expected_code;
    string expected_message;
    bit [3:0] before_pair;
    bit before_attached, aborted;
    int unsigned expected_calls;

    for (int unsigned fault = 0; fault < 16; fault++) begin
      for (int unsigned mode = 1; mode <= 2; mode++) begin
        for (int unsigned action = 0; action < 3; action++) begin
          setup(fault, mode, engine, handle);
          before_pair = engine.pair_bits();
          before_attached = engine.attached();
          expected_calls = action != 2 && !(fault inside {[1:7]}) ? 1 : 0;
          aborted = action == 0 && fault inside {0, 7};
          expected_code = RDMA_SC_RECOVERY_REQUIRED;
          expected_message = "unclaimed recovery admission is still unavailable";
          if (action == 2) begin
            expected_code = RDMA_SC_INVALID_ARGUMENT;
            expected_message = "retry requires caller confirmation";
          end
          else if (fault inside {[1:4]})
            expected_message = "unclaimed recovery evidence pair is incomplete";
          else if (fault inside {5, 6})
            expected_message = "unclaimed recovery attachment is stale";
          else if (aborted) begin
            expected_code = RDMA_SC_OK;
            expected_message = "";
          end
          else if (fault == 7)
            expected_message = "reservation-only recovery cannot retry without image";
          else if (action == 0) begin
            case (fault)
              12: begin
                expected_code = RDMA_SC_RESOURCE_BUSY;
                expected_message = "queue runtime is busy";
              end
              13: begin
                expected_code = RDMA_SC_RESOURCE_BUSY;
                expected_message = "queue detach is busy";
              end
              14: begin
                expected_code = RDMA_SC_INVALID_STATE;
                expected_message = "recovery detach attachment is stale";
              end
              15: begin
                expected_code = RDMA_SC_INVALID_STATE;
                expected_message = "runtime is not a device ring";
              end
              default: begin end
            endcase
          end
          engine.recover_queue(handle, action == 0 ? RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH :
            RDMA_QUEUE_RECOVERY_RETRY_PENDING, action != 2, status);
          cases++;
          expect_code("HANDOFF_MATRIX", status, expected_code);
          if (status == null || status.message != expected_message ||
              engine.admission_calls != expected_calls ||
              (expected_calls != 0 && !engine.pair_visible_at_admission) ||
              engine.pair_bits() != (aborted ? 4'b0000 : before_pair) ||
              engine.attached() != (aborted ? 1'b0 : before_attached) ||
              engine.observed_runtime.producer_index != 0 ||
              engine.observed_runtime.consumer_index != 0 || engine.observed_runtime.used != 0 ||
              engine.observed_runtime.tokens() != (fault == 12 ? 0 : 1))
            `uvm_error("HANDOFF", $sformatf("matrix drift fault=%0d mode=%0d action=%0d",
                                           fault, mode, action))
          if (fault == 12)
            engine.observed_runtime.set_busy(1'b0);
          if (fault == 13)
            engine.release_resize();
        end
      end
    end
  endtask

  // 功能：四次 raw cursor 分配故障保留 pair；真实接管后的 abort、重复调用及 retry 查询失败
  //   再 abort 共四次，证明 handoff 后的 claimed 流程仍继续且不会重复 admission。
  // 输入/输出及副作用：临时替换 factory 并恢复；真实 runtime 接管与 abort 改变其状态。
  // 失败/边界：query_pending 锁忙在任何 I/O 前停止，解除锁后必须能正常 abort。
  task check_handoff_and_factory();
    uvm_coreservice_t service = uvm_coreservice_t::get();
    uvm_factory original = service.get_factory();
    rdma_handoff_cursor_factory factory;
    rdma_handoff_engine_probe engine;
    rdma_handle handle;
    rdma_status status;

    for (int unsigned mode = 1; mode <= 2; mode++) begin
      for (int unsigned wrong = 0; wrong < 2; wrong++) begin
        setup(0, mode, engine, handle);
        factory = new(bit'(wrong));
        service.set_factory(factory);
        engine.recover_queue(handle, RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH, 0, status);
        service.set_factory(original);
        cases++;
        expect_code("HANDOFF_CURSOR_FACTORY", status, RDMA_SC_RESOURCE_EXHAUSTED);
        if (status.message != "device reservation snapshot allocation failed" ||
            engine.pair_bits() != 4'b1111 || !engine.attached() || factory.calls != 1 ||
            engine.observed_runtime.tokens() != 1)
          `uvm_error("HANDOFF", "cursor failure lost evidence or lock")
      end
    end
    setup(0, 0, engine, handle);
    engine.recover_queue(handle, RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH, 0, status);
    cases++;
    expect_ok("HANDOFF_REAL_ABORT", status);
    if (engine.pair_bits() != 0 || engine.attached() || engine.admission_calls != 1 ||
        !engine.pair_visible_at_admission ||
        engine.observed_runtime.state != RDMA_QUEUE_RUNTIME_DETACHED)
      `uvm_error("HANDOFF", "real handoff did not finish claimed abort")
    engine.recover_queue(handle, RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH, 0, status);
    cases++;
    expect_code("HANDOFF_REPEATED_ABORT", status, RDMA_SC_INVALID_STATE);
    if (status.message != "queue has no pending recovery" || engine.admission_calls != 1)
      `uvm_error("HANDOFF", "repeated abort repeated admission")
    setup(0, 3, engine, handle);
    engine.recover_queue(handle, RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1, status);
    cases++;
    expect_code("HANDOFF_RETRY_QUERY_BUSY", status, RDMA_SC_RESOURCE_BUSY);
    if (engine.pair_bits() != 0 || !engine.attached() || engine.admission_calls != 1 ||
        engine.observed_runtime.state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED)
      `uvm_error("HANDOFF", "successful handoff was rolled back after claimed query failure")
    engine.observed_runtime.set_busy(1'b0);
    engine.recover_queue(handle, RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH, 0, status);
    cases++;
    expect_ok("HANDOFF_CLAIMED_ABORT", status);
    if (engine.attached() || engine.admission_calls != 1 || engine.observed_runtime.tokens() != 1)
      `uvm_error("HANDOFF", "claimed abort leaked attachment or repeated handoff")
  endtask

  // 功能：运行 104 次公开恢复调用并发布完整计数，不执行父测试或新 helper。
  // 输入/输出及副作用：phase 管理 objection；fixture 不接入外部 I/O，无跨例共享状态。
  // 失败/边界：计数不齐报 error；所有调用同步无延时，不宣称线程交错或全部发布场景穷举。
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    check_matrix();
    check_handoff_and_factory();
    if (cases != 104)
      `uvm_error("HANDOFF", $sformatf("unexpected recovery calls %0d", cases))
    `uvm_info("HANDOFF", "completed 104 unclaimed recovery calls", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass
