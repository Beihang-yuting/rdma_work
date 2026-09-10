// 目录：测试层 unit/rdma_queue_data_engine_poll_test.sv。
// 职责：验证 queue-data 的 CQE poll、WQE release 与 CQ consumer cursor 契约；
//   正向 CQE 必须通过公开 device-producer publish 流程进入 committed occupancy。
// 依赖：依赖 rdma_queue_data_engine_fixture、CQE model、UVM 与已注册的 codec。
// 所有权与生命周期：测试只拥有本地 fixture 引用；queue、runtime、mapping 与
//   Host-memory 均由 fixture/lifecycle 管理，测试不直接写入正向 CQ backing。

class rdma_queue_data_engine_poll_test extends uvm_test;
  `uvm_component_utils(rdma_queue_data_engine_poll_test)

  // 功能：构造 poll 测试组件，仅建立 UVM 层级，等待 run_phase 创建独立 fixture。
  // 输入/输出及副作用：name、parent 为输入；不申请 queue、runtime、mapping 或 mock 资源。
  // 失败/边界：构造不校验依赖；fixture setup 失败时 run_phase 必须报告错误并释放 objection。
  function new(string name = "rdma_queue_data_engine_poll_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：clone_test_handle 手工复制 QP identity，避免测试辅助逻辑的 clone/cast
  //   故障触发 fatal，保证 publish_cqe 能以普通 status 报告 authority 失败。
  // 输入/输出及副作用：source 为输入、copy 为输出；成功时创建 detached handle，
  //   不修改 fixture、资源管理器或 source。
  // 失败边界：source 为空或分配失败时返回非成功 status，copy 保持 null。
  function automatic rdma_status clone_test_handle(
    rdma_handle source,
    output rdma_handle copy
  );
    rdma_handle candidate;

    copy = null;
    if (source == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "poll test handle source is null");
    candidate = rdma_handle::type_id::create("poll_test_handle_copy");
    if (candidate == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "poll test handle allocation failed");
    candidate.kind = source.kind;
    candidate.function_uid = source.function_uid;
    candidate.object_id = source.object_id;
    candidate.generation = source.generation;
    copy = candidate;
    return rdma_status::success();
  endfunction

  // 功能：make_cqe_for_outstanding_send 以已 post 的 SQ slot/wr_id 与 runtime
  //   polarity 构造可由公开 publish_cqe 提交并由 poll 精确释放的 CQE model。
  // 输入/输出及副作用：qp_h、qpn、posted、polarity 为输入，status 为输出；成功时
  //   返回 detached model，不读取或直接写入 CQ backing，也不修改 posted。
  // 失败边界：QP、post status 或对象分配不完整时返回 null/非成功 status，不产生
  //   可提交的半成品 CQE。
  function automatic rdma_hw_cqe_model make_cqe_for_outstanding_send(
    rdma_handle qp_h,
    int unsigned qpn,
    rdma_queue_post_result posted,
    bit polarity,
    output rdma_status status
  );
    rdma_hw_cqe_model model;

    status = rdma_status::success();
    model = null;
    if (qp_h == null || qp_h.kind != RDMA_RESOURCE_QP || posted == null ||
        posted.status == null || !posted.status.ok()) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "poll test posted-send evidence is incomplete");
      return null;
    end
    model = rdma_hw_cqe_model::type_id::create("poll_test_cqe");
    if (model == null) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "poll test CQE allocation failed");
      return null;
    end
    status = clone_test_handle(qp_h, model.qp_h);
    if (status == null || !status.ok() || model.qp_h == null) begin
      if (status == null)
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "poll test CQE QP clone returned null status");
      model = null;
      return null;
    end
    model.wr_id = posted.wr_id;
    model.opcode = RDMA_WR_SEND;
    model.qpn = qpn;
    model.wqe_index = posted.index;
    model.wqe_wrap = posted.wrap;
    model.rq_cqe = 1'b0;
    model.polarity = polarity;
    model.packet_opcode = 8'h01;
    model.ecode = RDMA_CMQ_SUCCESS_ECODE;
    model.payload_len = 32;
    model.immediate_data = 32'h0;
    model.signature = 8'h0;
    model.status = rdma_status::success();
    return model;
  endfunction

  // 功能：run_phase 验证未配置拒绝、post→public publish_cqe→poll 的 WQE release，
  //   以及 consumer commit 后 CQ 为空的可观察结果。
  // 输入/输出及副作用：phase 为输入；任务创建 fixture、调用公开 API 并报告断言，
  //   不直接写入正向 CQ backing，最终聚合释放 fixture-owned lifecycle 资源。
  // 失败边界：setup、post、polarity、CQE 构造、publish 或 poll 失败时停止后续正向
  //   事务并释放 objection；第二次 poll 只能返回 QUEUE_EMPTY。
  task run_phase(uvm_phase phase);
    rdma_queue_data_engine engine;
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_completion_result completion;
    rdma_queue_post_result posted;
    rdma_queue_event_result event_result;
    rdma_status status;
    rdma_post_send_req send_request;
    rdma_hw_cqe_model cqe;
    rdma_status cqe_status;
    rdma_status cleanup_status;
    rdma_queue_device_publish_result publish_result;
    int unsigned occupancy;
    bit pending;
    bit polarity;

    phase.raise_objection(this);
    engine = rdma_queue_data_engine::type_id::create("unconfigured_engine");
    completion = rdma_queue_completion_result::type_id::create("sentinel_cqe");
    status = null;
    engine.poll_cqe(null, 0, completion, status);
    if (status == null || status.ok() || completion != null)
      `uvm_error("POLL_UNCONFIGURED",
                 "poll_cqe published output while unconfigured")

    event_result = rdma_queue_event_result::type_id::create("sentinel_ceqe");
    status = null;
    engine.poll_ceqe(null, 0, event_result, status);
    if (status == null || status.ok() || event_result != null)
      `uvm_error("POLL_CEQ_UNCONFIGURED",
                 "poll_ceqe published output while unconfigured")

    event_result = rdma_queue_event_result::type_id::create("sentinel_aeqe");
    status = null;
    engine.poll_aeqe(null, 0, event_result, status);
    if (status == null || status.ok() || event_result != null)
      `uvm_error("POLL_AEQ_UNCONFIGURED",
                 "poll_aeqe published output while unconfigured")

    fixture = rdma_queue_data_engine_fixture::type_id::create("poll_fixture");
    // 中文设计：所有正向阶段通过 named flow 退出到同一 cleanup epilogue；
    // 任一 setup/publish/poll 失败都不能用早退跳过 lifecycle-owned 资源释放。
    begin : poll_flow
      if (fixture == null) begin
        `uvm_error("FIXTURE_FACTORY", "poll fixture allocation failed")
        disable poll_flow;
      end
      fixture.setup(status);
      if (status == null || !status.ok()) begin
        `uvm_error("FIXTURE_SETUP", status == null ? "null setup status" :
                   status.convert2string())
        disable poll_flow;
      end

      send_request = fixture.make_send(64'h1111_2222_3333_4444);
      fixture.engine.post_send(send_request, posted, status);
      if (status == null || !status.ok() || posted == null) begin
        `uvm_error("POLL_SETUP_POST", status == null ? "null status" :
                   status.convert2string())
        disable poll_flow;
      end

      polarity = 1'b0;
      cqe_status = fixture.engine.query_runtime_producer_polarity(
        fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, polarity);
      if (cqe_status == null || !cqe_status.ok()) begin
        `uvm_error("POLL_SETUP_POLARITY", cqe_status == null ? "null status" :
                   cqe_status.convert2string())
        disable poll_flow;
      end
      cqe = make_cqe_for_outstanding_send(fixture.qp.handle,
        fixture.qp.local_qp_id, posted, polarity, cqe_status);
      if (cqe_status == null || !cqe_status.ok() || cqe == null) begin
        `uvm_error("POLL_SETUP_CQE", cqe_status == null ? "null status" :
                   cqe_status.convert2string())
        disable poll_flow;
      end
      publish_result = null;
      fixture.engine.publish_cqe(fixture.cq.handle, cqe, publish_result, status);
      if (status == null || !status.ok() || publish_result == null ||
          publish_result.status == null || !publish_result.status.ok() ||
          !publish_result.occupancy_valid || publish_result.occupancy != 1) begin
        `uvm_error("POLL_SETUP_PUBLISH", status == null ? "null status" :
                   status.convert2string())
        disable poll_flow;
      end
      occupancy = 0;
      pending = 1'b1;
      status = fixture.engine.query_runtime_occupancy(
        fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, occupancy, pending);
      if (status == null || !status.ok() || occupancy != 1 || pending) begin
        `uvm_error("POLL_SETUP_OCCUPANCY", status == null ? "null status" :
                   status.convert2string())
        disable poll_flow;
      end

      completion = null;
      fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
      // 设计说明：该断言覆盖 read/decode/route/CI-doorbell/ledger-release 完整
      // 事务，确保 poll 在执行 match_and_release 后再检查 released_slots。
      if (status == null || !status.ok() || completion == null ||
          completion.cqe == null ||
          completion.cqe.qpn != fixture.qp.local_qp_id ||
          completion.cqe.wr_id != send_request.wr_id ||
          completion.completion_status == null ||
          !completion.completion_status.ok())
        `uvm_error("POLL_CQE", status == null ? "null status" :
                   status.convert2string())
      if (fixture.cq.queue_plan == null ||
          fixture.cq.queue_plan.context_ref == null)
        `uvm_error("POLL_CQE_CONTEXT", "CQ fixture lost lifecycle backing")
      occupancy = 1;
      pending = 1'b1;
      status = fixture.engine.query_runtime_occupancy(
        fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, occupancy, pending);
      if (status == null || !status.ok() || occupancy != 0 || pending)
        `uvm_error("POLL_CQE_CREDIT",
                   "poll-one did not restore CQ occupancy to zero")

      // 设计说明：CI commit 必须推进 CQ runtime。backing 中旧字节仍存在；若 CI
      // 未推进，第二次 poll 会重复消费同一 CQE，而不会观察到下一空槽。
      completion = null;
      fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
      if (status == null || status.code != RDMA_SC_QUEUE_EMPTY ||
          completion != null)
        `uvm_error("POLL_CQE_CI", status == null ? "null status" :
                   status.convert2string())
    end

    if (fixture != null && fixture.needs_cleanup()) begin
      fixture.cleanup(cleanup_status);
      if (cleanup_status == null || !cleanup_status.ok())
        `uvm_error("POLL_CLEANUP", cleanup_status == null ?
                   "fixture cleanup returned null" : cleanup_status.convert2string())
    end

    phase.drop_objection(this);
  endtask
endclass
