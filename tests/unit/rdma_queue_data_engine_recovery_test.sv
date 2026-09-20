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

// 设计说明：make_pending 是 legacy host-producer 失败路径的兼容工厂；它接收
// semantic request/image 的多态引用，因此 clone() 是必须显式验证的 value-boundary。
// 下面的 probe 与 hostile value 只暴露这一边界供 focused regression 使用，不改变
// 生产 engine 的可见接口，也不把测试故障注入 runtime 或外部 backing。
class rdma_pending_clone_fault_request extends rdma_post_send_req;
  `uvm_object_utils(rdma_pending_clone_fault_request)

  bit return_wrong_type;

  // 功能：构造可选择返回 null 或错误类型 clone 的 hostile post-send request。
  // 输入/输出及副作用：name 设置 UVM 对象名；return_wrong_type 默认清零，除本地
  //   故障开关外不申请 queue、mapping、Host-memory 或 scheduler 资源。
  // 失败/边界：对象只用于 recovery evidence 负例，不能送入正常 post_send；clone
  //   故障不会修改源 request 或任何 runtime 状态。
  function new(string name = "rdma_pending_clone_fault_request");
    super.new(name);
    return_wrong_type = 1'b0;
  endfunction

  // 功能：在 make_pending 的 request snapshot 边界注入 null 或不可转换对象，
  //   模拟多态 clone 实现失效。
  // 输入/输出及副作用：无显式输入；返回 null 或 rdma_hw_image 错误类型，不修改
  //   request 字段，也不触碰 runtime/ledger。
  // 失败/边界：return_wrong_type=1 时故意触发 $cast 失败；否则返回 null；生产
  //   make_pending 必须把两种结果都视为 evidence 构造失败。
  virtual function uvm_object clone();
    rdma_hw_image wrong_type;

    if (!return_wrong_type)
      return null;
    wrong_type = new("pending_wrong_request_clone");
    return wrong_type;
  endfunction
endclass

// 设计说明：image clone 也属于 recovery evidence 的不可变值边界；单独的 hostile
// 子类确保 request clone 成功时仍能隔离 image 失败，不让测试只覆盖一个字段。
class rdma_pending_clone_fault_image extends rdma_hw_image;
  `uvm_object_utils(rdma_pending_clone_fault_image)

  bit return_wrong_type;

  // 功能：构造可选择返回 null 或错误类型 clone 的 hostile hardware image。
  // 输入/输出及副作用：name 设置 UVM 对象名；return_wrong_type 默认清零，只保留
  //   本地故障开关，不取得 backing 或 DMA mapping 所有权。
  // 失败/边界：该 image 仅供 make_pending focused test 使用；正常 codec/write 路径
  //   不应消费此类对象，clone 失败不能被当作可恢复 image。
  function new(string name = "rdma_pending_clone_fault_image");
    super.new(name);
    return_wrong_type = 1'b0;
  endfunction

  // 功能：在 make_pending 的 image snapshot 边界返回 null 或不可转换对象，覆盖
  //   request 已可复制但 image value 失效的 recovery 分支。
  // 输入/输出及副作用：无显式输入；返回 null 或 rdma_queue_cursor_snapshot，不修改
  //   源 image、runtime cursor 或 Host-memory。
  // 失败/边界：return_wrong_type=1 时故意触发 image $cast 失败；否则返回 null；
  //   调用方必须拒绝整个 pending，而不能保留 request-only evidence。
  virtual function uvm_object clone();
    rdma_queue_cursor_snapshot wrong_type;

    if (!return_wrong_type)
      return null;
    wrong_type = new("pending_wrong_image_clone");
    return wrong_type;
  endfunction
endclass

