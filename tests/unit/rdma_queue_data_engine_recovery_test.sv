// 目录：测试层 unit/rdma_queue_data_engine_recovery_test.sv。
// 职责：验证 runtime pending 的深复制、producer recovery 策略，以及 CQ consumer
//   已提交后 release-only retry 的 caller-confirmation 与幂等契约。
// 依赖：依赖 rdma_queue_runtime、rdma_queue_data_engine_fixture、ordering fault 子类、
//   mock Host-memory/PCIe backend 和 UVM phase/report 基础设施。
// 所有权与生命周期：每个 task 创建并持有独立 runtime/fixture 与 detached 快照；
//   lifecycle resource、mapping 和 backend 仍由 fixture 管理，本测试不越权释放。

// 设计说明：把纯 runtime value-copy、通用 producer replay 和 Task 8 consumer
// release-only recovery 放在同一测试组件，可同时约束 pending 证据格式和 engine 对
// 该证据的消费策略；所有断言只经公开 API 观察状态，避免形成第二份恢复账本。
class rdma_queue_data_engine_recovery_test extends uvm_test;
  `uvm_component_utils(rdma_queue_data_engine_recovery_test)

  // 功能：构造 recovery UVM test component，并把 name/parent 交给基类建立层级。
  // 输入/输出及副作用：name、parent 为输入；返回初始化后的 component，不创建
  //   runtime、fixture、queue resource 或 factory override。
  // 失败/边界：parent 可为 null 以创建顶层 test；实际依赖延迟到各检查 task 创建，
  //   构造阶段不接管 Host-memory、PCIe、manager 或 mapping 生命周期。
  function new(string name = "rdma_queue_data_engine_recovery_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：make_queue_handle 为 runtime snapshot 场景构造固定 Function/object/
  //   generation 的 QP handle，使 pending 深复制断言有手工可核对的 identity。
  // 输入/输出及副作用：name 为 factory instance name；返回由调用方持有的独立
  //   rdma_handle，不注册到 manager，也不修改任何 queue runtime。
  // 失败/边界：正常 UVM factory 必须返回非 null rdma_handle；若恶意 override 返回
  //   null，本辅助函数会在字段赋值处使测试失败，不把 allocation fault 伪装成业务状态。
  function automatic rdma_handle make_queue_handle(string name);
    rdma_handle result;
    result = rdma_handle::type_id::create(name);
    result.kind = RDMA_RESOURCE_QP;
    result.function_uid = 64'hfeed_0000_0000_0001;
    result.object_id = 32'h42;
    result.generation = 9;
    return result;
  endfunction

  // 功能：check_pending_snapshot 在独立 SQ runtime 安装带 cursor/image 的 producer
  //   pending，再验证 snapshot_pending 深复制 queue handle、cursor 与 image bytes。
  // 输入/输出及副作用：无显式输入/输出；创建并 activate depth=8 runtime，进入
  //   recovery 后只读取 detached snapshot；通过 UVM_ERROR 发布断言结果。
  // 失败/边界：configure/activate/enter_recovery 失败会报告并返回；snapshot 必须与
  //   原对象值相等但 handle/cursor/image 引用不同，缺字段或 alias 均视为失败。
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

  // 功能：check_consumer_local_stage_gates 构造 MMIO SUCCESS 的真实 CQ consumer
  //   pending，验证 no-allocation CI commit 与 WQE release marker 均经过显式 gate。
  // 输入/输出及副作用：无显式参数；创建独立 CQ runtime/handle/cursor/image/status，
  //   真实提交一项 device entry，调用 recover/commit/begin/finalize 并查询 pending。
  // 失败/边界：未 enable 的 commit 必须零 mutation；release begin 竞争必须 BUSY，
  //   cancel 只解锁并保留错误，成功 finalize 必须在 complete 前立即发布 release marker。
  task automatic check_consumer_local_stage_gates();
    rdma_queue_runtime runtime;
    rdma_queue_pending_operation pending;
    rdma_queue_pending_operation snapshot;
    rdma_queue_cursor_snapshot producer;
    rdma_handle cq_h;
    rdma_handle qp_h;
    rdma_route_key_t route;
    rdma_reset_epoch_t epoch;
    rdma_status status;
    rdma_status noalloc_status;
    rdma_status busy_status;
    int unsigned occupancy;
    int unsigned i;
    rdma_queue_runtime_state_e runtime_state;

    cq_h = make_queue_handle("consumer_gate_cq");
    if (cq_h == null) begin
      `uvm_error("CONSUMER_GATE_FIXTURE", "CQ handle allocation failed")
      return;
    end
    cq_h.kind = RDMA_RESOURCE_CQ;
    qp_h = make_queue_handle("consumer_gate_qp");
    if (qp_h == null) begin
      `uvm_error("CONSUMER_GATE_FIXTURE", "routed QP handle allocation failed")
      return;
    end
    route = '0;
    route.host_topology_key = 32'h4401;
    route.root_id = 16'h44;
    route.segment = 16'h2;
    route.bdf.segment = route.segment;
    route.bdf.bus = 8'h44;
    route.bdf.device = 5'h4;
    route.bdf.function_num = 3'h1;
    epoch = rdma_reset_epoch_t'(64'h444);

    runtime = rdma_queue_runtime::type_id::create("consumer_gate_runtime");
    if (runtime == null) begin
      `uvm_error("CONSUMER_GATE_FIXTURE", "CQ runtime allocation failed")
      return;
    end
    status = runtime.configure(cq_h, RDMA_QUEUE_RUNTIME_CQ, 4,
                               0, 1'b0, 0, 1'b0, 1'b0);
    if (status == null || !status.ok()) begin
      `uvm_error("CONSUMER_GATE_CONFIGURE", status == null ? "null status" :
                 status.convert2string())
      return;
    end
    status = runtime.set_route_epoch(route, epoch);
    if (status == null || !status.ok()) begin
      `uvm_error("CONSUMER_GATE_AUTHORITY", status == null ? "null status" :
                 status.convert2string())
      return;
    end
    status = runtime.activate();
    if (status == null || !status.ok()) begin
      `uvm_error("CONSUMER_GATE_ACTIVATE", status == null ? "null status" :
                 status.convert2string())
      return;
    end
    status = runtime.reserve_device_producer(producer);
    if (status == null || !status.ok() || producer == null) begin
      `uvm_error("CONSUMER_GATE_RESERVE", status == null ? "null status" :
                 status.convert2string())
      return;
    end
    status = runtime.commit_device_producer(producer);
    if (status == null || !status.ok()) begin
      `uvm_error("CONSUMER_GATE_DEVICE_COMMIT", status == null ? "null status" :
                 status.convert2string())
      return;
    end

    pending = rdma_queue_pending_operation::type_id::create(
      "consumer_gate_pending");
    if (pending == null) begin
      `uvm_error("CONSUMER_GATE_FIXTURE", "pending allocation failed")
      return;
    end
    pending.queue_h = make_queue_handle("consumer_gate_pending_cq");
    if (pending.queue_h == null) begin
      `uvm_error("CONSUMER_GATE_FIXTURE", "pending CQ handle allocation failed")
      return;
    end
    pending.queue_h.kind = RDMA_RESOURCE_CQ;
    pending.kind = RDMA_QUEUE_RUNTIME_CQ;
    pending.cursor = rdma_queue_cursor_snapshot::type_id::create(
      "consumer_gate_cursor");
    pending.next_cursor = rdma_queue_cursor_snapshot::type_id::create(
      "consumer_gate_next");
    pending.image = rdma_hw_image::type_id::create("consumer_gate_image");
    pending.failure_status = rdma_status::make(
      RDMA_SC_INVALID_STATE, "prepared consumer gate sentinel");
    if (pending.cursor == null || pending.next_cursor == null ||
        pending.image == null || pending.failure_status == null) begin
      `uvm_error("CONSUMER_GATE_FIXTURE", "pending evidence allocation failed")
      return;
    end
    pending.cursor.index = producer.index;
    pending.cursor.wrap = producer.wrap;
    pending.next_cursor.index = producer.index + 1;
    pending.next_cursor.wrap = producer.wrap;
    if (pending.next_cursor.index >= 4) begin
      pending.next_cursor.index = 0;
      pending.next_cursor.wrap = ~pending.next_cursor.wrap;
    end
    pending.entry_size = 64;
    pending.entry_offset = longint'(pending.cursor.index) * pending.entry_size;
    pending.image.length = pending.entry_size;
    pending.image.image_kind = RDMA_IMAGE_CQE;
    for (i = 0; i < pending.entry_size; i++)
      pending.image.bytes.push_back(byte'(i));
    pending.mmio_evidence = RDMA_QUEUE_MMIO_SUCCESS;
    pending.completion_index = 0;
    pending.completion_wrap = 1'b0;
    pending.completion_target_valid = 1'b1;
    pending.completion_wq_kind = RDMA_QUEUE_RUNTIME_SQ;
    pending.routed_qp_h = qp_h;
    pending.route = route;
    pending.route_valid = 1'b1;
    pending.reset_epoch = epoch;
    pending.epoch_valid = 1'b1;
    status = runtime.enter_recovery_prepared(pending);
    if (status == null || !status.ok()) begin
      `uvm_error("CONSUMER_GATE_ENTER", status == null ? "null status" :
                 status.convert2string())
      return;
    end
    status = runtime.recover(
      RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1);
    if (status == null || !status.ok()) begin
      `uvm_error("CONSUMER_GATE_CONFIRM", status == null ? "null status" :
                 status.convert2string())
      return;
    end
    noalloc_status = rdma_status::make(
      RDMA_SC_OK, "unauthorized commit must replace this status");
    if (runtime.commit_consumer_recovery_noalloc(
          pending.cursor.index, pending.cursor.wrap, noalloc_status) ||
        noalloc_status == null || noalloc_status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("CONSUMER_GATE_REJECT",
                 "noalloc consumer commit bypassed recovery gate")
    status = runtime.query_occupancy(occupancy);
    if (status == null || !status.ok() || occupancy != 1)
      `uvm_error("CONSUMER_GATE_OCCUPANCY",
                 "rejected consumer commit changed CQ occupancy")
    status = runtime.query_pending(snapshot);
    if (status == null || !status.ok() || snapshot == null ||
        snapshot.consumer_committed || snapshot.cq_consumer_committed ||
        snapshot.committed_consumer_cursor != null)
      `uvm_error("CONSUMER_GATE_PENDING",
                 "rejected consumer commit published stage evidence")

    if (!runtime.enable_recovery_commit_noalloc(noalloc_status) ||
        noalloc_status == null || !noalloc_status.ok()) begin
      `uvm_error("CONSUMER_GATE_ENABLE",
                 "noalloc consumer commit gate could not be enabled")
      return;
    end
    if (!runtime.commit_consumer_recovery_noalloc(
          pending.cursor.index, pending.cursor.wrap, noalloc_status) ||
        noalloc_status == null || !noalloc_status.ok()) begin
      `uvm_error("CONSUMER_GATE_COMMIT",
                 "authorized noalloc consumer commit failed")
      return;
    end
    status = runtime.query_pending(snapshot);
    if (status == null || !status.ok() || snapshot == null ||
        !snapshot.consumer_committed || !snapshot.cq_consumer_committed ||
        snapshot.completion_released ||
        snapshot.committed_consumer_cursor == null) begin
      `uvm_error("CONSUMER_GATE_COMMITTED_PENDING",
                 "authorized commit did not publish exact stage evidence")
      return;
    end

    if (!runtime.begin_consumer_release_noalloc(noalloc_status) ||
        noalloc_status == null || !noalloc_status.ok()) begin
      `uvm_error("CONSUMER_RELEASE_BEGIN", "release gate could not be acquired")
      return;
    end
    busy_status = rdma_status::make(
      RDMA_SC_OK, "competing release begin must replace this status");
    if (runtime.begin_consumer_release_noalloc(busy_status) ||
        busy_status == null || busy_status.code != RDMA_SC_RESOURCE_BUSY)
      `uvm_error("CONSUMER_RELEASE_BUSY",
                 "competing release begin did not fail before WQ mutation")

    noalloc_status.code = RDMA_SC_INVALID_STATE;
    noalloc_status.message = "preserved WQE release failure";
    if (!runtime.finish_consumer_release_noalloc(1'b0, noalloc_status) ||
        noalloc_status.code != RDMA_SC_INVALID_STATE ||
        noalloc_status.message != "preserved WQE release failure") begin
      `uvm_error("CONSUMER_RELEASE_CANCEL",
                 "failed release did not unlock with its diagnosis preserved")
      return;
    end
    status = runtime.query_pending(snapshot);
    if (status == null || !status.ok() || snapshot == null ||
        snapshot.completion_released) begin
      `uvm_error("CONSUMER_RELEASE_CANCEL_PENDING",
                 "failed release published completion_released")
      return;
    end

    if (!runtime.begin_consumer_release_noalloc(noalloc_status) ||
        noalloc_status == null || !noalloc_status.ok() ||
        !runtime.finish_consumer_release_noalloc(1'b1, noalloc_status) ||
        !noalloc_status.ok()) begin
      `uvm_error("CONSUMER_RELEASE_FINISH",
                 "successful release could not publish its marker")
      return;
    end
    status = runtime.query_pending(snapshot);
    if (status == null || !status.ok() || snapshot == null ||
        !snapshot.completion_released)
      `uvm_error("CONSUMER_RELEASE_MARKER",
                 "successful release marker was not immediately visible")
    if (!runtime.complete_consumer_recovery_noalloc(1'b0, noalloc_status) ||
        noalloc_status == null || !noalloc_status.ok()) begin
      `uvm_error("CONSUMER_RELEASE_COMPLETE",
                 "premarked consumer recovery did not complete")
      return;
    end
    status = runtime.query_occupancy(occupancy);
    if (status == null || !status.ok() || occupancy != 0)
      `uvm_error("CONSUMER_RELEASE_FINAL_OCCUPANCY",
                 "completed consumer recovery retained CQ occupancy")
    status = runtime.query_state(runtime_state);
    if (status == null || !status.ok() ||
        runtime_state != RDMA_QUEUE_RUNTIME_ACTIVE)
      `uvm_error("CONSUMER_RELEASE_FINAL_STATE",
                 "completed consumer recovery did not return ACTIVE")
  endtask

  // 功能：check_engine_recovery_policy 验证 producer write 的 NO_SUBMIT pending
  //   需要 caller confirmation 后才 replay/commit，并验证 MMIO 失败的 AMBIGUOUS
  //   pending 禁止自动 retry、只能显式 abort/detach。
  // 输入/输出及副作用：无显式输入/输出；创建真实 data-engine fixture，注入一次
  //   Host-memory write 与一次 PCIe MMIO 故障，调用 post_send/recover_queue，并以
  //   下一次 post 的 slot index 证明首个 pending 已完成 producer commit。
  // 失败/边界：setup 或任一预期状态不符均报告 UVM_ERROR；未确认 retry 必须返回
  //   INVALID_ARGUMENT，ambiguous retry 必须返回 RECOVERY_REQUIRED，结果不得伪造成功。
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
    // 设计说明：confirmed retry 必须真正重放 pending write 与 producer commit，
    // 不能只修改 runtime state；因此下一次 post 应从 slot 1 开始，slot 0 仍由
    // 已恢复的 operation 占有。
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

  // 功能：验证真实 CQ poll 在 release 一次性失败后留下 consumer MMIO SUCCESS
  //   pending；未确认 recovery 不推进，确认后只补 WQE release 而不重发 doorbell/CI。
  // 输入/输出及副作用：无显式参数；建立 ordering-fault fixture，执行真实
  //   post_send、publish_cqe、poll_cqe 与 public recover_queue，并观测 trace、公开
  //   detached pending、CQ/SQ occupancy、factory guard 与 CQE codec guard；成功最终
  //   各消费一份 CQE/WQE credit。
  // 失败/边界：setup/post/publish/poll 或 pending 查询失败即报告并返回；首次 poll
  //   必须在 doorbell→commit 后只失败一次 release，未确认 retry 必须拒绝且零副作用，
  //   确认 retry 只能再调用一次 release，禁止重复 MMIO、CI decrement、codec lookup/
  //   decode、factory allocation 或 ledger 释放。
  task automatic check_success_consumer_recovery_skips_mmio();
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_data_engine_ordering_fault ordering;
    rdma_post_send_req request;
    rdma_queue_post_result posted;
    rdma_hw_cqe_model cqe;
    rdma_queue_device_publish_result published;
    rdma_queue_completion_result completion;
    rdma_queue_pending_operation pending;
    rdma_status status;
    rdma_queue_consumer_fault_registry fault_registry;
    rdma_queue_consumer_codec_guard codec_guard;
    rdma_codec_base original_cqe_codec;
    rdma_codec_base displaced_cqe_codec;
    rdma_codec_key cqe_codec_key;
    rdma_queue_poll_factory_fault_wrapper status_guard;
    rdma_queue_poll_factory_fault_wrapper pending_guard;
    rdma_queue_poll_factory_fault_wrapper handle_guard;
    rdma_queue_poll_factory_fault_wrapper cursor_guard;
    rdma_queue_poll_factory_fault_wrapper image_guard;
    rdma_queue_poll_factory_fault_wrapper slot_guard;
    rdma_queue_poll_factory_fault_wrapper cqe_model_guard;
    uvm_factory factory;
    int unsigned occupancy;
    int unsigned trace_before_retry;
    int unsigned guarded_creates;
    string first_guarded_create;
    bit has_pending;
    bit polarity;

    factory = uvm_factory::get();
    factory.set_type_override_by_type(
      rdma_queue_data_engine::get_type(),
      rdma_queue_data_engine_ordering_fault::get_type(), 1'b1);
    factory.set_type_override_by_type(
      rdma_hw_doorbell_codec_registry::get_type(),
      rdma_queue_consumer_fault_registry::get_type(), 1'b1);
    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "success_consumer_fixture");
    fixture.setup(status);
    if (status == null || !status.ok() ||
        !$cast(ordering, fixture.engine) ||
        !$cast(fault_registry, fixture.registry)) begin
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

    ordering.fail_release_once = 1'b1;
    completion = null;
    fixture.engine.poll_cqe(
      fixture.cq.handle, 0, completion, status);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        completion != null) begin
      `uvm_error("SUCCESS_CONSUMER_POLL",
                 status == null ? "null poll status" :
                 status.convert2string())
      return;
    end
    if (ordering.trace.size() != 3 ||
        ordering.trace[0] != "doorbell" ||
        ordering.trace[1] != "commit" ||
        ordering.trace[2] != "release" ||
        ordering.doorbell_calls != 1 || ordering.commit_calls != 1 ||
        ordering.release_calls != 1)
      `uvm_error("SUCCESS_CONSUMER_INITIAL_ORDER", $sformatf(
        "trace=%p calls=%0d/%0d/%0d", ordering.trace,
        ordering.doorbell_calls, ordering.commit_calls, ordering.release_calls))

    pending = null;
    status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending);
    if (status == null || !status.ok() || pending == null ||
        pending.mmio_evidence != RDMA_QUEUE_MMIO_SUCCESS ||
        !pending.consumer_doorbell_succeeded || !pending.consumer_committed ||
        !pending.cq_consumer_committed || pending.completion_released ||
        pending.committed_consumer_cursor == null ||
        pending.next_cursor == null ||
        pending.committed_consumer_cursor.index != pending.next_cursor.index ||
        pending.committed_consumer_cursor.wrap != pending.next_cursor.wrap ||
        pending.failure_status == null ||
        pending.failure_status.code != RDMA_SC_INVALID_STATE) begin
      `uvm_error("SUCCESS_CONSUMER_PENDING",
                 status == null ? "null pending status" :
                 status.convert2string())
      return;
    end

    occupancy = 32'hffff_ffff;
    has_pending = 1'b0;
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, occupancy, has_pending);
    if (status == null || !status.ok() || occupancy != 0 || !has_pending)
      `uvm_error("SUCCESS_CONSUMER_CQ_PENDING",
                 "release failure lost committed CQ recovery evidence")
    status = fixture.engine.query_runtime_occupancy(
      fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, occupancy, has_pending);
    if (status == null || !status.ok() || occupancy != 1 || has_pending)
      `uvm_error("SUCCESS_CONSUMER_SQ_PENDING",
                 "release failure changed the SQ WQE ledger")

    trace_before_retry = ordering.trace.size();
    fixture.engine.recover_queue(
      fixture.cq.handle, RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b0, status);
    if (status == null || status.code != RDMA_SC_INVALID_ARGUMENT ||
        ordering.trace.size() != trace_before_retry ||
        ordering.doorbell_calls != 1 || ordering.commit_calls != 1 ||
        ordering.release_calls != 1)
      `uvm_error("SUCCESS_CONSUMER_CONFIRM",
                 "unconfirmed retry changed a completed transaction stage")

    // 中文设计：在 confirmed SUCCESS continuation 前替换 CQE codec，并让
    // test-only engine 到达首个 commit/release seam 时再打开 factory guard。
    // 合规实现可在 seam 前完成 public detached query/route 校验，但 seam 后
    // 只使用 admission-time routed_qp_h/completion cursor，不触发 codec 或 factory。
    cqe_codec_key = '{hw_version:"rdma", image_kind:RDMA_IMAGE_CQE,
      object_type:"cqe", variant:"default", opcode:8'h00};
    original_cqe_codec = null;
    status = fixture.registry.lookup(cqe_codec_key, original_cqe_codec);
    if (status == null || !status.ok() || original_cqe_codec == null) begin
      `uvm_error("SUCCESS_CONSUMER_CODEC_SETUP", status == null ?
                 "CQE codec lookup returned null" : status.convert2string())
      return;
    end
    codec_guard = new("success_recovery_cqe_guard", original_cqe_codec);
    codec_guard.injected_error = rdma_status::make(
      RDMA_SC_CODEC_ERROR, "SUCCESS recovery attempted to decode CQE");
    codec_guard.block_decode = 1'b1;
    displaced_cqe_codec = null;
    if (!fault_registry.replace_codec_for_test(
          cqe_codec_key, codec_guard, displaced_cqe_codec) ||
        displaced_cqe_codec != original_cqe_codec) begin
      `uvm_error("SUCCESS_CONSUMER_CODEC_REPLACE", "CQE codec guard install failed")
      return;
    end
    status_guard = new("recovery_status_guard", rdma_status::get_type());
    pending_guard = new(
      "recovery_pending_guard", rdma_queue_pending_operation::get_type());
    handle_guard = new("recovery_handle_guard", rdma_handle::get_type());
    cursor_guard = new(
      "recovery_cursor_guard", rdma_queue_cursor_snapshot::get_type());
    image_guard = new("recovery_image_guard", rdma_hw_image::get_type());
    slot_guard = new(
      "recovery_slot_guard", rdma_queue_slot_ledger_entry::get_type());
    cqe_model_guard = new(
      "recovery_cqe_model_guard", rdma_hw_cqe_model::get_type());
    factory.set_type_override_by_type(
      rdma_status::get_type(), status_guard, 1'b1);
    factory.set_type_override_by_type(
      rdma_queue_pending_operation::get_type(), pending_guard, 1'b1);
    factory.set_type_override_by_type(
      rdma_handle::get_type(), handle_guard, 1'b1);
    factory.set_type_override_by_type(
      rdma_queue_cursor_snapshot::get_type(), cursor_guard, 1'b1);
    factory.set_type_override_by_type(
      rdma_hw_image::get_type(), image_guard, 1'b1);
    factory.set_type_override_by_type(
      rdma_queue_slot_ledger_entry::get_type(), slot_guard, 1'b1);
    factory.set_type_override_by_type(
      rdma_hw_cqe_model::get_type(), cqe_model_guard, 1'b1);
    ordering.arm_recovery_allocation_guard_once = 1'b1;
    fixture.engine.recover_queue(
      fixture.cq.handle, RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1, status);
    rdma_queue_poll_factory_fault_wrapper::disable_allocation_guard(
      guarded_creates, first_guarded_create);
    void'(fault_registry.restore_codec_for_test(
      cqe_codec_key, original_cqe_codec));
    if (status == null || !status.ok())
      `uvm_error("SUCCESS_CONSUMER_RECOVER",
                 status == null ? "null recovery status" :
                 status.convert2string())
    if (codec_guard.decode_calls != 0)
      `uvm_error("SUCCESS_CONSUMER_NO_DECODE", $sformatf(
        "SUCCESS recovery called CQE decode %0d times", codec_guard.decode_calls))
    if (guarded_creates != 0)
      `uvm_error("SUCCESS_CONSUMER_NO_ALLOC", $sformatf(
        "SUCCESS recovery factory creates=%0d first=%s",
        guarded_creates, first_guarded_create))
    if (ordering.trace.size() != trace_before_retry + 1 ||
        ordering.trace[trace_before_retry] != "release" ||
        ordering.doorbell_calls != 1 || ordering.commit_calls != 1 ||
        ordering.release_calls != 2)
      `uvm_error("SUCCESS_CONSUMER_RELEASE_ONLY", $sformatf(
        "trace=%p calls=%0d/%0d/%0d", ordering.trace,
        ordering.doorbell_calls, ordering.commit_calls, ordering.release_calls))

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

  // 功能：run_phase 顺序执行 pending 深复制、producer policy 与 consumer
  //   release-only recovery 三组独立断言，并用 objection 覆盖全部异步 test 时间。
  // 输入/输出及副作用：phase 由 UVM 输入；raise 后调用三个检查 task，最后 drop；
  //   可观察输出仅为 UVM report/summary，不向各 fixture 转移资源所有权。
  // 失败/边界：子 task 以 UVM_ERROR 记录失败并自行结束场景；run_phase 即使已有
  //   error 也继续其余独立覆盖，且在全部调用返回后始终释放 objection。
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    check_pending_snapshot();
    check_consumer_local_stage_gates();
    check_engine_recovery_policy();
    check_success_consumer_recovery_skips_mmio();
    phase.drop_objection(this);
  endtask
endclass
