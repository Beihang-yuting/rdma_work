// 目录：测试层 unit/rdma_queue_data_engine_device_publish_test.sv。
// 职责：验证 Task 5 的 CQE device-producer publish、真实 backing 写入和 poll
//   释放 WQE 的端到端契约。
// 依赖：依赖 rdma_queue_data_engine_fixture、mock Host-memory、CQE codec 与 UVM。
// 所有权与生命周期：测试只拥有本地 fixture；queue、mapping、runtime 和 Host-memory
//   都由 fixture 或其生命周期执行器管理，测试仅读取其已发布快照。

// 设计说明：CQ 的 allocation 必须完整满足 lifecycle 的 DEVICE_WRITE 契约，故
// 不能借由修改 allocation snapshot 伪造 publish 预检失败。engine 通过 factory
// 创建 backing-access；此 test-only 子类仅在 setup 完成后被静态开关命中的首次
// write_device 调用处返回权限拒绝，模拟 access 已完成 span 预检但尚未触及 backend。
class rdma_cq_device_write_preflight_fault_access extends rdma_queue_backing_access;
  `uvm_object_utils(rdma_cq_device_write_preflight_fault_access)

  // 设计说明：factory 创建的 CQ/SQ/RQ access 都是独立对象，测试须用共享的一次性
  // 开关精确命中 setup 后的 publish 调用，不能获取或修改 engine 私有 attachment。
  static bit reject_next_device_write;

  // 功能：构造 CQ device-write 预检故障 access，默认不拒绝调用，使 fixture
  //   setup、普通 post 和未显式 armed 的 publish 保持基类行为。
  // 输入/输出及副作用：name 为输入；构造不改变静态一次性开关、不申请 mapping，
  //   也不修改 runtime、Host-memory 或 lifecycle 对资源的所有权。
  // 失败边界：构造不验证 factory 或外部依赖；access 未经 configure/attach 时仍由
  //   基类接口拒绝，不能把该测试类当作绕过生产 lifecycle 校验的通道。
  function new(string name = "rdma_cq_device_write_preflight_fault_access");
    super.new(name);
  endfunction

  // 功能：write_device 在 armed 的首次设备发布预检处注入 DMA permission 拒绝，
  //   验证 engine 取消 reservation 而不向 Host-memory backend 发起 write。
  // 输入/输出及副作用：offset、data 为输入，backend_write_started 为输出；命中
  //   开关时清除一次性开关并保持输出为 0，未命中时完全委托基类实现。
  // 失败边界：仅 armed 的第一笔调用返回 RDMA_SC_DMA_PERMISSION；不访问 backing、
  //   不伪造已开始写入，后续调用恢复基类行为，避免泄露故障到其他测试事务。
  virtual function rdma_status write_device(
    longint unsigned offset,
    byte data[],
    output bit backend_write_started
  );
    if (reject_next_device_write) begin
      reject_next_device_write = 1'b0;
      backend_write_started = 1'b0;
      return rdma_status::make(RDMA_SC_DMA_PERMISSION,
                               "injected CQ device-write preflight failure");
    end
    return super.write_device(offset, data, backend_write_started);
  endfunction
endclass

class rdma_queue_data_engine_device_publish_test extends uvm_test;
  `uvm_component_utils(rdma_queue_data_engine_device_publish_test)

  // 功能：构造 UVM 测试组件，不预先绑定 queue-data fixture，保持每次 run 独立。
  // 输入/输出及副作用：name、parent 为输入；只建立组件层级，不申请 queue 或 mapping。
  // 失败边界：构造不校验依赖；fixture setup 失败时 run_phase 必须报告错误并释放 objection。
  function new(string name = "rdma_queue_data_engine_device_publish_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：clone_test_handle 手工复制 QP handle 的身份字段，避免测试辅助函数在
  //   clone/cast 注入故障时触发 fatal，使 CQE authority 错误可由 status 观察。
  // 输入/输出及副作用：source 为输入、copy 为输出；成功时分配 detached handle，
  //   不修改 source、fixture 或资源管理器。
  // 失败边界：source 为空或候选分配失败返回非成功 status，copy 保持 null。
  function automatic rdma_status clone_test_handle(
    rdma_handle source,
    output rdma_handle copy
  );
    rdma_handle candidate;

    copy = null;
    if (source == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "test handle source is null");
    candidate = rdma_handle::type_id::create("test_handle_copy");
    if (candidate == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "test handle allocation failed");
    candidate.kind = source.kind;
    candidate.function_uid = source.function_uid;
    candidate.object_id = source.object_id;
    candidate.generation = source.generation;
    copy = candidate;
    return rdma_status::success();
  endfunction

  // 功能：make_cqe_for_outstanding_send 仅利用 post_send 已发布的 slot/wr_id
  //   evidence 构造 CQE，验证 CQ poll 能精确释放对应 SQ WQE。
  // 输入/输出及副作用：qp_h、qpn、post_result、polarity 为输入，status 为输出；
  //   成功时返回新的 CQE model，不读取 CQ backing 或修改 post_result。
  // 失败边界：QP authority、post status 或对象分配不完整时返回 null，并保持
  //   非成功 status；绝不创建可被 publish 的半成品 model。
  function automatic rdma_hw_cqe_model make_cqe_for_outstanding_send(
    rdma_handle qp_h,
    int unsigned qpn,
    rdma_queue_post_result post_result,
    bit polarity,
    output rdma_status status
  );
    rdma_hw_cqe_model model;

    status = rdma_status::success();
    model = null;
    if (qp_h == null || qp_h.kind != RDMA_RESOURCE_QP ||
        post_result == null || post_result.status == null ||
        !post_result.status.ok()) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "posted send evidence is incomplete");
      return null;
    end
    model = rdma_hw_cqe_model::type_id::create("test_cqe");
    if (model == null) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "test CQE model allocation failed");
      return null;
    end
    status = clone_test_handle(qp_h, model.qp_h);
    if (status == null || !status.ok() || model.qp_h == null) begin
      if (status == null)
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "test CQE QP clone returned null status");
      model = null;
      return null;
    end
    model.wr_id = post_result.wr_id;
    model.opcode = RDMA_WR_SEND;
    model.status = rdma_status::success();
    model.qpn = qpn;
    model.wqe_index = post_result.index;
    model.wqe_wrap = post_result.wrap;
    model.rq_cqe = 1'b0;
    model.polarity = polarity;
    model.packet_opcode = 8'h01;
    model.ecode = 8'h00;
    model.payload_len = 32;
    model.immediate_data = 32'h0;
    model.signature = 8'h0;
    return model;
  endfunction

  // 功能：publish_cqe_for_test 只经公开 publish_cqe API 发起 CQE，防止测试
  //   绕过 reservation、device write/readback 或 commit pipeline。
  // 输入/输出及副作用：queue_data、cq_h、model 为输入，result/status 为输出；
  //   不修改 fixture、backing 或 model 的所有权。
  // 失败边界：queue_data 为空时返回 INVALID_ARGUMENT；其余拒绝由生产 API 原样发布。
  task automatic publish_cqe_for_test(
    rdma_queue_data_engine queue_data,
    rdma_handle cq_h,
    rdma_hw_cqe_model model,
    output rdma_queue_device_publish_result result,
    output rdma_status status
  );
    result = null;
    status = null;
    if (queue_data == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "queue-data engine is null");
      return;
    end
    queue_data.publish_cqe(cq_h, model, result, status);
  endtask

  // 功能：check_device_publish_calls 断言 publish 在 mock Host-memory 中先发起
  //   一次真实 write、再发起同槽位 readback，且两次都使用 CQ mapping。
  // 输入/输出及副作用：mem、start、offset、image 为输入；任务只报告
  //   调用序列和方向契约，不修改 mock 记录或 backing bytes。
  // 失败边界：调用数量不足、顺序/映射/偏移/大小不匹配，或 write/read 方向不是
  //   DEVICE_READ 时报告 UVM_ERROR；mock call.direction 表示 host_mem API 访问
  //   方向而非 backing permission，故还必须断言快照为 device_write=1/read=0。
  task automatic check_device_publish_calls(
    rdma_mock_host_mem mem,
    int unsigned start,
    longint unsigned offset,
    rdma_hw_image image
  );
    if (mem == null || image == null) begin
      `uvm_error("CQE_HOST_CALL", "Host-memory call evidence is incomplete")
      return;
    end
    if (mem.calls.size() < start + 2 || mem.calls[start] == null ||
        mem.calls[start + 1] == null) begin
      `uvm_error("CQE_HOST_CALL", "publish did not record write/readback")
      return;
    end
    if (mem.calls[start].method_name != "write" ||
        mem.calls[start + 1].method_name != "read" ||
        mem.calls[start].mapping == null || mem.calls[start + 1].mapping == null ||
        !mem.calls[start].mapping.permissions.device_write ||
        !mem.calls[start + 1].mapping.permissions.device_write ||
        mem.calls[start].mapping.permissions.device_read ||
        mem.calls[start + 1].mapping.permissions.device_read ||
        mem.calls[start].offset != offset ||
        mem.calls[start + 1].offset != offset ||
        mem.calls[start].size != image.bytes.size() ||
        mem.calls[start + 1].size != image.bytes.size() ||
        mem.calls[start].direction != RDMA_DMA_DEVICE_READ ||
        mem.calls[start + 1].direction != RDMA_DMA_DEVICE_READ)
      `uvm_error("CQE_HOST_CALL", "device publish Host-memory direction/order is wrong")
  endtask

  // 功能：check_device_publish_fault_recovery 对 backend write、read 与 readback
  //   mismatch 三类已开始设备写入故障执行 publish、查询 pending 和确认 retry。
  // 输入/输出及副作用：label、fault_kind 为输入；任务建立独立 fixture 并通过
  //   mock 注入单次故障，成功恢复后 poll CQE 释放该测试提前 post 的 SQ WQE。
  // 失败边界：fixture/post/model/注入、pending 证据、reservation、retry 或 poll
  //   任一不符合契约时报告 UVM_ERROR；已开始写入必须返回 RECOVERY_REQUIRED，
  //   不能发布 result 或悄悄清除 reservation。
  task automatic check_device_publish_fault_recovery(
    string label,
    int unsigned fault_kind
  );
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_post_result posted;
    rdma_queue_device_publish_result published;
    rdma_queue_completion_result completion;
    rdma_hw_cqe_model cqe;
    rdma_queue_pending_operation pending;
    rdma_queue_cursor_snapshot reservation;
    rdma_status status;
    rdma_status model_status;
    rdma_status injected;
    bit polarity;
    bit reservation_valid;
    bit occupancy_pending;
    int unsigned occupancy;

    fixture = rdma_queue_data_engine_fixture::type_id::create(
      {label, "_fixture"});
    fixture.setup(status);
    if (status == null || !status.ok()) begin
      `uvm_error({label, "_SETUP"}, "device publish fault fixture setup failed")
      return;
    end
    fixture.engine.post_send(fixture.make_send(64'hd500_0000 + fault_kind),
                             posted, status);
    if (status == null || !status.ok() || posted == null) begin
      `uvm_error({label, "_POST"}, "device publish fault setup post failed")
      return;
    end
    polarity = 1'b0;
    status = fixture.engine.query_runtime_producer_polarity(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, polarity);
    if (status == null || !status.ok()) begin
      `uvm_error({label, "_POLARITY"}, "device publish fault polarity query failed")
      return;
    end
    cqe = make_cqe_for_outstanding_send(fixture.qp.handle,
      fixture.qp.local_qp_id, posted, polarity, model_status);
    if (model_status == null || !model_status.ok() || cqe == null) begin
      `uvm_error({label, "_MODEL"}, "device publish fault CQE build failed")
      return;
    end
    case (fault_kind)
      0: begin
        injected = rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                     "injected device write failure");
        status = fixture.mem.fail_next("write", injected);
      end
      1: begin
        injected = rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                     "injected device read failure");
        status = fixture.mem.fail_next("read", injected);
      end
      2: begin
        fixture.mem.corrupt_next_readback = 1'b1;
        status = rdma_status::success();
      end
      default: status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                           "unknown device publish fault");
    endcase
    if (status == null || !status.ok()) begin
      `uvm_error({label, "_INJECT"}, "device publish fault injection failed")
      return;
    end
    published = null;
    publish_cqe_for_test(fixture.engine, fixture.cq.handle, cqe,
                         published, status);
    if (status == null || status.code != RDMA_SC_RECOVERY_REQUIRED ||
        published != null) begin
      `uvm_error({label, "_PUBLISH"},
                 "started device publish fault did not retain recovery")
      return;
    end
    pending = null;
    status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending);
    if (status == null || !status.ok() || pending == null ||
        !pending.device_producer || !pending.device_write_attempted ||
        pending.cursor == null || pending.next_cursor == null ||
        pending.image == null || pending.image.length != RDMA_CQE_BYTES ||
        pending.mmio_evidence != RDMA_QUEUE_MMIO_NOT_APPLICABLE) begin
      `uvm_error({label, "_PENDING"},
                 "started device publish fault lost replay evidence")
      return;
    end
    occupancy = 0;
    occupancy_pending = 1'b0;
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, occupancy, occupancy_pending);
    if (status == null || !status.ok() || occupancy != 0 ||
        !occupancy_pending)
      `uvm_error({label, "_OCCUPANCY"},
                 "failed device publish changed occupancy or hid pending")
    reservation_valid = 1'b0;
    reservation = null;
    status = fixture.engine.query_runtime_device_reservation(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, reservation_valid, reservation);
    if (status == null || !status.ok() || !reservation_valid ||
        reservation == null || reservation.index != pending.cursor.index ||
        reservation.wrap != pending.cursor.wrap) begin
      `uvm_error({label, "_RESERVATION"},
                 "failed device publish lost the reserved slot")
      return;
    end
    fixture.engine.recover_queue(fixture.cq.handle,
      RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1, status);
    if (status == null || !status.ok()) begin
      `uvm_error({label, "_RETRY"}, "device publish recovery retry failed")
      return;
    end
    occupancy = 0;
    occupancy_pending = 1'b1;
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, occupancy, occupancy_pending);
    if (status == null || !status.ok() || occupancy != 1 || occupancy_pending)
      `uvm_error({label, "_RETRY_OCCUPANCY"},
                 "device publish retry did not commit exactly one CQE")
    reservation_valid = 1'b1;
    reservation = null;
    status = fixture.engine.query_runtime_device_reservation(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, reservation_valid, reservation);
    if (status == null || !status.ok() || reservation_valid || reservation != null)
      `uvm_error({label, "_RETRY_RESERVATION"},
                 "device publish retry retained a committed reservation")
    completion = null;
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
    if (status == null || !status.ok() || completion == null ||
        completion.released_slots.size() != 1)
      `uvm_error({label, "_POLL"}, "recovered device CQE did not release WQE")
  endtask

  // 功能：check_device_publish_preflight_failure 在 attachment access 的首次
  //   write_device 预检处注入 DEVICE_WRITE 拒绝，验证 reservation 被 cancel 且
  //   backend write/commit 均不可观察。
  // 输入/输出及副作用：无显式输入；任务在 setup 前注册 factory override、在 setup
  //   后 arm 一次性 access 故障，随后只读取 publish、Host-memory 和 runtime 观测值。
  // 失败边界：factory 注入、publish 拒绝、调用数/游标/occupancy/pending/reservation
  //   检查任一不符时报告 UVM_ERROR；该 access 只模拟未开始 backend 的预检失败，
  //   不能替代 mapping 权限或 lifecycle allocation 的独立覆盖。
  task automatic check_device_publish_preflight_failure();
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_post_result posted;
    rdma_queue_device_publish_result published;
    rdma_hw_cqe_model cqe;
    rdma_queue_pending_operation pending;
    rdma_queue_cursor_snapshot reservation;
    rdma_status status;
    rdma_status model_status;
    bit polarity;
    bit reservation_valid;
    bit occupancy_pending;
    int unsigned occupancy;
    int unsigned calls_before;
    int unsigned producer_index;
    int unsigned consumer_index;
    bit producer_wrap;
    bit consumer_wrap;

    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "device_publish_preflight_fixture");
    rdma_queue_backing_access::type_id::set_type_override(
      rdma_cq_device_write_preflight_fault_access::get_type());
    rdma_cq_device_write_preflight_fault_access::reject_next_device_write =
      1'b0;
    fixture.setup(status);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_PREFLIGHT_SETUP", status == null ?
                 "preflight fixture setup returned null status" :
                 status.convert2string())
      return;
    end
    fixture.engine.post_send(fixture.make_send(64'hd510_0000), posted, status);
    if (status == null || !status.ok() || posted == null) begin
      `uvm_error("CQE_PREFLIGHT_POST", "preflight setup post failed")
      return;
    end
    status = fixture.engine.query_runtime_producer_polarity(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, polarity);
    cqe = make_cqe_for_outstanding_send(fixture.qp.handle,
      fixture.qp.local_qp_id, posted, polarity, model_status);
    if (status == null || !status.ok() || model_status == null ||
        !model_status.ok() || cqe == null) begin
      `uvm_error("CQE_PREFLIGHT_MODEL", "preflight CQE setup is incomplete")
      return;
    end
    status = fixture.engine.query_runtime_cursors(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, producer_index, producer_wrap,
      consumer_index, consumer_wrap);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_PREFLIGHT_CURSOR", "preflight cursor query failed")
      return;
    end
    calls_before = fixture.mem.calls.size();
    published = null;
    rdma_cq_device_write_preflight_fault_access::reject_next_device_write =
      1'b1;
    publish_cqe_for_test(fixture.engine, fixture.cq.handle, cqe,
                         published, status);
    rdma_cq_device_write_preflight_fault_access::reject_next_device_write =
      1'b0;
    if (status == null || status.code != RDMA_SC_DMA_PERMISSION ||
        published != null || fixture.mem.calls.size() != calls_before)
      `uvm_error("CQE_PREFLIGHT_PUBLISH",
                 "preflight failure entered backend or published a CQE")
    occupancy = 0;
    occupancy_pending = 1'b1;
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, occupancy, occupancy_pending);
    if (status == null || !status.ok() || occupancy != 0 || occupancy_pending)
      `uvm_error("CQE_PREFLIGHT_OCCUPANCY", "preflight failure changed occupancy")
    status = fixture.engine.query_runtime_cursors(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, occupancy, polarity,
      consumer_index, consumer_wrap);
    if (status == null || !status.ok() || occupancy != producer_index ||
        polarity != producer_wrap)
      `uvm_error("CQE_PREFLIGHT_CURSOR_AFTER", "preflight failure advanced PI")
    pending = null;
    status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending);
    if (status == null || status.ok() || pending != null ||
        status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("CQE_PREFLIGHT_PENDING", "preflight failure retained pending")
    reservation_valid = 1'b1;
    reservation = null;
    status = fixture.engine.query_runtime_device_reservation(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, reservation_valid, reservation);
    if (status == null || !status.ok() || reservation_valid || reservation != null)
      `uvm_error("CQE_PREFLIGHT_RESERVATION", "preflight failure retained reservation")
  endtask

  // 功能：check_device_publish_stale_route 拍平 attachment 的冻结 route/epoch 与
  //   binding 当前 epoch 不一致场景，验证 publish 在 reserve 前 fail-closed。
  // 输入/输出及副作用：无显式输入；任务先建立有效 CQE，再经 fixture 公开 API
  //   更新 binding reset epoch；只读取 Host-memory/runtime 观测值。
  // 失败边界：未返回 STALE_GENERATION、出现 backend 调用、occupancy/pending 或
  //   reservation 非空时报告 UVM_ERROR；该场景故意不恢复旧 binding。
  task automatic check_device_publish_stale_route();
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_post_result posted;
    rdma_queue_device_publish_result published;
    rdma_hw_cqe_model cqe;
    rdma_queue_pending_operation pending;
    rdma_queue_cursor_snapshot reservation;
    rdma_status status;
    rdma_status model_status;
    bit polarity;
    bit reservation_valid;
    bit occupancy_pending;
    int unsigned occupancy;
    int unsigned calls_before;

    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "device_publish_stale_route_fixture");
    fixture.setup(status);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_STALE_ROUTE_SETUP", "stale route fixture setup failed")
      return;
    end
    fixture.engine.post_send(fixture.make_send(64'hd520_0000), posted, status);
    if (status == null || !status.ok() || posted == null) begin
      `uvm_error("CQE_STALE_ROUTE_POST", "stale route setup post failed")
      return;
    end
    status = fixture.engine.query_runtime_producer_polarity(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, polarity);
    cqe = make_cqe_for_outstanding_send(fixture.qp.handle,
      fixture.qp.local_qp_id, posted, polarity, model_status);
    if (status == null || !status.ok() || model_status == null ||
        !model_status.ok() || cqe == null) begin
      `uvm_error("CQE_STALE_ROUTE_MODEL", "stale route CQE setup is incomplete")
      return;
    end
    calls_before = fixture.mem.calls.size();
    status = fixture.advance_binding_reset_epoch(1);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_STALE_ROUTE_INJECT", "stale route epoch injection failed")
      return;
    end
    published = null;
    publish_cqe_for_test(fixture.engine, fixture.cq.handle, cqe,
                         published, status);
    if (status == null || status.code != RDMA_SC_STALE_GENERATION ||
        published != null || fixture.mem.calls.size() != calls_before)
      `uvm_error("CQE_STALE_ROUTE_PUBLISH",
                 "stale route publish reserved or entered Host-memory")
    occupancy = 0;
    occupancy_pending = 1'b1;
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, occupancy, occupancy_pending);
    if (status == null || !status.ok() || occupancy != 0 || occupancy_pending)
      `uvm_error("CQE_STALE_ROUTE_OCCUPANCY", "stale route changed occupancy")
    pending = null;
    status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending);
    if (status == null || status.ok() || pending != null ||
        status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("CQE_STALE_ROUTE_PENDING", "stale route retained pending")
    reservation_valid = 1'b1;
    reservation = null;
    status = fixture.engine.query_runtime_device_reservation(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, reservation_valid, reservation);
    if (status == null || !status.ok() || reservation_valid || reservation != null)
      `uvm_error("CQE_STALE_ROUTE_RESERVATION", "stale route retained reservation")
  endtask

  // 功能：run_phase 依次 post_send、以 runtime 查询的 polarity publish CQE、读取
  //   真实 CQ backing，并两次 poll 验证 WQE release 和 occupancy 归零。
  // 输入/输出及副作用：phase 为输入；任务驱动 fixture 事务并报告 publish 前后
  //   occupancy/pending/cursor/image/Host-memory 证据，不直接写 CQ backing。
  // 失败边界：setup、post、polarity、publish、readback 或 poll 任一失败都会报告
  //   UVM_ERROR；第二次 poll 必须为 QUEUE_EMPTY 且 completion 为空。
  task run_phase(uvm_phase phase);
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_post_result posted;
    rdma_post_send_req request;
    rdma_hw_cqe_model cqe;
    rdma_queue_device_publish_result published;
    rdma_queue_completion_result completion;
    rdma_queue_pending_operation pending;
    rdma_status setup_status, status, model_status, poll_status;
    rdma_status pending_status, polarity_status;
    rdma_status occupancy_status;
    byte backing_bytes[];
    bit polarity;
    int unsigned pre_occupancy;
    int unsigned host_call_start;
    int unsigned pre_index;
    bit pre_wrap;
    int unsigned post_index;
    bit post_wrap;
    int unsigned consumer_index;
    bit consumer_wrap;
    bit occupancy_pending;
    longint unsigned backing_offset;

    phase.raise_objection(this);
    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "device_publish_fixture");
    fixture.setup(setup_status);
    if (setup_status == null || !setup_status.ok()) begin
      `uvm_error("CQE_FIXTURE", "fixture setup failed")
      phase.drop_objection(this);
      return;
    end
    pre_occupancy = 0;
    occupancy_pending = 1'b1;
    occupancy_status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pre_occupancy,
      occupancy_pending);
    if (occupancy_status == null || !occupancy_status.ok() ||
        pre_occupancy != 0 || occupancy_pending) begin
      `uvm_error("CQE_PRE_OCCUPANCY", "empty CQ occupancy is not zero")
      phase.drop_objection(this);
      return;
    end
    pre_index = 0;
    pre_wrap = 1'b0;
    consumer_index = 0;
    consumer_wrap = 1'b0;
    status = fixture.engine.query_runtime_cursors(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pre_index, pre_wrap,
      consumer_index, consumer_wrap);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_PRE_CURSOR", "runtime CQ cursor query failed")
      phase.drop_objection(this);
      return;
    end
    pending = null;
    pending_status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending);
    if (pending != null || pending_status == null || pending_status.ok() ||
        pending_status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("CQE_PRE_PENDING", "empty CQ unexpectedly has recovery pending")
    polarity = 1'b0;
    polarity_status = fixture.engine.query_runtime_producer_polarity(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, polarity);
    if (polarity_status == null || !polarity_status.ok()) begin
      `uvm_error("CQE_POLARITY", "runtime producer polarity query failed")
      phase.drop_objection(this);
      return;
    end
    request = fixture.make_send(64'h100);
    fixture.engine.post_send(request, posted, status);
    if (status == null || !status.ok() || posted == null) begin
      `uvm_error("CQE_POST", "send WQE post failed")
      phase.drop_objection(this);
      return;
    end
    cqe = make_cqe_for_outstanding_send(fixture.qp.handle,
      fixture.qp.local_qp_id, posted, polarity, model_status);
    if (model_status == null || !model_status.ok() || cqe == null) begin
      `uvm_error("CQE_MODEL", "CQE model construction failed")
      phase.drop_objection(this);
      return;
    end
    host_call_start = fixture.mem.calls.size();
    publish_cqe_for_test(fixture.engine, fixture.cq.handle, cqe,
                         published, status);
    if (status == null || !status.ok() || published == null ||
        published.status == null || !published.status.ok() ||
        published.queue_h == null ||
        !published.queue_h.same_instance(fixture.cq.handle) ||
        published.index != pre_index || published.wrap != pre_wrap ||
        published.image == null || !published.occupancy_valid ||
        published.occupancy != pre_occupancy + 1) begin
      `uvm_error("CQE_PUBLISH", "device CQE publish result/cursor/occupancy is wrong")
      phase.drop_objection(this);
      return;
    end
    occupancy_pending = 1'b1;
    occupancy_status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pre_occupancy,
      occupancy_pending);
    if (occupancy_status == null || !occupancy_status.ok() ||
        pre_occupancy != published.occupancy || occupancy_pending)
      `uvm_error("CQE_POST_OCCUPANCY", "runtime occupancy differs from publish result")
    post_index = 0;
    post_wrap = 1'b0;
    consumer_index = 0;
    consumer_wrap = 1'b0;
    status = fixture.engine.query_runtime_cursors(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, post_index, post_wrap,
      consumer_index, consumer_wrap);
    if (status == null || !status.ok() ||
        (post_index == pre_index && post_wrap == pre_wrap))
      `uvm_error("CQE_POST_CURSOR", "publish did not advance runtime producer cursor")
    backing_offset = longint'(published.index) *
      longint'(published.image.length);
    check_device_publish_calls(fixture.mem, host_call_start,
                               backing_offset, published.image);
    status = fixture.read_cq_entry(published.index, published.image.length,
                                   backing_bytes);
    if (status == null || !status.ok() ||
        backing_bytes.size() != published.image.bytes.size())
      `uvm_error("CQE_BACKING", "cannot read real CQ backing after publish")
    else foreach (backing_bytes[i]) begin
      if (backing_bytes[i] !== published.image.bytes[i])
        `uvm_error("CQE_BACKING", $sformatf("CQ backing byte %0d differs", i))
    end
    pending = null;
    pending_status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending);
    if (pending != null || pending_status == null || pending_status.ok() ||
        pending_status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("CQE_POST_PENDING", "committed CQE retained recovery pending")
    completion = null;
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, poll_status);
    if (poll_status == null || !poll_status.ok() || completion == null ||
        completion.released_slots.size() != 1)
      `uvm_error("CQE_CHAIN", "published CQE did not release one WQE")
    occupancy_pending = 1'b1;
    occupancy_status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pre_occupancy,
      occupancy_pending);
    if (occupancy_status == null || !occupancy_status.ok() ||
        pre_occupancy != 0 || occupancy_pending)
      `uvm_error("CQE_POLL_OCCUPANCY", "poll did not return CQ occupancy to zero")
    completion = null;
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, poll_status);
    if (poll_status == null || poll_status.code != RDMA_SC_QUEUE_EMPTY ||
        completion != null)
      `uvm_error("CQE_EMPTY", "second CQE poll did not prove occupancy is zero")
    check_device_publish_preflight_failure();
    check_device_publish_fault_recovery("CQE_WRITE_FAIL", 0);
    check_device_publish_fault_recovery("CQE_READ_FAIL", 1);
    check_device_publish_fault_recovery("CQE_READ_MISMATCH", 2);
    check_device_publish_stale_route();
    phase.drop_objection(this);
  endtask
endclass