// 设计说明：handle clone 失败不能沿用全局 fatal 复制 helper；legacy pending
//   必须把它当作 recovery evidence 构造失败，避免 runtime 接管空 authority。
class rdma_pending_clone_fault_handle extends rdma_handle;
  `uvm_object_utils(rdma_pending_clone_fault_handle)

  bit return_wrong_type;

  // 功能：构造可选择返回 null 或错误类型 clone 的 hostile queue/route handle。
  // 输入/输出及副作用：name 设置 UVM 对象名；return_wrong_type 默认清零，不申请
  //   manager、mapping、Host-memory 或 scheduler 资源。
  // 失败/边界：对象只用于 make_pending 的 detached handle 负例；clone 故障不得
  //   触发 UVM fatal，也不得修改源 handle 或 runtime。
  function new(string name = "rdma_pending_clone_fault_handle");
    super.new(name);
    return_wrong_type = 1'b0;
  endfunction

  // 功能：在 pending handle value-boundary 返回 null 或不可转换对象，覆盖 queue_h
  //   与 routed_qp_h 两个可选 detached identity 的失败分支。
  // 输入/输出及副作用：无显式输入；返回 null 或 rdma_hw_image 错误类型，不修改
  //   handle identity、pending ledger 或外部 backing。
  // 失败/边界：return_wrong_type=1 时故意触发 make_pending 的 $cast 失败；否则
  //   返回 null；两种结果都必须使整个 pending 返回 null。
  virtual function uvm_object clone();
    rdma_hw_image wrong_type;

    if (!return_wrong_type)
      return null;
    wrong_type = new("pending_wrong_handle_clone");
    return wrong_type;
  endfunction
endclass

// 设计说明：probe 只把 production make_pending 暴露为测试可调用的 value-boundary，
// 让 focused test 不必经过 post_send 前置 snapshot.copy（该步骤会抹掉 hostile
// request 的动态类型）。probe 不持有 runtime、backing 或任何外部资源。
class rdma_queue_pending_clone_probe extends rdma_queue_data_engine;
  `uvm_object_utils(rdma_queue_pending_clone_probe)

  // 功能：构造 pending clone probe，沿用生产 engine 的未配置默认状态。
  // 输入/输出及副作用：name 传给基类；只建立本地索引和 locks，不配置 attachment、
  //   Host-memory、PCIe 或 scheduler。
  // 失败/边界：probe 不能替代已配置 engine 执行公开 post/poll；仅用于调用受保护
  //   make_pending 观察其返回的 detached evidence。
  function new(string name = "rdma_queue_pending_clone_probe");
    super.new(name);
  endfunction

  // 功能：build_pending 透传 production make_pending，供测试验证 nested clone/cast
  //   失败是否会产生可进入 recovery 的对象。
  // 输入/输出及副作用：cursor、queue_h、image、request_snapshot 等为输入；返回
  //   detached pending 或 null，不修改任何输入、runtime、backing 或 ledger。
  // 失败/边界：任一 nested clone/cast 失败都应返回 null；测试会把返回值交给公开
  //   runtime.enter_recovery，确认不完整 evidence 不能安装。
  function rdma_queue_pending_operation build_pending(
    rdma_queue_cursor_snapshot cursor,
    rdma_handle queue_h,
    rdma_hw_image image,
    rdma_semantic_request request_snapshot,
    rdma_handle routed_qp_h = null
  );
    return make_pending(
      cursor, queue_h, RDMA_QUEUE_RUNTIME_SQ, 1'b1,
      0, image, request_snapshot, 1'b1,
      0, 1'b0, 1'b0, 1'b0, routed_qp_h);
  endfunction
endclass

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

  // 功能：check_consumer_local_stage_gates 构造 legacy runtime-only consumer
  //   pending，验证 no-allocation CI commit 与 WQE release marker 均经过显式 gate。
  //   这里的 MMIO_SUCCESS 是兼容路径的合成 evidence，不代表 0.1.34 CQC shadow
  //   写；真实驱动 shadow ABI 由 check_success_consumer_recovery_skips_mmio 覆盖。
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
    // 中文设计：该 focused task 不编码真实 CQC context shadow。保持
    // consumer_shadow_required=0，专门覆盖旧的 generic consumer-doorbell
    // runtime gate；任何 shadow offset/CI payload 断言都属于真实 fixture。
    pending.consumer_shadow_required = 1'b0;
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
    // 中文设计：SUCCESS 只描述 legacy runtime 的已完成 consumer marker；它
    // 不对应驱动 BAR 写，也不应被复用到 CQC shadow-backed fixture。
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

  // 功能：验证真实 CQ poll 在 CQC shadow 已发布、WQE release 一次性失败后留下
  //   consumer shadow pending；未确认 recovery 不推进，确认后只补 WQE release，
  //   不重发 shadow write、CQ CI 或 consumer doorbell。
  // 输入/输出及副作用：无显式参数；建立 ordering-fault fixture，执行真实
  //   post_send、publish_cqe、poll_cqe 与 public recover_queue，并观测 trace、公开
  //   detached pending、CQ/SQ occupancy、factory guard 与 CQE codec guard；成功最终
  //   各消费一份 CQE/WQE credit。
  // 失败/边界：setup/post/publish/poll 或 pending 查询失败即报告并返回；首次 poll
  //   必须在 shadow→commit 后只失败一次 release，未确认 retry 必须拒绝且零副作用，
  //   确认 retry 只能再调用一次 release，禁止重复 shadow write、CQ CI decrement、
  //   PCIe MMIO、codec lookup/decode、factory allocation 或 ledger 释放。
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
    int unsigned shadow_writes_before_poll;
    int unsigned shadow_writes_after_poll;
    int unsigned shadow_invocations_before_poll;
    int unsigned shadow_invocations_after_poll;
    int unsigned mmio_writes_before_poll;
    int unsigned mmio_writes_after_poll;
    int unsigned i;
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
    // 中文设计：0.1.34 驱动的 CQ consumer 只通过 CQC context shadow
    // offset +4 发布 CI/wrap；该 SUCCESS recovery 场景必须显式提供同一
    // authority，不能依赖已被生产路径移除的 CQ consumer MMIO fallback。
    fixture.setup(status, 16, RDMA_CQE_BYTES, 16, 16, 1'b1, 1'b0);
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

    shadow_writes_before_poll = ordering.shadow_write_calls;
    shadow_invocations_before_poll = ordering.shadow_invocation_calls;
    mmio_writes_before_poll = 0;
    foreach (fixture.pcie.calls[i]) begin
      if (fixture.pcie.calls[i] != null &&
          fixture.pcie.calls[i].method_name == "mmio_write")
        mmio_writes_before_poll++;
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
    if (ordering.trace.size() != 2 ||
        ordering.trace[0] != "commit" ||
        ordering.trace[1] != "release" ||
        ordering.doorbell_calls != 0 || ordering.commit_calls != 1 ||
        ordering.release_calls != 1)
      `uvm_error("SUCCESS_CONSUMER_INITIAL_ORDER", $sformatf(
        "trace=%p calls=%0d/%0d/%0d", ordering.trace,
        ordering.doorbell_calls, ordering.commit_calls, ordering.release_calls))

    pending = null;
    status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending);
    if (status == null || !status.ok() || pending == null ||
        pending.mmio_evidence != RDMA_QUEUE_MMIO_NO_SUBMIT ||
        !pending.consumer_shadow_required ||
        pending.consumer_shadow_urc ||
        !pending.consumer_shadow_attempted ||
        !pending.consumer_shadow_published ||
        pending.consumer_doorbell_succeeded || !pending.consumer_committed ||
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
    shadow_writes_after_poll = ordering.shadow_write_calls;
    shadow_invocations_after_poll = ordering.shadow_invocation_calls;
    mmio_writes_after_poll = 0;
    foreach (fixture.pcie.calls[i]) begin
      if (fixture.pcie.calls[i] != null &&
          fixture.pcie.calls[i].method_name == "mmio_write")
        mmio_writes_after_poll++;
    end
    if (shadow_writes_after_poll != shadow_writes_before_poll + 1 ||
        mmio_writes_after_poll != mmio_writes_before_poll)
      `uvm_error("SUCCESS_CONSUMER_SHADOW",
                 $sformatf("shadow writes=%0d->%0d mmio writes=%0d->%0d",
                   shadow_writes_before_poll, shadow_writes_after_poll,
                   mmio_writes_before_poll, mmio_writes_after_poll))

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
        ordering.doorbell_calls != 0 || ordering.commit_calls != 1 ||
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
        ordering.doorbell_calls != 0 || ordering.commit_calls != 1 ||
        ordering.release_calls != 2)
      `uvm_error("SUCCESS_CONSUMER_RELEASE_ONLY", $sformatf(
        "trace=%p calls=%0d/%0d/%0d", ordering.trace,
        ordering.doorbell_calls, ordering.commit_calls, ordering.release_calls))

    if (ordering.shadow_write_calls != shadow_writes_after_poll ||
        ordering.shadow_invocation_calls != shadow_invocations_after_poll)
      `uvm_error("SUCCESS_CONSUMER_SHADOW_RETRY", $sformatf(
        "shadow writes=%0d invocations=%0d attempts=%0d",
        ordering.shadow_write_calls, ordering.shadow_invocation_calls,
        ordering.shadow_calls))

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

  // 功能：check_pending_clone_fail_closed 为 request/image 的 null 与错误类型
  //   clone 各建立一笔 legacy SQ recovery，验证不完整 evidence 不会被 runtime
  //   接受为 RECOVERY_REQUIRED。
  // 输入/输出及副作用：label、request、image 为输入；每次调用创建独立 QP handle、
  //   cursor 和 ACTIVE host runtime，调用 probe.make_pending 与 runtime recovery/query
  //   API；不访问 Host-memory、PCIe 或 resource manager。
  // 失败/边界：pending 必须保持 null，enter_recovery 必须拒绝并保持 ACTIVE，query
  //   pending 必须为空；任何半成品 evidence、成功 recovery 或状态迁移都报告错误。
  task automatic check_pending_clone_fail_closed_case(
    string label,
    rdma_semantic_request request,
    rdma_hw_image image
  );
    rdma_queue_pending_clone_probe probe;
    rdma_queue_runtime runtime;
    rdma_handle queue_h;
    rdma_queue_cursor_snapshot cursor;
    rdma_queue_pending_operation pending;
    rdma_queue_pending_operation observed_pending;
    rdma_queue_runtime_state_e runtime_state;
    rdma_status status;

    probe = new({label, "_probe"});
    runtime = new({label, "_runtime"});
    queue_h = new({label, "_queue"});
    cursor = new({label, "_cursor"});
    if (probe == null || runtime == null || queue_h == null || cursor == null ||
        request == null || image == null) begin
      `uvm_error({label, "_SETUP"},
                 "pending clone fault fixture allocation failed")
      return;
    end
    queue_h.kind = RDMA_RESOURCE_QP;
    queue_h.function_uid = 64'hca11_0000_0000_0001;
    queue_h.object_id = 32'h71;
    queue_h.generation = 3;
    cursor.index = 0;
    cursor.wrap = 1'b0;
    status = runtime.configure(queue_h, RDMA_QUEUE_RUNTIME_SQ,
                               4, 0, 1'b0, 0, 1'b0, 1'b1);
    if (status == null || !status.ok()) begin
      `uvm_error({label, "_CONFIGURE"}, status == null ?
                 "runtime configure returned null" : status.convert2string())
      return;
    end
    status = runtime.activate();
    if (status == null || !status.ok()) begin
      `uvm_error({label, "_ACTIVATE"}, status == null ?
                 "runtime activate returned null" : status.convert2string())
      return;
    end

    pending = probe.build_pending(cursor, queue_h, image, request);
    if (pending != null)
      `uvm_error({label, "_PENDING"},
                 "clone/cast failure returned a partial pending evidence")

    status = runtime.enter_recovery(pending, 1'b0);
    if (status == null || status.ok())
      `uvm_error({label, "_ENTER"},
                 "runtime accepted incomplete pending evidence")

    status = runtime.query_state(runtime_state);
    if (status == null || !status.ok() ||
        runtime_state != RDMA_QUEUE_RUNTIME_ACTIVE)
      `uvm_error({label, "_STATE"},
                 "incomplete pending changed runtime state")

    observed_pending = null;
    status = runtime.query_pending(observed_pending);
    if (status == null || status.ok() || observed_pending != null)
      `uvm_error({label, "_QUERY"},
                 "incomplete pending became observable recovery evidence")
  endtask

  // 功能：check_pending_clone_fail_closed 运行 request/image 两个 nested value
  //   的 null/cast-failure 矩阵，确保 make_pending 的所有 clone 边界统一 fail closed。
  // 输入/输出及副作用：无显式输入；构造四组 hostile UVM value 并逐项调用上述
  //   case helper，所有 runtime 均为独立本地对象。
  // 失败/边界：任一矩阵项允许 partial pending 或 RECOVERY_REQUIRED 都通过 UVM_ERROR
  //   暴露；正常 clone 成功路径不在本 focused test 中代替失败覆盖。
  task automatic check_pending_clone_fail_closed();
    rdma_pending_clone_fault_request request_fault;
    rdma_pending_clone_fault_image image_fault;
    rdma_hw_image image;

    request_fault = new("pending_request_null_clone");
    image = new("pending_image_for_request_null");
    check_pending_clone_fail_closed_case(
      "PENDING_REQUEST_NULL_CLONE", request_fault, image);

    request_fault = new("pending_request_wrong_clone");
    request_fault.return_wrong_type = 1'b1;
    image = new("pending_image_for_request_wrong");
    check_pending_clone_fail_closed_case(
      "PENDING_REQUEST_WRONG_CLONE", request_fault, image);

    image_fault = new("pending_image_null_clone");
    request_fault = new("pending_request_for_image_null");
    image = image_fault;
    check_pending_clone_fail_closed_case(
      "PENDING_IMAGE_NULL_CLONE", request_fault, image);

    image_fault = new("pending_image_wrong_clone");
    image_fault.return_wrong_type = 1'b1;
    request_fault = new("pending_request_for_image_wrong");
    image = image_fault;
    check_pending_clone_fail_closed_case(
      "PENDING_IMAGE_WRONG_CLONE", request_fault, image);
  endtask

  // 功能：check_pending_shape_fail_closed 验证 make_pending 的非多态结构边界，
  //   覆盖空 cursor、通用 semantic request 以及 queue/route handle clone 失败。
  // 输入/输出及副作用：无显式输入；每个 case 只创建 detached fixture 对象并调用
  //   probe，不配置 runtime、Host-memory、PCIe 或 scheduler。
  // 失败/边界：cursor 缺失、request 不是 post-send/post-recv，或任一提供的 handle
  //   clone 返回 null/错误类型时，必须返回 null；任何半成品 pending 都报告错误。
  task automatic check_pending_shape_fail_closed();
    rdma_queue_pending_clone_probe probe;
    rdma_queue_cursor_snapshot cursor;
    rdma_hw_image image;
    rdma_post_send_req request;
    rdma_semantic_request generic_request;
    rdma_handle queue_h;
    rdma_pending_clone_fault_handle handle_fault;
    rdma_queue_pending_operation pending;

    probe = new("pending_shape_probe");
    cursor = new("pending_shape_cursor");
    image = new("pending_shape_image");
    request = new("pending_shape_request");
    queue_h = new("pending_shape_queue");
    if (probe == null || cursor == null || image == null || request == null ||
        queue_h == null) begin
      `uvm_error("PENDING_SHAPE_SETUP", "shape fixture allocation failed")
      return;
    end
    queue_h.kind = RDMA_RESOURCE_QP;

    pending = probe.build_pending(null, queue_h, image, request);
    if (pending != null)
      `uvm_error("PENDING_NULL_CURSOR", "null cursor produced pending evidence")

    generic_request = new("pending_generic_request");
    pending = probe.build_pending(cursor, queue_h, image, generic_request);
    if (pending != null)
      `uvm_error("PENDING_GENERIC_REQUEST", "generic request produced pending evidence")

    handle_fault = new("pending_queue_null_clone");
    pending = probe.build_pending(cursor, handle_fault, image, request);
    if (pending != null)
      `uvm_error("PENDING_QUEUE_NULL_CLONE",
                 "queue handle null clone produced pending evidence")

    handle_fault = new("pending_queue_wrong_clone");
    handle_fault.return_wrong_type = 1'b1;
    pending = probe.build_pending(cursor, handle_fault, image, request);
    if (pending != null)
      `uvm_error("PENDING_QUEUE_WRONG_CLONE",
                 "queue handle wrong clone produced pending evidence")

    handle_fault = new("pending_route_wrong_clone");
    handle_fault.return_wrong_type = 1'b1;
    pending = probe.build_pending(cursor, queue_h, image, request,
                                  handle_fault);
    if (pending != null)
      `uvm_error("PENDING_ROUTE_WRONG_CLONE",
                 "routed QP wrong clone produced pending evidence")
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
    check_pending_clone_fail_closed();
    check_pending_shape_fail_closed();
    phase.drop_objection(this);
  endtask
endclass
