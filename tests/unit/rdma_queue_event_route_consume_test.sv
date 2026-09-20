// 目录：测试层 unit/rdma_queue_event_route_consume_test.sv。
// 职责：验证合法 CEQE/AEQE image 在 CQN/QPN route 已过期或未知时仍按驱动
//   语义消费 ring entry：丢弃 payload、推进 CI 并发送 consumer doorbell。
// 依赖：依赖 rdma_queue_data_engine_device_publish_test 提供的 lifecycle fixture、
//   event topology helper、codec 与 UVM；只通过 mock Host-memory 改写已发布槽位。
// 所有权与生命周期：测试拥有本地 fixture 和 detached model；queue、mapping、
//   runtime、PCIe 与资源 executor 仍由 fixture/cleanup helper 管理，不接管外部资源。

// 设计说明：真实驱动在 event.c 中先判断 wire valid/polarity；image 合法后即使
// CQN/QPN 找不到对应对象，也会走 update_*_ci 并写 consumer doorbell。测试因此
// 先使用公开 device-publish API 产生合法 entry，再只改写 wire route 字段，避免
// 把 publish 侧严格 route 校验与 poll 侧 stale-route 处置混为一谈。
class rdma_queue_event_route_consume_test
    extends rdma_queue_data_engine_device_publish_test;
  `uvm_component_utils(rdma_queue_event_route_consume_test)

  // 功能：构造 route-consume 测试组件，复用父类的 UVM 层级与 factory seam。
  // 输入/输出及副作用：name、parent 为输入；只调用 super.new，不创建 queue、
  //   backing、runtime 或 PCIe 事务。
  // 失败/边界：构造不验证外部依赖；run_phase 必须在 topology setup 失败时仍执行
  //   已发布资源的统一 cleanup。
  function new(string name = "rdma_queue_event_route_consume_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：rewrite_event_route_field 在已经提交的 16-byte CEQ/AEQ backing slot
  //   中改写唯一的 CQN 或 QPN wire field，构造合法 image 的 stale/unknown route。
  // 输入/输出及副作用：fixture、queue、role、index、aeq_field、new_id 为输入；
  //   读取并重新写入对应 ring mapping 的一个 slot，不推进 runtime PI/CI、used、
  //   pending 或 doorbell ledger。
  // 失败/边界：queue plan、ring mapping、slot 范围或 Host-memory read/write 失败时
  //   返回原始错误；函数只允许 CEQ/AEQ ring role，不能改写 CQ/WQ 或伪造 publish。
  function automatic rdma_status rewrite_event_route_field(
    rdma_queue_data_engine_fixture fixture,
    rdma_queue_resource queue,
    rdma_queue_backing_role_e role,
    int unsigned index,
    bit aeq_field,
    longint unsigned new_id
  );
    rdma_queue_backing_ref ring_ref;
    byte data[];
    longint unsigned qword;
    rdma_status status;

    ring_ref = null;
    data = new[0];
    if (fixture == null || fixture.mem == null || queue == null ||
        queue.queue_plan == null || index >= queue.depth)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "event route rewrite input is incomplete");

    foreach (queue.queue_plan.refs[i]) begin
      if (queue.queue_plan.refs[i] != null &&
          queue.queue_plan.refs[i].role == role) begin
        if (ring_ref != null)
          return rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "event ring mapping is ambiguous");
        ring_ref = queue.queue_plan.refs[i];
      end
    end
    if (ring_ref == null || ring_ref.mapping == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "event ring mapping is unavailable");

    status = fixture.mem.read(
      ring_ref.mapping,
      ring_ref.mapping_offset + longint'(index) * 16,
      16,
      data
    );
    if (status == null || !status.ok())
      return status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE, "event route rewrite read returned null status") :
        status;
    if (data.size() != 16)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "event route rewrite read size is invalid");

    qword = '0;
    for (int unsigned i = 0; i < 8; i++)
      qword = (qword << 8) | data[i];
    if (aeq_field)
      qword[17:0] = new_id[17:0];
    else
      qword[36:16] = new_id[20:0];
    // CQN/QPN 位于 qword0；qword1 携带 CEQE/AEQE 的其他合法字段，不能在
    // 改写 route 时被清零，否则 valid/polarity 或 URC overlay 会被测试自身破坏。
    for (int unsigned i = 0; i < 8; i++)
      data[i] = qword >> (56 - 8 * i);

    return fixture.mem.write(
      ring_ref.mapping,
      ring_ref.mapping_offset + longint'(index) * 16,
      data
    );
  endfunction

  // 功能：mmio_write_count 返回 mock PCIe 中已经记录的 consumer doorbell 数量，
  //   用于区分“只丢弃 payload”与“真正完成 CI/doorbell 消费”。
  // 输入/输出及副作用：pcie 为输入；只读取 calls 和 method_name，不修改 PCIe
  //   trace、runtime 或 scheduler 状态。
  // 失败/边界：pcie 为空时返回零；未知 call 类型不会计入，调用方必须同时检查
  //   poll status 和 runtime cursor，不能单独把计数当作提交证明。
  function automatic int unsigned mmio_write_count(rdma_mock_pcie pcie);
    int unsigned count;

    count = 0;
    if (pcie == null)
      return count;
    foreach (pcie.calls[i]) begin
      if (pcie.calls[i] != null &&
          pcie.calls[i].method_name == "mmio_write")
        count++;
    end
    return count;
  endfunction

  // 功能：check_stale_ceqe_route 先发布合法 CEQE，再把 CQN 改为不存在的 local
  //   ID，验证 poll 丢弃事件 payload 但仍完成 CEQ CI/doorbell。
  // 输入/输出及副作用：fixture、CEQ/CQ 为输入，status 为输出；读取公开 cursor/
  //   occupancy、改写一个已提交槽位并调用 poll_ceqe，不修改资源所有权。
  // 失败/边界：合法 publish、raw route 改写、poll、CI/occupancy/pending 或 MMIO
  //   证据任一不符均返回 INVALID_STATE；route miss 不得返回 INVALID_STATE 或留下
  //   recovery pending。
  task automatic check_stale_ceqe_route(
    rdma_queue_data_engine_fixture fixture,
    rdma_ceq ceq,
    rdma_cq cq,
    output rdma_status status
  );
    rdma_hw_ceqe_model ceqe;
    rdma_queue_device_publish_result published;
    rdma_queue_event_result event_result;
    rdma_status model_status;
    rdma_status poll_status;
    int unsigned producer_index;
    int unsigned consumer_index;
    int unsigned occupancy;
    int unsigned mmio_before;
    int unsigned mmio_after;
    bit producer_wrap;
    bit consumer_wrap;
    bit expected_wrap;
    int unsigned expected_index;
    bit pending;
    bit polarity;

    status = rdma_status::make(RDMA_SC_INVALID_STATE,
                               "stale CEQE route check is incomplete");
    if (fixture == null || fixture.engine == null || ceq == null || cq == null)
      return;

    status = fixture.engine.query_runtime_producer_polarity(
      ceq.handle, RDMA_QUEUE_RUNTIME_CEQ, polarity);
    if (status == null || !status.ok()) return;
    make_ceqe_from_committed_cq(
      fixture.engine, cq.handle, cq.local_cq_id, 0, polarity, ceqe,
      model_status);
    if (model_status == null || !model_status.ok() || ceqe == null) begin
      status = model_status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE, "stale CEQE model construction failed") :
        model_status;
      return;
    end
    fixture.engine.publish_ceqe(ceq.handle, ceqe, published, status);
    if (status == null || !status.ok() || published == null) return;

    status = fixture.engine.query_runtime_cursors(
      ceq.handle, RDMA_QUEUE_RUNTIME_CEQ,
      producer_index, producer_wrap, consumer_index, consumer_wrap);
    if (status == null || !status.ok()) return;
    status = fixture.engine.query_runtime_occupancy(
      ceq.handle, RDMA_QUEUE_RUNTIME_CEQ, occupancy, pending);
    if (status == null || !status.ok() || occupancy != 1 || pending) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "CEQ baseline occupancy is invalid");
      return;
    end
    expected_index = consumer_index + 1 >= ceq.depth ? 0 : consumer_index + 1;
    expected_wrap = consumer_index + 1 >= ceq.depth ? !consumer_wrap : consumer_wrap;
    mmio_before = mmio_write_count(fixture.pcie);

    status = rewrite_event_route_field(
      fixture, ceq, RDMA_QUEUE_ROLE_CEQ_RING, published.index, 1'b0,
      21'h1f_ffff);
    if (status == null || !status.ok()) return;

    event_result = null;
    poll_status = null;
    fixture.engine.poll_ceqe(ceq.handle, 0, event_result, poll_status);
    if (poll_status == null || !poll_status.ok() || event_result != null) begin
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        poll_status == null ?
          "stale CEQE route poll returned null status" :
          {"stale CEQE route poll failed: ", poll_status.convert2string()});
      return;
    end
    status = fixture.engine.query_runtime_cursors(
      ceq.handle, RDMA_QUEUE_RUNTIME_CEQ,
      producer_index, producer_wrap, consumer_index, consumer_wrap);
    if (status == null || !status.ok() || consumer_index != expected_index ||
        consumer_wrap != expected_wrap) begin
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE, "stale CEQE route did not advance CI");
      return;
    end
    status = fixture.engine.query_runtime_occupancy(
      ceq.handle, RDMA_QUEUE_RUNTIME_CEQ, occupancy, pending);
    mmio_after = mmio_write_count(fixture.pcie);
    if (status == null || !status.ok() || occupancy != 0 || pending ||
        mmio_after != mmio_before + 1) begin
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "stale CEQE route did not complete consumer transaction");
      return;
    end
    status = rdma_status::success();
  endtask

  // 功能：check_stale_aeqe_route 先发布合法 AEQE，再把 QPN 改为不存在的 local
  //   ID，验证 poll 丢弃异步事件 payload 但仍完成 AEQ CI/doorbell。
  // 输入/输出及副作用：fixture、AEQ、event_qp 为输入，status 为输出；读取公开
  //   cursor/occupancy、改写一个已提交槽位并调用 poll_aeqe，不取得 QP 所有权。
  // 失败/边界：合法 publish、raw route 改写、poll、CI/occupancy/pending 或 MMIO
  //   证据任一不符均返回 INVALID_STATE；route miss 不得卡住 AEQ ring。
  task automatic check_stale_aeqe_route(
    rdma_queue_data_engine_fixture fixture,
    rdma_aeq aeq,
    rdma_qp event_qp,
    output rdma_status status
  );
    rdma_hw_aeqe_model aeqe;
    rdma_queue_device_publish_result published;
    rdma_queue_event_result event_result;
    rdma_status model_status;
    rdma_status poll_status;
    int unsigned producer_index;
    int unsigned consumer_index;
    int unsigned occupancy;
    int unsigned mmio_before;
    int unsigned mmio_after;
    bit producer_wrap;
    bit consumer_wrap;
    bit expected_wrap;
    int unsigned expected_index;
    bit pending;
    bit polarity;

    status = rdma_status::make(RDMA_SC_INVALID_STATE,
                               "stale AEQE route check is incomplete");
    if (fixture == null || fixture.engine == null || aeq == null ||
        event_qp == null)
      return;

    aeqe = rdma_hw_aeqe_model::type_id::create("stale_route_aeqe");
    if (aeqe == null) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "stale AEQE model allocation failed");
      return;
    end
    model_status = clone_test_handle_value(event_qp.handle, aeqe.target_h);
    if (model_status == null || !model_status.ok() || aeqe.target_h == null) begin
      status = model_status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE, "stale AEQE target clone failed") : model_status;
      return;
    end
    status = fixture.engine.query_runtime_producer_polarity(
      aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, polarity);
    if (status == null || !status.ok()) return;
    aeqe.qpn = event_qp.local_qp_id;
    aeqe.qp_state = 3'd4;
    aeqe.ecode = 8'h00;
    aeqe.packet_opcode = 8'h00;
    aeqe.valid = polarity;
    fixture.engine.publish_aeqe(aeq.handle, aeqe, published, status);
    if (status == null || !status.ok() || published == null) return;

    status = fixture.engine.query_runtime_cursors(
      aeq.handle, RDMA_QUEUE_RUNTIME_AEQ,
      producer_index, producer_wrap, consumer_index, consumer_wrap);
    if (status == null || !status.ok()) return;
    status = fixture.engine.query_runtime_occupancy(
      aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, occupancy, pending);
    if (status == null || !status.ok() || occupancy != 1 || pending) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "AEQ baseline occupancy is invalid");
      return;
    end
    expected_index = consumer_index + 1 >= aeq.depth ? 0 : consumer_index + 1;
    expected_wrap = consumer_index + 1 >= aeq.depth ? !consumer_wrap : consumer_wrap;
    mmio_before = mmio_write_count(fixture.pcie);

    status = rewrite_event_route_field(
      fixture, aeq, RDMA_QUEUE_ROLE_AEQ_RING, published.index, 1'b1,
      18'h3ffff);
    if (status == null || !status.ok()) return;

    event_result = null;
    poll_status = null;
    fixture.engine.poll_aeqe(aeq.handle, 0, event_result, poll_status);
    if (poll_status == null || !poll_status.ok() || event_result != null) begin
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        poll_status == null ?
          "stale AEQE route poll returned null status" :
          {"stale AEQE route poll failed: ", poll_status.convert2string()});
      return;
    end
    status = fixture.engine.query_runtime_cursors(
      aeq.handle, RDMA_QUEUE_RUNTIME_AEQ,
      producer_index, producer_wrap, consumer_index, consumer_wrap);
    if (status == null || !status.ok() || consumer_index != expected_index ||
        consumer_wrap != expected_wrap) begin
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE, "stale AEQE route did not advance CI");
      return;
    end
    status = fixture.engine.query_runtime_occupancy(
      aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, occupancy, pending);
    mmio_after = mmio_write_count(fixture.pcie);
    if (status == null || !status.ok() || occupancy != 0 || pending ||
        mmio_after != mmio_before + 1) begin
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "stale AEQE route did not complete consumer transaction");
      return;
    end
    status = rdma_status::success();
  endtask

  // 功能：run_phase 建立共享 event topology，分别执行 CEQ/AEQ stale-route
  //   契约测试，并在任何阶段后按父类顺序释放所有 lifecycle-owned 资源。
  // 输入/输出及副作用：phase 为 UVM 输入；任务通过 status/UVM_ERROR 暴露断言，
  //   只改写测试 backing，不修改生产资源所有权。
  // 失败/边界：setup 失败时跳过消费测试但仍 cleanup；任一 route test 失败不跳过
  //   另一类事件，cleanup 错误以独立 UVM_ERROR 报告。
  task run_phase(uvm_phase phase);
    rdma_queue_data_engine_fixture fixture;
    rdma_ceq lifecycle_ceq;
    rdma_ceq wrong_ceq;
    rdma_aeq lifecycle_aeq;
    rdma_cq lifecycle_cq;
    rdma_qp event_qp;
    rdma_qp foreign_qp;
    rdma_status status;
    rdma_status cleanup_status;
    bit lifecycle_ceq_created;
    bit lifecycle_ceq_attached;
    bit wrong_ceq_created;
    bit wrong_ceq_attached;
    bit lifecycle_aeq_created;
    bit lifecycle_aeq_attached;
    bit lifecycle_cq_created;
    bit lifecycle_cq_attached;
    bit event_qp_created;
    bit event_qp_attached;
    bit foreign_qp_created;
    bit foreign_qp_attached;

    phase.raise_objection(this);
    setup_event_publish_topology(
      fixture, lifecycle_ceq, wrong_ceq, lifecycle_aeq, lifecycle_cq, event_qp,
      foreign_qp, lifecycle_ceq_created, lifecycle_ceq_attached,
      wrong_ceq_created, wrong_ceq_attached, lifecycle_aeq_created,
      lifecycle_aeq_attached, lifecycle_cq_created, lifecycle_cq_attached,
      event_qp_created, event_qp_attached, foreign_qp_created,
      foreign_qp_attached, status);
    if (status == null || !status.ok()) begin
      `uvm_error("EVENT_ROUTE_SETUP", status == null ?
                 "event topology setup returned null status" :
                 status.convert2string())
    end
    else begin
      check_stale_ceqe_route(fixture, lifecycle_ceq, lifecycle_cq, status);
      if (status == null || !status.ok())
        `uvm_error("EVENT_ROUTE_CEQE", status == null ?
                   "stale CEQE route check returned null status" :
                   status.convert2string())
      check_stale_aeqe_route(fixture, lifecycle_aeq, event_qp, status);
      if (status == null || !status.ok())
        `uvm_error("EVENT_ROUTE_AEQE", status == null ?
                   "stale AEQE route check returned null status" :
                   status.convert2string())
    end
    cleanup_event_publish_topology(
      fixture, lifecycle_ceq, wrong_ceq, lifecycle_aeq, lifecycle_cq, event_qp,
      foreign_qp, lifecycle_ceq_created, lifecycle_ceq_attached,
      wrong_ceq_created, wrong_ceq_attached, lifecycle_aeq_created,
      lifecycle_aeq_attached, lifecycle_cq_created, lifecycle_cq_attached,
      event_qp_created, event_qp_attached, foreign_qp_created,
      foreign_qp_attached);
    reset_device_publish_factory_state();
    cleanup_tracked_fixtures(cleanup_status);
    if (cleanup_status == null || !cleanup_status.ok())
      `uvm_error("EVENT_ROUTE_CLEANUP", cleanup_status == null ?
                 "event route fixture cleanup returned null status" :
                 cleanup_status.convert2string())
    phase.drop_objection(this);
  endtask
endclass
