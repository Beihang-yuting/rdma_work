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
  // 失败/边界：source 为空或分配失败时返回非成功 status，copy 保持 null。
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
  // 失败/边界：QP、post status 或对象分配不完整时返回 null/非成功 status，不产生
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

  // 功能：make_cqe_for_outstanding_receive 根据已 post 的私有 RQ slot、QP route
  //   和 CQ producer polarity 构造显式 RQ/SRFQ variant 的 receive CQE，供公开
  //   publish_cqe→poll_cqe 正向链验证 RQ ledger release。
  // 输入/输出及副作用：qp_h、qpn、posted、polarity 为输入；status 为输出；成功
  //   返回携带 detached QP handle、RQ_CQE、WQE index/wrap、RQ overlay 和成功 ecode
  //   的 CQE model，不读取/写入 CQ backing，也不修改 posted 或 runtime。
  // 失败/边界：QP/posted/status evidence 缺失、clone/factory 分配失败时返回 null
  //   与非成功 status；模型必须保留 non-null status、RQ/SRFQ variant 和合法 qpn，
  //   调用方不得把半成品送入 publish_cqe。
  function automatic rdma_hw_cqe_model make_cqe_for_outstanding_receive(
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
      status = rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "poll test posted-receive evidence is incomplete");
      return null;
    end
    model = rdma_hw_cqe_model::type_id::create("poll_test_receive_cqe");
    if (model == null) begin
      status = rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "poll test receive CQE allocation failed");
      return null;
    end
    status = clone_test_handle(qp_h, model.qp_h);
    if (status == null || !status.ok() || model.qp_h == null) begin
      if (status == null)
        status = rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "poll test receive CQE QP clone returned null status");
      model = null;
      return null;
    end
    model.wr_id = posted.wr_id;
    model.opcode = RDMA_WR_RECV;
    model.qpn = qpn;
    model.wqe_index = posted.index;
    model.wqe_wrap = posted.wrap;
    model.rq_cqe = 1'b1;
    model.srfq = 1'b0;
    model.variant = RDMA_CQE_VARIANT_RQ_SRFQ;
    model.polarity = polarity;
    model.packet_opcode = 8'h01;
    model.ecode = RDMA_CMQ_SUCCESS_ECODE;
    model.payload_len = 32;
    model.immediate_data = 32'h0;
    model.signature = 8'h0;
    model.rqe_cpl = 1'b1;
    model.srfqn = 12'h0;
    model.srfqe_wrap = 1'b0;
    model.srfqe_index = 15'h0;
    model.status = rdma_status::success();
    return model;
  endfunction

  // 功能：make_cqe_for_outstanding_ud_send 根据已 post 的 UD SQ slot、UD QP
  //   route 和 CQ producer polarity 构造显式 UD variant 的 send CQE，供公开
  //   publish_cqe→poll_cqe 链验证 UD qword2/qword3 overlay 与 SQ ledger release。
  // 输入/输出及副作用：qp_h、qpn、posted、polarity 为输入；status 为输出；成功
  //   返回携带 detached QP handle、SQ WQE index/wrap、UD source QPN、SMAC/VLAN
  //   overlay 和成功 ecode 的 CQE model，不读取/写入 CQ backing，也不修改 posted
  //   或 runtime。
  // 失败/边界：QP/posted/status evidence 缺失、clone/factory 分配失败时返回 null
  //   与非成功 status；model 必须保留 non-null status、UD variant 和合法 qpn，
  //   调用方不得把半成品送入 publish_cqe。
  function automatic rdma_hw_cqe_model make_cqe_for_outstanding_ud_send(
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
      status = rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "poll test posted UD send evidence is incomplete");
      return null;
    end
    model = rdma_hw_cqe_model::type_id::create("poll_test_ud_send_cqe");
    if (model == null) begin
      status = rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "poll test UD send CQE allocation failed");
      return null;
    end
    status = clone_test_handle(qp_h, model.qp_h);
    if (status == null || !status.ok() || model.qp_h == null) begin
      if (status == null)
        status = rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "poll test UD send CQE QP clone returned null status");
      model = null;
      return null;
    end
    model.wr_id = posted.wr_id;
    model.opcode = RDMA_WR_SEND;
    model.qpn = qpn;
    model.wqe_index = posted.index;
    model.wqe_wrap = posted.wrap;
    model.rq_cqe = 1'b0;
    model.srfq = 1'b0;
    model.variant = RDMA_CQE_VARIANT_UD;
    model.polarity = polarity;
    model.packet_opcode = 8'h01;
    model.ecode = RDMA_CMQ_SUCCESS_ECODE;
    model.payload_len = 0;
    model.immediate_data = 32'h0;
    model.signature = 8'h0;
    model.ud_src_qpn = 24'h654321;
    model.ud_smac = 48'h0011_2233_4455;
    model.ud_vlan_tag = 16'h7788;
    model.status = rdma_status::success();
    return model;
  endfunction

  // 功能：check_cq_poll_wq_attachment_validator 驱动 test-only probe 验证 CQ→WQ
  //   validator 的正常 contract、depth/entry-size/role hostile 变形和 stale
  //   incarnation 拒绝，并验证 staged attachment 的 canonical relookup 与 pending
  //   kind 漂移拒绝，确认所有 WQ authority 门禁在 admission 前可独立审查。
  // 输入/输出及副作用：无显式输入输出；任务创建并清理一个 probe fixture，读取
  //   validator status 并报告断言，不提交 CQE、不推进 runtime cursor、不写 Host-memory
  //   或 MMIO。probe 在每次断言后恢复临时 attachment 字段，fixture 仍由自身 cleanup
  //   持有 queue、runtime、mapping 与 backing 所有权。
  // 失败/边界：fixture/probe setup、cast 或 cleanup 失败均报告 UVM_ERROR；validator
  //   正常 case 必须返回 OK，fault_kind 1/2/3 必须返回 INVALID_STATE，fault_kind 4
  //   必须返回 STALE_GENERATION；canonicalization fault 0..5 必须回查成功且 1..5
  //   标记 relookup，fault_kind 6 必须返回 INVALID_STATE；任一状态不符不会跳过
  //   后续 case 或生命周期清理。
  task automatic check_cq_poll_wq_attachment_validator();
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_data_engine_probe probe;
    rdma_status setup_status;
    rdma_status validator_status;
    rdma_status canonical_status;
    rdma_status cleanup_status;
    int unsigned fault_kind;
    rdma_status_code_e expected_code;
    bit used_canonical_relookup;

    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "poll_validator_fixture");
    begin : validator_flow
      if (fixture == null) begin
        `uvm_error("POLL_VALIDATOR_FIXTURE",
                   "CQ poll validator fixture allocation failed")
        disable validator_flow;
      end
      fixture.setup(setup_status, 16, RDMA_CQE_BYTES, 16, 16,
                    1'b0, 1'b0, 1'b1);
      if (setup_status == null || !setup_status.ok()) begin
        `uvm_error("POLL_VALIDATOR_SETUP",
                   setup_status == null ? "null setup status" :
                   setup_status.convert2string())
        disable validator_flow;
      end
      if (!$cast(probe, fixture.engine) || probe == null) begin
        `uvm_error("POLL_VALIDATOR_CAST",
                   "fixture did not create queue-data probe")
        disable validator_flow;
      end
      for (fault_kind = 0; fault_kind < 5; fault_kind++) begin
        expected_code = fault_kind == 0 ? RDMA_SC_OK :
                        (fault_kind == 4 ? RDMA_SC_STALE_GENERATION :
                                           RDMA_SC_INVALID_STATE);
        validator_status = probe.probe_validate_cq_poll_wq_attachment_fixture(
          fixture.qp.handle, fault_kind);
        if (validator_status == null ||
            validator_status.code != expected_code) begin
          `uvm_error("POLL_VALIDATOR_CASE",
                     $sformatf("fault_kind=%0d expected=%0d got=%s",
                               fault_kind, expected_code,
                               validator_status == null ? "null" :
                               validator_status.convert2string()))
        end
      end
      // 中文设计：canonicalization fixture 把 staging 可能携带的错误引用与
      // engine-owned registry 分离；fault 1..5 必须回查到同一 canonical SQ，
      // fault 6 则在任何 lookup/副作用之前拒绝 pending kind 漂移。
      for (fault_kind = 0; fault_kind < 7; fault_kind++) begin
        used_canonical_relookup = 1'b0;
        canonical_status =
          probe.probe_canonicalize_cq_poll_wq_attachment_fixture(
            fixture.qp.handle, fault_kind, used_canonical_relookup);
        expected_code = fault_kind == 6 ? RDMA_SC_INVALID_STATE : RDMA_SC_OK;
        if (canonical_status == null ||
            canonical_status.code != expected_code ||
            ((fault_kind inside {1, 2, 3, 4, 5}) &&
             !used_canonical_relookup) ||
            ((fault_kind inside {0, 6}) && used_canonical_relookup)) begin
          `uvm_error("POLL_CANONICALIZATION_CASE",
                     $sformatf("fault_kind=%0d expected=%0d relookup=%0b got=%s",
                               fault_kind, expected_code,
                               used_canonical_relookup,
                               canonical_status == null ? "null" :
                               canonical_status.convert2string()))
        end
      end
    end
    if (fixture != null && fixture.needs_cleanup()) begin
      fixture.cleanup(cleanup_status);
      if (cleanup_status == null || !cleanup_status.ok())
        `uvm_error("POLL_VALIDATOR_CLEANUP",
                   cleanup_status == null ? "null cleanup status" :
                   cleanup_status.convert2string())
    end
  endtask

  // 功能：check_private_rq_receive_cqe_e2e 通过独立 lifecycle fixture 执行
  //   post_recv→公开 publish_cqe(rq_cqe=1)→poll_cqe 的完整私有 RQ 正向事务，
  //   确认 CQ consumer commit 只释放目标 RQ ledger，而不误碰 SQ。
  // 输入/输出及副作用：无显式参数；任务创建拥有 CQ context shadow 的 fixture，
  //   发布真实 RQE/CQE、读取 runtime occupancy/cursor 和 detached completion，
  //   最后由 fixture cleanup 释放全部 queue、QP、CQ、PD 与 Function 资源。
  // 失败/边界：setup、post、polarity、CQE 构造、publish、poll、cursor/occupancy
  //   查询或第二次空轮询任一步失败均报告 UVM_ERROR；result 保持 null 的失败链
  //   不得被当作完成，cleanup 无论中途哪一阶段失败都必须继续执行。
  task automatic check_private_rq_receive_cqe_e2e();
    rdma_queue_data_engine_fixture fixture;
    rdma_post_recv_req request;
    rdma_queue_post_result posted;
    rdma_hw_cqe_model cqe;
    rdma_queue_device_publish_result published;
    rdma_queue_completion_result completion;
    rdma_status setup_status;
    rdma_status status;
    rdma_status cqe_status;
    rdma_status cleanup_status;
    int unsigned used;
    int unsigned producer_index;
    int unsigned consumer_index;
    bit pending;
    bit producer_wrap;
    bit consumer_wrap;
    bit polarity;

    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "private_rq_receive_cqe_fixture");
    begin : private_rq_receive_cqe_flow
      if (fixture == null) begin
        `uvm_error("PRIVATE_RQ_CQE_FIXTURE",
                   "private RQ receive CQE fixture allocation failed")
        disable private_rq_receive_cqe_flow;
      end

      // CQ poll 的 CI/wrap 必须走 fixture context shadow；未注入 shadow 的
      // fixture 会在 occupancy/read 前按生产 contract 返回 UNSUPPORTED_OPCODE。
      fixture.setup(setup_status, 16, RDMA_CQE_BYTES, 16, 16,
                    1'b1, 1'b0, 1'b0);
      if (setup_status == null || !setup_status.ok()) begin
        `uvm_error("PRIVATE_RQ_CQE_SETUP",
                   setup_status == null ? "null setup status" :
                   setup_status.convert2string())
        disable private_rq_receive_cqe_flow;
      end

      request = fixture.make_recv(64'hbabe_cafe_0000_1300);
      posted = null;
      fixture.engine.post_recv(request, posted, status);
      if (status == null || !status.ok() || posted == null ||
          posted.status == null || !posted.status.ok() || posted.index != 0 ||
          posted.wrap != 1'b0 || posted.image == null ||
          posted.image.bytes.size() != RDMA_WQE_BYTES) begin
        `uvm_error("PRIVATE_RQ_CQE_POST",
                   status == null ? "null post-receive status" :
                   status.convert2string())
        disable private_rq_receive_cqe_flow;
      end

      used = 0;
      pending = 1'b1;
      status = fixture.engine.query_runtime_occupancy(
        fixture.qp.handle, RDMA_QUEUE_RUNTIME_RQ, used, pending);
      if (status == null || !status.ok() || used != 1 || pending) begin
        `uvm_error("PRIVATE_RQ_CQE_POST_CREDIT",
                   status == null ? "null RQ occupancy status" :
                   status.convert2string())
        disable private_rq_receive_cqe_flow;
      end

      polarity = 1'b0;
      cqe_status = fixture.engine.query_runtime_producer_polarity(
        fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, polarity);
      if (cqe_status == null || !cqe_status.ok()) begin
        `uvm_error("PRIVATE_RQ_CQE_POLARITY",
                   cqe_status == null ? "null CQ polarity status" :
                   cqe_status.convert2string())
        disable private_rq_receive_cqe_flow;
      end
      cqe = make_cqe_for_outstanding_receive(
        fixture.qp.handle, fixture.qp.local_qp_id, posted, polarity,
        cqe_status);
      if (cqe_status == null || !cqe_status.ok() || cqe == null) begin
        `uvm_error("PRIVATE_RQ_CQE_MODEL",
                   cqe_status == null ? "null receive CQE status" :
                   cqe_status.convert2string())
        disable private_rq_receive_cqe_flow;
      end

      published = null;
      fixture.engine.publish_cqe(fixture.cq.handle, cqe, published, status);
      if (status == null || !status.ok() || published == null ||
          published.status == null || !published.status.ok() ||
          published.index != 0 || published.wrap != 1'b0 ||
          !published.occupancy_valid || published.occupancy != 1 ||
          published.image == null ||
          published.image.bytes.size() != RDMA_CQE_BYTES) begin
        `uvm_error("PRIVATE_RQ_CQE_PUBLISH",
                   status == null ? "null receive CQE publish status" :
                   status.convert2string())
        disable private_rq_receive_cqe_flow;
      end

      completion = null;
      fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
      if (status == null || !status.ok() || completion == null ||
          completion.cqe == null || completion.cqe.rq_cqe != 1'b1 ||
          completion.cqe.variant != RDMA_CQE_VARIANT_RQ_SRFQ ||
          completion.cqe.qpn != fixture.qp.local_qp_id ||
          completion.cqe.wqe_index != posted.index ||
          completion.cqe.wqe_wrap != posted.wrap ||
          completion.cqe.wr_id != posted.wr_id ||
          completion.cqe.opcode != RDMA_WR_RECV ||
          completion.cqe.rqe_cpl != 1'b1 ||
          completion.completion_status == null ||
          !completion.completion_status.ok() ||
          completion.released_slots.size() != 1 ||
          completion.released_slots[0] == null ||
          completion.released_slots[0].wr_id != posted.wr_id ||
          completion.released_slots[0].index != posted.index ||
          completion.released_slots[0].wrap != posted.wrap ||
          completion.released_slots[0].completion_status == null ||
          !completion.released_slots[0].completion_status.ok()) begin
        `uvm_error("PRIVATE_RQ_CQE_POLL",
                   status == null ? "null receive CQE poll status" :
                   status.convert2string())
        disable private_rq_receive_cqe_flow;
      end

      used = 1;
      pending = 1'b1;
      status = fixture.engine.query_runtime_occupancy(
        fixture.qp.handle, RDMA_QUEUE_RUNTIME_RQ, used, pending);
      if (status == null || !status.ok() || used != 0 || pending) begin
        `uvm_error("PRIVATE_RQ_CQE_RQ_RELEASE",
                   status == null ? "null RQ release status" :
                   status.convert2string())
      end
      status = fixture.engine.query_runtime_occupancy(
        fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, used, pending);
      if (status == null || !status.ok() || used != 0 || pending) begin
        `uvm_error("PRIVATE_RQ_CQE_SQ_UNTOUCHED",
                   status == null ? "null SQ occupancy status" :
                   status.convert2string())
      end
      status = fixture.engine.query_runtime_occupancy(
        fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, used, pending);
      if (status == null || !status.ok() || used != 0 || pending) begin
        `uvm_error("PRIVATE_RQ_CQE_CQ_RELEASE",
                   status == null ? "null CQ release status" :
                   status.convert2string())
      end

      status = fixture.engine.query_runtime_cursors(
        fixture.qp.handle, RDMA_QUEUE_RUNTIME_RQ, producer_index,
        producer_wrap, consumer_index, consumer_wrap);
      if (status == null || !status.ok() || producer_index != 1 ||
          producer_wrap != 1'b0 || consumer_index != 1 ||
          consumer_wrap != 1'b0) begin
        `uvm_error("PRIVATE_RQ_CQE_RQ_CURSOR",
                   status == null ? "null RQ cursor status" :
                   status.convert2string())
      end
      status = fixture.engine.query_runtime_cursors(
        fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, producer_index,
        producer_wrap, consumer_index, consumer_wrap);
      if (status == null || !status.ok() || producer_index != 1 ||
          producer_wrap != 1'b0 || consumer_index != 1 ||
          consumer_wrap != 1'b0) begin
        `uvm_error("PRIVATE_RQ_CQE_CQ_CURSOR",
                   status == null ? "null CQ cursor status" :
                   status.convert2string())
      end

      completion = null;
      fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
      if (status == null || status.code != RDMA_SC_QUEUE_EMPTY ||
          completion != null)
        `uvm_error("PRIVATE_RQ_CQE_EMPTY",
                   status == null ? "null second-poll status" :
                   status.convert2string())
    end

    if (fixture != null && fixture.needs_cleanup()) begin
      fixture.cleanup(cleanup_status);
      if (cleanup_status == null || !cleanup_status.ok())
        `uvm_error("PRIVATE_RQ_CQE_CLEANUP",
                   cleanup_status == null ? "null cleanup status" :
                   cleanup_status.convert2string())
    end
  endtask

  // 功能：check_ud_send_cqe_e2e 在真实 UD QP/CQ route 上执行
  //   post_send→公开 publish_cqe→poll_cqe，确认 poll 按冻结 UD variant 保留
  //   qword2/qword3 overlay，并只释放 UD SQ ledger，不误碰私有 RQ。
  // 输入/输出及副作用：无显式参数；任务创建带 CQC context shadow 的 fixture，
  //   将基础 RC route 切换为 fixture-owned UD QP/CQ，发布并消费一条空 payload
  //   UD SEND CQE，读取 SQ/RQ/CQ occupancy、cursor 与 detached completion，最后
  //   由 fixture cleanup 释放 UD/URC/base QP、CQ、PD 与 Function 资源。
  // 失败/边界：setup、UD route 切换、request/AV、post、polarity、CQE 构造、
  //   publish、poll、overlay/occupancy/cursor 查询或第二次空轮询任一步失败均报告
  //   UVM_ERROR；任何 early disable 都必须继续 cleanup，不能把未完成 result 当作成功。
  task automatic check_ud_send_cqe_e2e();
    rdma_queue_data_engine_fixture fixture;
    rdma_post_send_req request;
    rdma_address_vector av;
    rdma_queue_post_result posted;
    rdma_hw_cqe_model cqe;
    rdma_queue_device_publish_result published;
    rdma_queue_completion_result completion;
    rdma_status setup_status;
    rdma_status status;
    rdma_status cqe_status;
    rdma_status cleanup_status;
    rdma_status clone_status;
    int unsigned used;
    int unsigned producer_index;
    int unsigned consumer_index;
    bit pending;
    bit producer_wrap;
    bit consumer_wrap;
    bit polarity;

    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "ud_send_cqe_fixture");
    begin : ud_send_cqe_flow
      if (fixture == null) begin
        `uvm_error("UD_SEND_CQE_FIXTURE",
                   "UD send CQE fixture allocation failed")
        disable ud_send_cqe_flow;
      end

      // UD poll 的 CI/wrap 同样必须写入 CQC context shadow；fixture 显式注入
      // shadow 后再切换 CQ transport，避免以普通 CQ consumer MMIO 伪造成功。
      fixture.setup(setup_status, 16, RDMA_CQE_BYTES, 16, 16,
                    1'b1, 1'b0, 1'b0);
      if (setup_status == null || !setup_status.ok()) begin
        `uvm_error("UD_SEND_CQE_SETUP",
                   setup_status == null ? "null setup status" :
                   setup_status.convert2string())
        disable ud_send_cqe_flow;
      end

      fixture.setup_transport_qps(status);
      if (status == null || !status.ok() || fixture.ud_qp == null ||
          fixture.ud_qp.handle == null) begin
        `uvm_error("UD_SEND_CQE_QP",
                   status == null ? "UD transport QP setup failed" :
                   status.convert2string())
        disable ud_send_cqe_flow;
      end

      // attach_cq 冻结 transport profile；基础 RC QP/CQ 必须先撤销，避免同一
      // CQ 同时存在 RC 与 UD route，导致 variant authority 不唯一。
      status = fixture.engine.detach(fixture.qp.handle);
      if (status == null || !status.ok()) begin
        `uvm_error("UD_SEND_CQE_DETACH_QP",
                   status == null ? "base QP detach failed" :
                   status.convert2string())
        disable ud_send_cqe_flow;
      end
      fixture.qp_attached = 1'b0;

      status = fixture.engine.detach(fixture.cq.handle);
      if (status == null || !status.ok()) begin
        `uvm_error("UD_SEND_CQE_DETACH_CQ",
                   status == null ? "base CQ detach failed" :
                   status.convert2string())
        disable ud_send_cqe_flow;
      end
      fixture.cq_attached = 1'b0;

      status = fixture.engine.attach_cq(
        fixture.cq.handle, RDMA_TRANSPORT_UD);
      if (status == null || !status.ok()) begin
        `uvm_error("UD_SEND_CQE_ATTACH_CQ",
                   status == null ? "UD CQ attach failed" :
                   status.convert2string())
        disable ud_send_cqe_flow;
      end
      fixture.cq_attached = 1'b1;

      status = fixture.engine.attach_qp(fixture.ud_qp.handle);
      if (status == null || !status.ok()) begin
        `uvm_error("UD_SEND_CQE_ATTACH_QP",
                   status == null ? "UD QP attach failed" :
                   status.convert2string())
        disable ud_send_cqe_flow;
      end
      fixture.ud_qp_attached = 1'b1;

      request = fixture.make_send(64'hbabe_cafe_0000_1310);
      clone_status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "UD request factory returned null before handle clone");
      if (request != null)
        clone_status = clone_test_handle(fixture.ud_qp.handle, request.qp_h);
      av = rdma_address_vector::type_id::create("ud_send_cqe_av");
      if (request == null || clone_status == null || !clone_status.ok() ||
          request.qp_h == null || av == null) begin
        `uvm_error("UD_SEND_CQE_REQUEST",
                   clone_status == null ? "UD request setup returned null status" :
                   clone_status.convert2string())
        disable ud_send_cqe_flow;
      end
      request.transport = RDMA_TRANSPORT_UD;
      request.opcode = RDMA_WR_SEND;
      request.sges.delete();
      request.payload.delete();
      request.inline_data = 1'b0;
      request.destination_qpn = 24'h123;
      request.qkey = 32'h8001_0000;
      request.address_vector_valid = 1'b1;
      av.destination_mac = 48'h0011_2233_4455;
      request.address_vector = av;

      posted = null;
      fixture.engine.post_send(request, posted, status);
      if (status == null || !status.ok() || posted == null ||
          posted.status == null || !posted.status.ok() || posted.index != 0 ||
          posted.wrap != 1'b0 || posted.image == null ||
          posted.image.bytes.size() != RDMA_WQE_BYTES) begin
        `uvm_error("UD_SEND_CQE_POST",
                   status == null ? "UD post-send returned null status" :
                   status.convert2string())
        disable ud_send_cqe_flow;
      end

      used = 0;
      pending = 1'b1;
      status = fixture.engine.query_runtime_occupancy(
        fixture.ud_qp.handle, RDMA_QUEUE_RUNTIME_SQ, used, pending);
      if (status == null || !status.ok() || used != 1 || pending) begin
        `uvm_error("UD_SEND_CQE_POST_CREDIT",
                   status == null ? "null UD SQ occupancy status" :
                   status.convert2string())
        disable ud_send_cqe_flow;
      end
      status = fixture.engine.query_runtime_occupancy(
        fixture.ud_qp.handle, RDMA_QUEUE_RUNTIME_RQ, used, pending);
      if (status == null || !status.ok() || used != 0 || pending) begin
        `uvm_error("UD_SEND_CQE_RQ_BASELINE",
                   status == null ? "null UD RQ occupancy status" :
                   status.convert2string())
        disable ud_send_cqe_flow;
      end

      polarity = 1'b0;
      cqe_status = fixture.engine.query_runtime_producer_polarity(
        fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, polarity);
      if (cqe_status == null || !cqe_status.ok()) begin
        `uvm_error("UD_SEND_CQE_POLARITY",
                   cqe_status == null ? "null UD CQ polarity status" :
                   cqe_status.convert2string())
        disable ud_send_cqe_flow;
      end
      cqe = make_cqe_for_outstanding_ud_send(
        fixture.ud_qp.handle, fixture.ud_qp.local_qp_id, posted, polarity,
        cqe_status);
      if (cqe_status == null || !cqe_status.ok() || cqe == null) begin
        `uvm_error("UD_SEND_CQE_MODEL",
                   cqe_status == null ? "null UD send CQE status" :
                   cqe_status.convert2string())
        disable ud_send_cqe_flow;
      end

      published = null;
      fixture.engine.publish_cqe(fixture.cq.handle, cqe, published, status);
      if (status == null || !status.ok() || published == null ||
          published.status == null || !published.status.ok() ||
          published.index != 0 || published.wrap != 1'b0 ||
          !published.occupancy_valid || published.occupancy != 1 ||
          published.image == null ||
          published.image.bytes.size() != RDMA_CQE_BYTES) begin
        `uvm_error("UD_SEND_CQE_PUBLISH",
                   status == null ? "null UD CQE publish status" :
                   status.convert2string())
        disable ud_send_cqe_flow;
      end

      completion = null;
      fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
      if (status == null || !status.ok() || completion == null ||
          completion.cqe == null ||
          completion.cqe.variant != RDMA_CQE_VARIANT_UD ||
          completion.cqe.rq_cqe != 1'b0 ||
          completion.cqe.qpn != fixture.ud_qp.local_qp_id ||
          completion.cqe.wqe_index != posted.index ||
          completion.cqe.wqe_wrap != posted.wrap ||
          completion.cqe.wr_id != posted.wr_id ||
          completion.cqe.opcode != RDMA_WR_SEND ||
          completion.cqe.ud_src_qpn != 24'h654321 ||
          completion.cqe.ud_smac != 48'h0011_2233_4455 ||
          completion.cqe.ud_vlan_tag != 16'h7788 ||
          completion.completion_status == null ||
          !completion.completion_status.ok() ||
          completion.released_slots.size() != 1 ||
          completion.released_slots[0] == null ||
          completion.released_slots[0].wr_id != posted.wr_id ||
          completion.released_slots[0].index != posted.index ||
          completion.released_slots[0].wrap != posted.wrap ||
          completion.released_slots[0].completion_status == null ||
          !completion.released_slots[0].completion_status.ok()) begin
        `uvm_error("UD_SEND_CQE_POLL",
                   status == null ? "null UD send CQE poll status" :
                   status.convert2string())
        disable ud_send_cqe_flow;
      end

      status = fixture.engine.query_runtime_occupancy(
        fixture.ud_qp.handle, RDMA_QUEUE_RUNTIME_SQ, used, pending);
      if (status == null || !status.ok() || used != 0 || pending)
        `uvm_error("UD_SEND_CQE_SQ_RELEASE",
                   status == null ? "null UD SQ release status" :
                   status.convert2string())
      status = fixture.engine.query_runtime_occupancy(
        fixture.ud_qp.handle, RDMA_QUEUE_RUNTIME_RQ, used, pending);
      if (status == null || !status.ok() || used != 0 || pending)
        `uvm_error("UD_SEND_CQE_RQ_UNTOUCHED",
                   status == null ? "null UD RQ occupancy status" :
                   status.convert2string())
      status = fixture.engine.query_runtime_occupancy(
        fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, used, pending);
      if (status == null || !status.ok() || used != 0 || pending)
        `uvm_error("UD_SEND_CQE_CQ_RELEASE",
                   status == null ? "null UD CQ release status" :
                   status.convert2string())

      status = fixture.engine.query_runtime_cursors(
        fixture.ud_qp.handle, RDMA_QUEUE_RUNTIME_SQ, producer_index,
        producer_wrap, consumer_index, consumer_wrap);
      if (status == null || !status.ok() || producer_index != 1 ||
          producer_wrap != 1'b0 || consumer_index != 1 ||
          consumer_wrap != 1'b0)
        `uvm_error("UD_SEND_CQE_SQ_CURSOR",
                   status == null ? "null UD SQ cursor status" :
                   status.convert2string())
      status = fixture.engine.query_runtime_cursors(
        fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, producer_index,
        producer_wrap, consumer_index, consumer_wrap);
      if (status == null || !status.ok() || producer_index != 1 ||
          producer_wrap != 1'b0 || consumer_index != 1 ||
          consumer_wrap != 1'b0)
        `uvm_error("UD_SEND_CQE_CQ_CURSOR",
                   status == null ? "null UD CQ cursor status" :
                   status.convert2string())

      completion = null;
      fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
      if (status == null || status.code != RDMA_SC_QUEUE_EMPTY ||
          completion != null)
        `uvm_error("UD_SEND_CQE_EMPTY",
                   status == null ? "null second UD poll status" :
                   status.convert2string())
    end

    if (fixture != null && fixture.needs_cleanup()) begin
      fixture.cleanup(cleanup_status);
      if (cleanup_status == null || !cleanup_status.ok())
        `uvm_error("UD_SEND_CQE_CLEANUP",
                   cleanup_status == null ? "null cleanup status" :
                   cleanup_status.convert2string())
    end
  endtask

  // 功能：run_phase 验证未配置拒绝、post→public publish_cqe→poll 的 WQE release，
  //   以及 consumer commit 后 CQ 为空的可观察结果。
  // 输入/输出及副作用：phase 为输入；任务创建 fixture、调用公开 API 并报告断言，
  //   不直接写入正向 CQ backing，最终聚合释放 fixture-owned lifecycle 资源。
  // 失败/边界：fixture 分配、setup、post、polarity、CQE 构造、publish 或 poll 失败时停止后续正向
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
    check_cq_poll_wq_attachment_validator();
    check_private_rq_receive_cqe_e2e();
    check_ud_send_cqe_e2e();
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
      fixture.setup(status, 16, RDMA_CQE_BYTES, 16, 16, 1'b1);
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
