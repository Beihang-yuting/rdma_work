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

  // 功能：read_event_slot_bytes 读取 CEQ/AEQ 指定槽位的完整 16-byte raw image，供
  //   malformed 注入后恢复原始 entry，保持测试只观察 poll admission 而不伪造新事件。
  // 输入/输出及副作用：fixture、queue、role、index 为输入；data 为输出；函数只读取
  //   对应 ring mapping，不推进 producer/consumer cursor，也不改变 pending/MMIO 记录。
  // 失败/边界：fixture/queue/plan/index、role mapping、Host-memory capability 或长度
  //   不满足时返回非成功状态；CEQ/AEQ 以外 role、重复 mapping 和非 16-byte read 都拒绝。
  function automatic rdma_status read_event_slot_bytes(
    rdma_queue_data_engine_fixture fixture,
    rdma_queue_resource queue,
    rdma_queue_backing_role_e role,
    int unsigned index,
    output byte data[]
  );
    rdma_queue_backing_ref ring_ref;
    rdma_status status;

    data = new[0];
    ring_ref = null;
    if (fixture == null || fixture.mem == null || queue == null ||
        queue.queue_plan == null || index >= queue.depth)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "event slot read input is incomplete");
    foreach (queue.queue_plan.refs[i]) begin
      if (queue.queue_plan.refs[i] != null &&
          queue.queue_plan.refs[i].role == role) begin
        if (ring_ref != null)
          return rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "event slot read mapping is ambiguous");
        ring_ref = queue.queue_plan.refs[i];
      end
    end
    if (ring_ref == null || ring_ref.mapping == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "event slot read mapping is unavailable");
    status = fixture.mem.read(
      ring_ref.mapping,
      ring_ref.mapping_offset + longint'(index) * 16,
      16,
      data);
    if (status == null || !status.ok())
      return status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE, "event slot read returned null status") : status;
    if (data.size() != 16)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "event slot read size is invalid");
    return rdma_status::success();
  endfunction

  // 功能：write_event_slot_bytes 将测试准备好的完整 CEQ/AEQ raw image 写回指定槽位，
  //   用于在 malformed rejection 后恢复可解码 entry，再验证后续 retry 只提交一次。
  // 输入/输出及副作用：fixture、queue、role、index、data 为输入；函数只写对应 ring
  //   mapping，不直接修改 runtime cursor、ledger、pending 或 resource ownership。
  // 失败/边界：输入缺失、mapping 不唯一/不可用、data 非 16-byte 或 Host-memory write
  //   失败时返回原始错误；调用方不得把 partial write 当作可重试成功。
  function automatic rdma_status write_event_slot_bytes(
    rdma_queue_data_engine_fixture fixture,
    rdma_queue_resource queue,
    rdma_queue_backing_role_e role,
    int unsigned index,
    input byte data[]
  );
    rdma_queue_backing_ref ring_ref;

    ring_ref = null;
    if (fixture == null || fixture.mem == null || queue == null ||
        queue.queue_plan == null || index >= queue.depth || data.size() != 16)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "event slot write input is incomplete");
    foreach (queue.queue_plan.refs[i]) begin
      if (queue.queue_plan.refs[i] != null &&
          queue.queue_plan.refs[i].role == role) begin
        if (ring_ref != null)
          return rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "event slot write mapping is ambiguous");
        ring_ref = queue.queue_plan.refs[i];
      end
    end
    if (ring_ref == null || ring_ref.mapping == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "event slot write mapping is unavailable");
    return fixture.mem.write(
      ring_ref.mapping,
      ring_ref.mapping_offset + longint'(index) * 16,
      data);
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

  // 功能：check_malformed_aeqe_retry 注入 AEQE reserved bit，确认 AEQ malformed image
  //   在修复前不会推进 CI/doorbell；恢复原始 bytes 后仅产生一次 detached event 结果。
  // 输入/输出及副作用：fixture、aeq、event_qp 为输入，status 为输出；任务发布并保存
  //   一个合法 AEQE，执行失败尝试、raw 修复和成功 retry，仅读取 queue/runtime/MMIO 证据。
  // 失败/边界：任何 malformed 阶段 mutation、恢复写入失败、成功 retry 缺少 result 或
  //   occupancy/MMIO 非单次变化都返回 INVALID_STATE，不拥有 AEQ/QP/backing 生命周期。
  task automatic check_malformed_aeqe_retry(
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
    rdma_status raw_status;
    byte original[];
    byte malformed[];
    int unsigned producer_index;
    int unsigned consumer_index;
    int unsigned occupancy;
    int unsigned mmio_before;
    int unsigned mmio_after;
    int unsigned expected_index;
    bit producer_wrap;
    bit consumer_wrap;
    bit expected_wrap;
    bit pending;
    bit polarity;

    status = rdma_status::make(RDMA_SC_INVALID_STATE,
                               "malformed AEQE retry check is incomplete");
    if (fixture == null || fixture.engine == null || aeq == null ||
        event_qp == null)
      return;
    aeqe = rdma_hw_aeqe_model::type_id::create("malformed_retry_aeqe");
    if (aeqe == null) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "malformed AEQE model allocation failed");
      return;
    end
    model_status = clone_test_handle_value(event_qp.handle, aeqe.target_h);
    if (model_status == null || !model_status.ok() || aeqe.target_h == null) begin
      status = model_status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE, "malformed AEQE target clone failed") :
        model_status;
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
    raw_status = read_event_slot_bytes(
      fixture, aeq, RDMA_QUEUE_ROLE_AEQ_RING, published.index, original);
    if (raw_status == null || !raw_status.ok()) begin
      status = raw_status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE, "malformed AEQE original read returned null") :
        raw_status;
      return;
    end
    malformed = new[original.size()];
    foreach (original[i]) malformed[i] = original[i];
    // AEQE qword1[31:28] are reserved; byte 12 bit4 is the lowest reserved bit
    // in the big-endian 16-byte event image.
    malformed[12] |= 8'h10;
    status = write_event_slot_bytes(
      fixture, aeq, RDMA_QUEUE_ROLE_AEQ_RING, published.index, malformed);
    if (status == null || !status.ok()) return;
    status = fixture.engine.query_runtime_cursors(
      aeq.handle, RDMA_QUEUE_RUNTIME_AEQ,
      producer_index, producer_wrap, consumer_index, consumer_wrap);
    if (status == null || !status.ok()) return;
    expected_index = consumer_index;
    expected_wrap = consumer_wrap;
    status = fixture.engine.query_runtime_occupancy(
      aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, occupancy, pending);
    if (status == null || !status.ok() || occupancy != 1 || pending) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "malformed AEQE baseline is invalid");
      return;
    end
    mmio_before = mmio_write_count(fixture.pcie);
    event_result = null;
    poll_status = null;
    fixture.engine.poll_aeqe(aeq.handle, 0, event_result, poll_status);
    if (poll_status == null || poll_status.ok() ||
        poll_status.code != RDMA_SC_CODEC_ERROR || event_result != null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
        poll_status == null ? "malformed AEQE poll returned null status" :
        "malformed AEQE poll did not fail with codec error");
      return;
    end
    status = fixture.engine.query_runtime_cursors(
      aeq.handle, RDMA_QUEUE_RUNTIME_AEQ,
      producer_index, producer_wrap, consumer_index, consumer_wrap);
    if (status == null || !status.ok() || consumer_index != expected_index ||
        consumer_wrap != expected_wrap) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "malformed AEQE advanced consumer cursor");
      return;
    end
    status = fixture.engine.query_runtime_occupancy(
      aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, occupancy, pending);
    mmio_after = mmio_write_count(fixture.pcie);
    if (status == null || !status.ok() || occupancy != 1 || pending ||
        mmio_after != mmio_before) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "malformed AEQE created consumer side effect");
      return;
    end
    status = write_event_slot_bytes(
      fixture, aeq, RDMA_QUEUE_ROLE_AEQ_RING, published.index, original);
    if (status == null || !status.ok()) return;
    event_result = null;
    poll_status = null;
    fixture.engine.poll_aeqe(aeq.handle, 0, event_result, poll_status);
    if (poll_status == null || !poll_status.ok() || event_result == null) begin
      status = poll_status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE, "repaired AEQE retry returned null status") :
        poll_status;
      return;
    end
    status = fixture.engine.query_runtime_occupancy(
      aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, occupancy, pending);
    mmio_after = mmio_write_count(fixture.pcie);
    if (status == null || !status.ok() || occupancy != 0 || pending ||
        mmio_after != mmio_before + 1) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "repaired AEQE retry was not exactly once");
      return;
    end
    status = rdma_status::success();
  endtask

  // 功能：check_malformed_ceqe_retry 注入 CEQE reserved bit，确认 codec 失败不会提前
  //   ack；修复原 image 后再次 poll 必须恰好完成一次 CI/doorbell/occupancy 提交。
  // 输入/输出及副作用：fixture、ceq、cq 为输入，status 为输出；任务发布一个合法
  //   CEQE、保存 raw image、执行 malformed poll/retry 并读取 cursor/occupancy/MMIO 证据。
  // 失败/边界：malformed 阶段若改变 CI、used、pending 或 doorbell 即失败；恢复写入失败、
  //   第二次 poll 非成功或重复提交同样失败，任务不接管 queue/mapping/PCIe 所有权。
  task automatic check_malformed_ceqe_retry(
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
    rdma_status raw_status;
    byte original[];
    byte malformed[];
    int unsigned producer_index;
    int unsigned consumer_index;
    int unsigned occupancy;
    int unsigned mmio_before;
    int unsigned mmio_after;
    int unsigned expected_index;
    bit producer_wrap;
    bit consumer_wrap;
    bit expected_wrap;
    bit pending;
    bit polarity;

    status = rdma_status::make(RDMA_SC_INVALID_STATE,
                               "malformed CEQE retry check is incomplete");
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
        RDMA_SC_INVALID_STATE, "malformed CEQE model construction failed") :
        model_status;
      return;
    end
    fixture.engine.publish_ceqe(ceq.handle, ceqe, published, status);
    if (status == null || !status.ok() || published == null) return;
    raw_status = read_event_slot_bytes(
      fixture, ceq, RDMA_QUEUE_ROLE_CEQ_RING, published.index, original);
    if (raw_status == null || !raw_status.ok()) begin
      status = raw_status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE, "malformed CEQE original read returned null") :
        raw_status;
      return;
    end
    malformed = new[original.size()];
    foreach (original[i]) malformed[i] = original[i];
    malformed[8] |= 8'h80;
    status = write_event_slot_bytes(
      fixture, ceq, RDMA_QUEUE_ROLE_CEQ_RING, published.index, malformed);
    if (status == null || !status.ok()) return;
    status = fixture.engine.query_runtime_cursors(
      ceq.handle, RDMA_QUEUE_RUNTIME_CEQ,
      producer_index, producer_wrap, consumer_index, consumer_wrap);
    if (status == null || !status.ok()) return;
    expected_index = consumer_index;
    expected_wrap = consumer_wrap;
    status = fixture.engine.query_runtime_occupancy(
      ceq.handle, RDMA_QUEUE_RUNTIME_CEQ, occupancy, pending);
    if (status == null || !status.ok() || occupancy != 1 || pending) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "malformed CEQE baseline is invalid");
      return;
    end
    mmio_before = mmio_write_count(fixture.pcie);
    event_result = null;
    poll_status = null;
    fixture.engine.poll_ceqe(ceq.handle, 0, event_result, poll_status);
    if (poll_status == null || poll_status.ok() ||
        poll_status.code != RDMA_SC_CODEC_ERROR || event_result != null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
        poll_status == null ? "malformed CEQE poll returned null status" :
        "malformed CEQE poll did not fail with codec error");
      return;
    end
    status = fixture.engine.query_runtime_cursors(
      ceq.handle, RDMA_QUEUE_RUNTIME_CEQ,
      producer_index, producer_wrap, consumer_index, consumer_wrap);
    if (status == null || !status.ok() || consumer_index != expected_index ||
        consumer_wrap != expected_wrap) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "malformed CEQE advanced consumer cursor");
      return;
    end
    status = fixture.engine.query_runtime_occupancy(
      ceq.handle, RDMA_QUEUE_RUNTIME_CEQ, occupancy, pending);
    mmio_after = mmio_write_count(fixture.pcie);
    if (status == null || !status.ok() || occupancy != 1 || pending ||
        mmio_after != mmio_before) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "malformed CEQE created consumer side effect");
      return;
    end
    status = write_event_slot_bytes(
      fixture, ceq, RDMA_QUEUE_ROLE_CEQ_RING, published.index, original);
    if (status == null || !status.ok()) return;
    event_result = null;
    poll_status = null;
    fixture.engine.poll_ceqe(ceq.handle, 0, event_result, poll_status);
    if (poll_status == null || !poll_status.ok() || event_result == null) begin
      status = poll_status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE, "repaired CEQE retry returned null status") :
        poll_status;
      return;
    end
    status = fixture.engine.query_runtime_occupancy(
      ceq.handle, RDMA_QUEUE_RUNTIME_CEQ, occupancy, pending);
    mmio_after = mmio_write_count(fixture.pcie);
    if (status == null || !status.ok() || occupancy != 0 || pending ||
        mmio_after != mmio_before + 1) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "repaired CEQE retry was not exactly once");
      return;
    end
    status = rdma_status::success();
  endtask

  // 功能：check_event_doorbell_failure_recovery 在真实 CEQ/AEQ topology 上分别
  //   注入一次 consumer doorbell 的确定性 NO_SUBMIT 失败，随后通过公开
  //   recover_queue() 重放同一 pending，验证 doorbell、CI/occupancy 和 recovery
  //   completion 恰好各发生一次。
  // 输入/输出及副作用：任务内部建立 ordering-fault engine fixture，发布一条
  //   CEQE 与一条 AEQE，读取 runtime pending/cursor/occupancy 和 PCIe/trace 计数；
  //   失败注入只由测试子类消费，不修改生产资源的生命周期所有权。
  // 失败/边界：首次 poll 必须返回非 OK 且保留 NO_SUBMIT pending；retry 未确认时
  //   返回 INVALID_ARGUMENT，确认 retry 成功后第二次 recovery 必须返回
  //   INVALID_STATE 且不再发送 doorbell；任一阶段缺少 result、CI/occupancy 变化
  //   或重复提交均返回测试错误，所有部分资源最终交给统一 cleanup。
  task automatic check_event_doorbell_failure_recovery();
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_data_engine_ordering_fault ordering;
    rdma_ceq lifecycle_ceq;
    rdma_ceq wrong_ceq;
    rdma_aeq lifecycle_aeq;
    rdma_cq lifecycle_cq;
    rdma_qp event_qp;
    rdma_qp foreign_qp;
    rdma_hw_ceqe_model ceqe;
    rdma_hw_aeqe_model aeqe;
    rdma_queue_device_publish_result published;
    rdma_queue_event_result event_result;
    rdma_queue_pending_operation pending;
    rdma_status model_status;
    rdma_status status;
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
    bit polarity;
    int unsigned occupancy;
    int unsigned doorbell_before;
    int unsigned doorbell_after;
    bit has_pending;

    reset_device_publish_factory_state();
    rdma_queue_data_engine::type_id::set_type_override(
      rdma_queue_data_engine_ordering_fault::get_type(), 1'b1);
    setup_event_publish_topology(
      fixture, lifecycle_ceq, wrong_ceq, lifecycle_aeq, lifecycle_cq, event_qp,
      foreign_qp, lifecycle_ceq_created, lifecycle_ceq_attached,
      wrong_ceq_created, wrong_ceq_attached, lifecycle_aeq_created,
      lifecycle_aeq_attached, lifecycle_cq_created, lifecycle_cq_attached,
      event_qp_created, event_qp_attached, foreign_qp_created,
      foreign_qp_attached, status);
    if (status == null || !status.ok() || fixture == null ||
        !$cast(ordering, fixture.engine) || ordering == null) begin
      `uvm_error("EVENT_DB_RECOVERY_SETUP", status == null ?
                 "event doorbell recovery setup returned null" :
                 status.convert2string())
      cleanup_event_publish_topology(
        fixture, lifecycle_ceq, wrong_ceq, lifecycle_aeq, lifecycle_cq,
        event_qp, foreign_qp, lifecycle_ceq_created, lifecycle_ceq_attached,
        wrong_ceq_created, wrong_ceq_attached, lifecycle_aeq_created,
        lifecycle_aeq_attached, lifecycle_cq_created, lifecycle_cq_attached,
        event_qp_created, event_qp_attached, foreign_qp_created,
        foreign_qp_attached);
      reset_device_publish_factory_state();
      return;
    end

    status = fixture.engine.query_runtime_producer_polarity(
      lifecycle_ceq.handle, RDMA_QUEUE_RUNTIME_CEQ, polarity);
    make_ceqe_from_committed_cq(
      fixture.engine, lifecycle_cq.handle, lifecycle_cq.local_cq_id, 0,
      polarity, ceqe, model_status);
    if (status == null || !status.ok() || model_status == null ||
        !model_status.ok() || ceqe == null) begin
      `uvm_error("EVENT_DB_RECOVERY_CEQE_MODEL",
                 "CEQE recovery model construction failed")
    end
    else begin
      fixture.engine.publish_ceqe(
        lifecycle_ceq.handle, ceqe, published, status);
      if (status == null || !status.ok() || published == null) begin
        `uvm_error("EVENT_DB_RECOVERY_CEQE_PUBLISH",
                   "CEQE recovery publish failed")
      end
      else begin
        ordering.fail_doorbell_once = 1'b1;
        ordering.inject_ambiguous_doorbell = 1'b0;
        ordering.trace.delete();
        doorbell_before = ordering.doorbell_calls;
        event_result = null;
        fixture.engine.poll_ceqe(
          lifecycle_ceq.handle, 0, event_result, status);
        if (status == null || status.ok() || event_result != null ||
            ordering.doorbell_calls != doorbell_before + 1) begin
          `uvm_error("EVENT_DB_RECOVERY_CEQE_FAIL",
                     "CEQE doorbell failure did not retain pending")
        end
        status = fixture.engine.query_runtime_pending(
          lifecycle_ceq.handle, RDMA_QUEUE_RUNTIME_CEQ, pending);
        if (status == null || !status.ok() || pending == null ||
            pending.mmio_evidence != RDMA_QUEUE_MMIO_NO_SUBMIT) begin
          `uvm_error("EVENT_DB_RECOVERY_CEQE_PENDING",
                     "CEQE NO_SUBMIT evidence is incomplete")
        end
        status = fixture.engine.query_runtime_occupancy(
          lifecycle_ceq.handle, RDMA_QUEUE_RUNTIME_CEQ, occupancy, has_pending);
        if (status == null || !status.ok() || occupancy != 1 || !has_pending)
          `uvm_error("EVENT_DB_RECOVERY_CEQE_STATE",
                     "CEQE failure changed occupancy or pending state")
        fixture.engine.recover_queue(
          lifecycle_ceq.handle, RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b0,
          status);
        if (status == null || status.code != RDMA_SC_INVALID_ARGUMENT)
          `uvm_error("EVENT_DB_RECOVERY_CEQE_CONFIRM",
                     "unconfirmed CEQE retry was accepted")
        fixture.engine.recover_queue(
          lifecycle_ceq.handle, RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1,
          status);
        doorbell_after = ordering.doorbell_calls;
        if (status == null || !status.ok() ||
            doorbell_after != doorbell_before + 2)
          `uvm_error("EVENT_DB_RECOVERY_CEQE_RETRY",
                     "CEQE retry did not submit exactly once")
        status = fixture.engine.query_runtime_occupancy(
          lifecycle_ceq.handle, RDMA_QUEUE_RUNTIME_CEQ, occupancy, has_pending);
        if (status == null || !status.ok() || occupancy != 0 || has_pending)
          `uvm_error("EVENT_DB_RECOVERY_CEQE_COMMIT",
                     "CEQE retry did not complete consumer commit")
        fixture.engine.recover_queue(
          lifecycle_ceq.handle, RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1,
          status);
        if (status == null || status.code != RDMA_SC_INVALID_STATE ||
            ordering.doorbell_calls != doorbell_after)
          `uvm_error("EVENT_DB_RECOVERY_CEQE_ONCE",
                     "CEQE recovery was not exactly once")
      end
    end

    status = fixture.engine.query_runtime_producer_polarity(
      lifecycle_aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, polarity);
    aeqe = rdma_hw_aeqe_model::type_id::create("event_db_recovery_aeqe");
    if (status == null || !status.ok() || aeqe == null) begin
      `uvm_error("EVENT_DB_RECOVERY_AEQE_MODEL",
                 "AEQE recovery model construction failed")
    end
    else begin
      model_status = clone_test_handle_value(event_qp.handle, aeqe.target_h);
      aeqe.qpn = event_qp.local_qp_id;
      aeqe.valid = polarity;
      aeqe.ecode = 8'h00;
      aeqe.packet_opcode = 8'h00;
      if (model_status == null || !model_status.ok() || aeqe.target_h == null) begin
        `uvm_error("EVENT_DB_RECOVERY_AEQE_HANDLE",
                   "AEQE recovery target clone failed")
      end
      else begin
        fixture.engine.publish_aeqe(
          lifecycle_aeq.handle, aeqe, published, status);
        if (status == null || !status.ok() || published == null) begin
          `uvm_error("EVENT_DB_RECOVERY_AEQE_PUBLISH",
                     "AEQE recovery publish failed")
        end
        else begin
          ordering.fail_doorbell_once = 1'b1;
          ordering.inject_ambiguous_doorbell = 1'b0;
          event_result = null;
          doorbell_before = ordering.doorbell_calls;
          fixture.engine.poll_aeqe(
            lifecycle_aeq.handle, 0, event_result, status);
          status = fixture.engine.query_runtime_pending(
            lifecycle_aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, pending);
          if (status == null || !status.ok() || pending == null ||
              pending.mmio_evidence != RDMA_QUEUE_MMIO_NO_SUBMIT ||
              event_result != null || ordering.doorbell_calls != doorbell_before + 1)
            `uvm_error("EVENT_DB_RECOVERY_AEQE_FAIL",
                       "AEQE doorbell failure evidence is incomplete")
          fixture.engine.recover_queue(
            lifecycle_aeq.handle, RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1,
            status);
          doorbell_after = ordering.doorbell_calls;
          if (status == null || !status.ok() ||
              doorbell_after != doorbell_before + 2)
            `uvm_error("EVENT_DB_RECOVERY_AEQE_RETRY",
                       "AEQE retry did not submit exactly once")
          status = fixture.engine.query_runtime_occupancy(
            lifecycle_aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, occupancy, has_pending);
          if (status == null || !status.ok() || occupancy != 0 || has_pending)
            `uvm_error("EVENT_DB_RECOVERY_AEQE_COMMIT",
                       "AEQE retry did not complete consumer commit")
        end
      end
    end

    cleanup_event_publish_topology(
      fixture, lifecycle_ceq, wrong_ceq, lifecycle_aeq, lifecycle_cq,
      event_qp, foreign_qp, lifecycle_ceq_created, lifecycle_ceq_attached,
      wrong_ceq_created, wrong_ceq_attached, lifecycle_aeq_created,
      lifecycle_aeq_attached, lifecycle_cq_created, lifecycle_cq_attached,
      event_qp_created, event_qp_attached, foreign_qp_created,
      foreign_qp_attached);
    reset_device_publish_factory_state();
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
      check_malformed_ceqe_retry(fixture, lifecycle_ceq, lifecycle_cq, status);
      if (status == null || !status.ok())
        `uvm_error("EVENT_MALFORMED_CEQE", status == null ?
                   "malformed CEQE retry check returned null status" :
                   status.convert2string())
      check_malformed_aeqe_retry(fixture, lifecycle_aeq, event_qp, status);
      if (status == null || !status.ok())
        `uvm_error("EVENT_MALFORMED_AEQE", status == null ?
                   "malformed AEQE retry check returned null status" :
                   status.convert2string())
    end
    check_event_doorbell_failure_recovery();
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
