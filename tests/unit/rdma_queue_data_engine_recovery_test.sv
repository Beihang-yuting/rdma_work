// 目录：测试层 unit/rdma_queue_data_engine_recovery_test.sv。
// 职责：验证 rdma_queue_data_engine_recovery_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_queue_data_engine_recovery_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

// 设计说明：public recover_queue 的 consumer SUCCESS 场景需要向 runtime 注入
// 完整 prepared evidence；测试子类仅把 protected attachment lookup 转为测试期
// 非拥有 runtime 引用，不改变生产接口或被测 recovery 路径。
class rdma_queue_data_engine_recovery_probe extends rdma_queue_data_engine;
  `uvm_object_utils(rdma_queue_data_engine_recovery_probe)

  // 功能：构造 recovery probe engine，仅建立与生产 engine 相同的初始状态。
  // 输入/输出及副作用：name（输入）传给父类；不配置 manager/backend 或 attachment。
  // 失败/边界：构造后仍需 fixture.setup 完成 configure/attach，未配置查询必须拒绝。
  function new(string name = "rdma_queue_data_engine_recovery_probe");
    super.new(name);
  endfunction

  // 功能：按完整 handle/kind 定位 fixture 已创建的 attachment，并返回其 runtime
  //   非拥有引用，供测试安装真实 consumer prepared recovery evidence。
  // 输入/输出及副作用：handle/kind（输入）、runtime（输出）先置 null；只调用
  //   protected lookup_attachment，不修改 engine 索引、runtime 或 backing。
  // 失败/边界：句柄 stale、kind 不匹配、attachment/runtime 缺失时返回非成功状态，
  //   runtime 保持 null；成功引用只在 fixture 生命周期内有效。
  function rdma_status query_runtime_for_test(
    rdma_handle handle,
    rdma_queue_runtime_kind_e kind,
    output rdma_queue_runtime runtime
  );
    rdma_queue_data_attachment attachment;
    rdma_status status;

    runtime = null;
    status = lookup_attachment(handle, kind, attachment);
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make(RDMA_SC_INVALID_STATE,
                          "probe lookup returned null status") : status;
    if (attachment == null || attachment.runtime == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "probe attachment runtime is missing");
    runtime = attachment.runtime;
    return rdma_status::success();
  endfunction
endclass

class rdma_queue_data_engine_recovery_test extends uvm_test;
  `uvm_component_utils(rdma_queue_data_engine_recovery_test)

  // 功能：构造 rdma_queue_data_engine_recovery_test，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_data_engine_recovery_test 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_data_engine_recovery_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：make_queue_handle 创建独立的 rdma_handle；根据 name 设置字段 result、result.kind、result.function_uid、result.object_id、result.generation，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）；make_queue_handle 读取 name 并使用字段 result、result.kind、result.function_uid、result.object_id、result.generation；函数返回 rdma_handle，不取得调用方资源所有权。
  // 失败/边界：make_queue_handle 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  function automatic rdma_handle make_queue_handle(string name);
    rdma_handle result;
    result = rdma_handle::type_id::create(name);
    result.kind = RDMA_RESOURCE_QP;
    result.function_uid = 64'hfeed_0000_0000_0001;
    result.object_id = 32'h42;
    result.generation = 9;
    return result;
  endfunction

  // 功能：在测试辅助 rdma_queue_data_engine_recovery_test.check_pending_snapshot 中构造或驱动“pending snapshot”场景，并断言 DUT
  //   的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_pending_snapshot();
    rdma_queue_runtime runtime;
    rdma_queue_pending_operation pending;
    rdma_queue_pending_operation snapshot;
    rdma_queue_cursor_snapshot cursor;
    rdma_hw_image image;
    rdma_handle queue_h;
    rdma_status status;

    runtime = rdma_queue_runtime::type_id::create("recovery_runtime");
    queue_h = make_queue_handle("recovery_qp");
    status = runtime.configure(queue_h, RDMA_QUEUE_RUNTIME_SQ,
                               8, 0, 0, 0, 0, 1'b1);
    if (status == null || !status.ok()) begin
      `uvm_error("RECOVERY_SETUP", status == null ? "null status" :
                 status.convert2string())
      return;
    end
    status = runtime.activate();
    if (status == null || !status.ok()) begin
      `uvm_error("RECOVERY_ACTIVATE", status == null ? "null status" :
                 status.convert2string())
      return;
    end

    cursor = rdma_queue_cursor_snapshot::type_id::create("pending_cursor");
    cursor.index = 3;
    cursor.wrap = 1'b1;
    image = rdma_hw_image::type_id::create("pending_image");
    image.bytes.push_back(8'haa);
    image.bytes.push_back(8'h55);
    image.length = 2;
    pending = rdma_queue_pending_operation::type_id::create("pending");
    pending.queue_h = queue_h;
    pending.kind = RDMA_QUEUE_RUNTIME_SQ;
    pending.producer = 1'b1;
    pending.entry_offset = 192;
    pending.cursor = cursor;
    pending.image = image;
    status = runtime.enter_recovery(pending, 1'b0);
    if (status == null || !status.ok()) begin
      `uvm_error("RECOVERY_ENTER", status == null ? "null status" :
                 status.convert2string())
      return;
    end

    snapshot = null;
    status = runtime.snapshot_pending(snapshot);
    if (status == null || !status.ok() || snapshot == null ||
        snapshot.queue_h == null || snapshot.queue_h == queue_h ||
        snapshot.kind != RDMA_QUEUE_RUNTIME_SQ || !snapshot.producer ||
        snapshot.entry_offset != 192 || snapshot.cursor == null ||
        snapshot.cursor == cursor || snapshot.cursor.index != 3 ||
        !snapshot.cursor.wrap || snapshot.image == null ||
        snapshot.image == image || snapshot.image.bytes.size() != 2 ||
        snapshot.image.bytes[0] != 8'haa || snapshot.image.bytes[1] != 8'h55)
      `uvm_error("RECOVERY_SNAPSHOT",
                 status == null ? "pending snapshot unavailable" :
                 status.convert2string())
  endtask

  // 功能：在测试辅助 rdma_queue_data_engine_recovery_test.check_engine_recovery_policy 中构造或驱动“engine recovery policy”场景，并断言
  //   DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_engine_recovery_policy();
    rdma_queue_data_engine_fixture fixture;
    rdma_post_send_req request;
    rdma_queue_post_result result;
    rdma_status status;
    rdma_status injected;

    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "recovery_engine_fixture");
    fixture.setup(status);
    if (status == null || !status.ok()) begin
      `uvm_error("RECOVERY_FIXTURE", status == null ? "null setup status" :
                 status.convert2string())
      return;
    end
    request = fixture.make_send(64'h9999_aaaa_bbbb_cccc);
    injected = rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                  "injected queue write failure");
    fixture.mem.fail_next("write", injected);
    fixture.engine.post_send(request, result, status);
    if (status == null || status.ok() || result != null)
      `uvm_error("RECOVERY_WRITE_FAIL", "failed write published a result")
    fixture.engine.recover_queue(
      fixture.qp.handle, RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b0, status);
    if (status == null || status.code != RDMA_SC_INVALID_ARGUMENT)
      `uvm_error("RECOVERY_CONFIRM", "retry without confirmation was accepted")
    fixture.engine.recover_queue(
      fixture.qp.handle, RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1, status);
    if (status == null || !status.ok())
      `uvm_error("RECOVERY_RETRY", status == null ? "null status" :
                 status.convert2string())
    // A confirmed retry must replay the pending write and producer commit,
    // rather than merely changing the runtime state.  The next post therefore
    // starts at slot 1; slot 0 is owned by the recovered operation.
    result = null;
    fixture.engine.post_send(fixture.make_send(64'h9999_aaaa_bbbb_cccd),
                             result, status);
    if (status == null || !status.ok() || result == null || result.index != 1)
      `uvm_error("RECOVERY_REPLAY", status == null ? "null status" :
                 status.convert2string())

    fixture.pcie.fail_next("mmio_write",
      rdma_status::make(RDMA_SC_TIMEOUT, "injected ambiguous MMIO"));
    result = null;
    fixture.engine.post_send(request, result, status);
    if (status == null || status.ok() || result != null)
      `uvm_error("RECOVERY_MMIO_FAIL", "ambiguous MMIO published a result")
    fixture.engine.recover_queue(
      fixture.qp.handle, RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1, status);
    if (status == null || status.code != RDMA_SC_RECOVERY_REQUIRED)
      `uvm_error("RECOVERY_MMIO_RETRY", "ambiguous MMIO was retried")
    fixture.engine.recover_queue(
      fixture.qp.handle, RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH, 1'b0, status);
    if (status == null || !status.ok())
      `uvm_error("RECOVERY_ABORT", status == null ? "null status" :
                 status.convert2string())
  endtask

  // 功能：验证 public recover_queue 接受 caller-confirmed 的 consumer MMIO
  //   SUCCESS pending，只恢复 CQ 本地 WQE release/CI/complete 阶段且不重发 doorbell。
  // 输入/输出及副作用：无显式参数；建立真实 fixture，执行 post_send、publish_cqe，
  //   经测试 probe 安装 SUCCESS pending，再比较 mock PCIe mmio_write 调用数和 occupancy。
  // 失败/边界：setup/post/publish/probe/admission 任一步失败即报告并返回；recovery
  //   必须成功、PCIe 计数不变、SQ/CQ occupancy 清零且 CQ pending 被清除。
  task automatic check_success_consumer_recovery_skips_mmio();
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_data_engine_recovery_probe probe;
    rdma_queue_runtime runtime;
    rdma_post_send_req request;
    rdma_queue_post_result posted;
    rdma_hw_cqe_model cqe;
    rdma_queue_device_publish_result published;
    rdma_queue_pending_operation pending;
    rdma_queue_cursor_snapshot cursor;
    rdma_route_key_t route;
    rdma_reset_epoch_t epoch;
    rdma_status status;
    int unsigned mmio_before;
    int unsigned mmio_after;
    int unsigned occupancy;
    bit route_valid;
    bit epoch_valid;
    bit has_pending;
    bit polarity;

    uvm_factory::get().set_type_override_by_type(
      rdma_queue_data_engine::get_type(),
      rdma_queue_data_engine_recovery_probe::get_type(), 1'b1);
    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "success_consumer_fixture");
    fixture.setup(status);
    if (status == null || !status.ok() ||
        !$cast(probe, fixture.engine)) begin
      `uvm_error("SUCCESS_CONSUMER_FIXTURE",
                 status == null ? "null setup status" :
                 status.convert2string())
      return;
    end

    request = fixture.make_send(64'h9999_aaaa_0000_0001);
    fixture.engine.post_send(request, posted, status);
    if (status == null || !status.ok() || posted == null) begin
      `uvm_error("SUCCESS_CONSUMER_POST",
                 status == null ? "null post status" :
                 status.convert2string())
      return;
    end
    polarity = 1'b0;
    status = fixture.engine.query_runtime_producer_polarity(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, polarity);
    if (status == null || !status.ok()) begin
      `uvm_error("SUCCESS_CONSUMER_POLARITY",
                 status == null ? "null polarity status" :
                 status.convert2string())
      return;
    end
    cqe = rdma_hw_cqe_model::type_id::create("success_consumer_cqe");
    if (cqe == null) begin
      `uvm_error("SUCCESS_CONSUMER_CQE", "CQE allocation failed")
      return;
    end
    cqe.qp_h = rdma_clone_handle_value(
      fixture.qp.handle, "success consumer CQE QP");
    cqe.wr_id = posted.wr_id;
    cqe.opcode = RDMA_WR_SEND;
    cqe.qpn = fixture.qp.local_qp_id;
    cqe.wqe_index = posted.index;
    cqe.wqe_wrap = posted.wrap;
    cqe.rq_cqe = 1'b0;
    cqe.polarity = polarity;
    cqe.packet_opcode = 8'h01;
    cqe.ecode = RDMA_CMQ_SUCCESS_ECODE;
    cqe.payload_len = 32;
    cqe.status = rdma_status::success();
    published = null;
    fixture.engine.publish_cqe(
      fixture.cq.handle, cqe, published, status);
    if (status == null || !status.ok() || published == null ||
        published.image == null) begin
      `uvm_error("SUCCESS_CONSUMER_PUBLISH",
                 status == null ? "null publish status" :
                 status.convert2string())
      return;
    end

    status = probe.query_runtime_for_test(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, runtime);
    if (status == null || !status.ok() || runtime == null) begin
      `uvm_error("SUCCESS_CONSUMER_RUNTIME",
                 status == null ? "null probe status" :
                 status.convert2string())
      return;
    end
    status = runtime.peek_consumer(cursor);
    if (status == null || !status.ok() || cursor == null) begin
      `uvm_error("SUCCESS_CONSUMER_CURSOR",
                 status == null ? "null consumer cursor status" :
                 status.convert2string())
      return;
    end
    route = '0;
    route_valid = 1'b0;
    epoch = '0;
    epoch_valid = 1'b0;
    status = runtime.query_route_epoch(
      route, route_valid, epoch, epoch_valid);
    if (status == null || !status.ok() || !route_valid || !epoch_valid) begin
      `uvm_error("SUCCESS_CONSUMER_AUTHORITY",
                 status == null ? "null authority status" :
                 status.convert2string())
      return;
    end

    pending = rdma_queue_pending_operation::type_id::create(
      "success_consumer_pending");
    if (pending == null) begin
      `uvm_error("SUCCESS_CONSUMER_PENDING", "pending allocation failed")
      return;
    end
    pending.queue_h = rdma_clone_handle_value(
      fixture.cq.handle, "success consumer pending CQ");
    pending.kind = RDMA_QUEUE_RUNTIME_CQ;
    pending.producer = 1'b0;
    pending.device_producer = 1'b0;
    pending.cursor = rdma_queue_cursor_snapshot::type_id::create(
      "success_consumer_cursor");
    pending.next_cursor = rdma_queue_cursor_snapshot::type_id::create(
      "success_consumer_next");
    pending.failure_status = rdma_status::make(
      RDMA_SC_INVALID_STATE, "injected post-doorbell local stage failure");
    pending.routed_qp_h = rdma_clone_handle_value(
      fixture.qp.handle, "success consumer routed QP");
    if (pending.queue_h == null || pending.cursor == null ||
        pending.next_cursor == null || pending.failure_status == null ||
        pending.routed_qp_h == null) begin
      `uvm_error("SUCCESS_CONSUMER_PENDING",
                 "pending nested evidence allocation failed")
      return;
    end
    pending.cursor.index = cursor.index;
    pending.cursor.wrap = cursor.wrap;
    pending.next_cursor.index = cursor.index;
    pending.next_cursor.wrap = cursor.wrap;
    if (pending.next_cursor.index + 1 >= runtime.depth) begin
      pending.next_cursor.index = 0;
      pending.next_cursor.wrap = ~pending.next_cursor.wrap;
    end else begin
      pending.next_cursor.index++;
    end
    pending.image = published.image;
    pending.entry_size = published.image.length;
    pending.entry_offset = longint'(cursor.index) * pending.entry_size;
    pending.wr_id = posted.wr_id;
    pending.signaled = 1'b1;
    pending.completion_index = posted.index;
    pending.completion_wrap = posted.wrap;
    pending.completion_target_valid = 1'b1;
    pending.completion_released = 1'b0;
    pending.mmio_evidence = RDMA_QUEUE_MMIO_SUCCESS;
    pending.route = route;
    pending.route_valid = route_valid;
    pending.reset_epoch = epoch;
    pending.epoch_valid = epoch_valid;
    status = runtime.enter_recovery_prepared(pending);
    if (status == null || !status.ok()) begin
      `uvm_error("SUCCESS_CONSUMER_ENTER",
                 status == null ? "null admission status" :
                 status.convert2string())
      return;
    end

    mmio_before = 0;
    foreach (fixture.pcie.calls[i])
      if (fixture.pcie.calls[i] != null &&
          fixture.pcie.calls[i].method_name == "mmio_write")
        mmio_before++;
    fixture.engine.recover_queue(
      fixture.cq.handle, RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1, status);
    mmio_after = 0;
    foreach (fixture.pcie.calls[i])
      if (fixture.pcie.calls[i] != null &&
          fixture.pcie.calls[i].method_name == "mmio_write")
        mmio_after++;
    if (status == null || !status.ok())
      `uvm_error("SUCCESS_CONSUMER_RECOVER",
                 status == null ? "null recovery status" :
                 status.convert2string())
    if (mmio_after != mmio_before)
      `uvm_error("SUCCESS_CONSUMER_MMIO_RESEND",
                 $sformatf("mmio_write count changed from %0d to %0d",
                           mmio_before, mmio_after))

    occupancy = 32'hffff_ffff;
    has_pending = 1'b1;
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, occupancy, has_pending);
    if (status == null || !status.ok() || occupancy != 0 || has_pending)
      `uvm_error("SUCCESS_CONSUMER_CQ_FINAL",
                 status == null ? "null CQ occupancy status" :
                 status.convert2string())
    status = fixture.engine.query_runtime_occupancy(
      fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, occupancy, has_pending);
    if (status == null || !status.ok() || occupancy != 0 || has_pending)
      `uvm_error("SUCCESS_CONSUMER_SQ_FINAL",
                 status == null ? "null SQ occupancy status" :
                 status.convert2string())
  endtask

  // 功能：在 rdma_queue_data_engine_recovery_test 中，run_phase 驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：run_phase 的 setup/阶段驱动失败时停止新增事务，并按测试生命周期清理 objection 与临时引用。
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    check_pending_snapshot();
    check_engine_recovery_policy();
    check_success_consumer_recovery_skips_mmio();
    phase.drop_objection(this);
  endtask
endclass
