// 目录：测试层 unit/rdma_queue_data_engine_device_publish_test.sv。
// 职责：验证 Task 5 的 CQE device-producer publish、真实 backing 写入和 poll
//   释放 WQE 的端到端契约。
// 依赖：依赖 rdma_queue_data_engine_fixture、mock Host-memory、CQE codec 与 UVM。
// 所有权与生命周期：测试只拥有本地 fixture；queue、mapping、runtime 和 Host-memory
//   都由 fixture 或其生命周期执行器管理，测试仅读取其已发布快照。

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

  // 功能：find_cq_backing 返回 fixture 生命周期已创建的 CQ ring backing，用于
  //   只读验证 publish 写入的真实 bytes 与 Host-memory 调用 authority。
  // 输入/输出及副作用：fixture 为输入、backing 为输出；只遍历 queue plan，不改变
  //   mapping、permissions 或 runtime cursor。
  // 失败边界：fixture、CQ、ring ref 或 mapping 缺失时返回 INVALID_STATE 且 backing=null。
  function automatic rdma_status find_cq_backing(
    rdma_queue_data_engine_fixture fixture,
    output rdma_queue_backing_ref backing
  );
    backing = null;
    if (fixture == null || fixture.cq == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "fixture CQ is unavailable");
    foreach (fixture.cq.queue_plan.refs[i]) begin
      if (fixture.cq.queue_plan.refs[i] != null &&
          fixture.cq.queue_plan.refs[i].role == RDMA_QUEUE_ROLE_CQ_RING)
        backing = fixture.cq.queue_plan.refs[i];
    end
    if (backing == null || backing.mapping == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "fixture CQ backing is missing");
    return rdma_status::success();
  endfunction

  // 功能：check_device_publish_calls 断言 publish 在 mock Host-memory 中先发起
  //   一次真实 write、再发起同槽位 readback，且两次都使用 CQ mapping。
  // 输入/输出及副作用：mem、start、backing、offset、image 为输入；任务只报告
  //   调用序列和方向契约，不修改 mock 记录或 backing bytes。
  // 失败边界：调用数量不足、顺序/映射/偏移/大小不匹配，或 write/read 方向不是
  //   DEVICE_READ 时报告 UVM_ERROR；mock call.direction 表示 host_mem API 访问
  //   方向而非 backing permission，故还必须断言快照为 device_write=1/read=0。
  task automatic check_device_publish_calls(
    rdma_mock_host_mem mem,
    int unsigned start,
    rdma_queue_backing_ref backing,
    longint unsigned offset,
    rdma_hw_image image
  );
    if (mem == null || backing == null || backing.mapping == null ||
        image == null) begin
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
        mem.calls[start].mapping.iova.value != backing.mapping.iova.value ||
        mem.calls[start + 1].mapping.iova.value != backing.mapping.iova.value ||
        mem.calls[start].mapping.size != backing.mapping.size ||
        mem.calls[start + 1].mapping.size != backing.mapping.size ||
        mem.calls[start].mapping.reset_epoch != backing.mapping.reset_epoch ||
        mem.calls[start + 1].mapping.reset_epoch != backing.mapping.reset_epoch ||
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
    rdma_queue_backing_ref backing;
    rdma_status setup_status, status, model_status, poll_status;
    rdma_status pending_status, polarity_status, backing_status;
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
    backing_status = find_cq_backing(fixture, backing);
    if (backing_status == null || !backing_status.ok()) begin
      `uvm_error("CQE_BACKING", "fixture CQ backing lookup failed")
      phase.drop_objection(this);
      return;
    end
    // DEVICE_WRITE 与 readback 都不依赖 device_read；若 publish 错用了 posting
    // ring 的方向权限，此处将被 backing-access preflight 拒绝。
    backing.mapping.permissions.device_read = 1'b0;
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
    if (pending != null || (pending_status != null && pending_status.ok()))
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
    backing_offset = backing.mapping_offset +
      longint'(published.index) * longint'(published.image.length);
    check_device_publish_calls(fixture.mem, host_call_start, backing,
                               backing_offset, published.image);
    status = fixture.mem.read(backing.mapping, backing_offset,
                              published.image.length, backing_bytes);
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
    if (pending != null || (pending_status != null && pending_status.ok()))
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
    phase.drop_objection(this);
  endtask
endclass
