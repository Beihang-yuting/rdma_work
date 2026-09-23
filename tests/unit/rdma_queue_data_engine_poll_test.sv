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
  //   polarity 构造显式 RC variant 的 CQE model，供公开 publish_cqe 提交并由
  //   poll 精确释放对应 SQ ledger。
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
    // 本 helper 仅服务 fixture 默认 RC QP 的 SQ completion；显式冻结 send
    // overlay，避免 producer variant gate 依赖 model 构造的兼容默认值。
    model.srfq = 1'b0;
    model.variant = RDMA_CQE_VARIANT_RC;
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

  // 功能：make_cqe_for_outstanding_shared_srq_receive 根据已 post 的共享 SRQ
  //   slot、负责完成的 RC QP、SRQ wire local ID 与 CQ producer polarity，构造带
  //   SRFQ overlay 的 receive CQE；模型同时保留 WQE release 坐标，供公开
  //   publish_cqe→poll_cqe 链验证 shared-SRQ ledger release；调用方负责把真实
  //   SRQ 的 authoritative local_srq_id 作为 srqn 传入，helper 只负责 wire 范围门禁。
  // 输入/输出及副作用：qp_h、qpn、srqn、posted、polarity 为输入；status 为输出；
  //   成功返回 detached QP-owned CQE，不读取/写入 CQ/SRQ backing，不修改 posted
  //   或任何 runtime；srfqn 从 SRQ resource 的 authoritative local_srq_id 投影，
  //   不把 handle.object_id（manager registry identity）误当成 wire 坐标。
  // 失败/边界：QP kind、local_qp_id 超出 18-bit wire 范围、local_srq_id 超出 12-bit
  //   wire 范围、posted/status
  //   evidence 或对象分配/clone 失败时返回 null 与非成功 status；调用方不得把
  //   缺失 srfqn、srfqe index/wrap 或 RQ/SRFQ variant 的半成品送入 publish_cqe。
  function automatic rdma_hw_cqe_model make_cqe_for_outstanding_shared_srq_receive(
    rdma_handle qp_h,
    int unsigned qpn,
    int unsigned srqn,
    rdma_queue_post_result posted,
    bit polarity,
    output rdma_status status
  );
    rdma_hw_cqe_model model;

    status = rdma_status::success();
    model = null;
    if (qp_h == null || qp_h.kind != RDMA_RESOURCE_QP ||
        qpn > 18'h3ffff || srqn > 12'hfff || posted == null ||
        posted.status == null || !posted.status.ok()) begin
      status = rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "poll test shared-SRQ receive CQE evidence is incomplete");
      return null;
    end
    model = rdma_hw_cqe_model::type_id::create(
      "poll_test_shared_srq_receive_cqe");
    if (model == null) begin
      status = rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "poll test shared-SRQ receive CQE allocation failed");
      return null;
    end
    status = clone_test_handle(qp_h, model.qp_h);
    if (status == null || !status.ok() || model.qp_h == null) begin
      if (status == null)
        status = rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "poll test shared-SRQ CQE QP clone returned null status");
      model = null;
      return null;
    end
    model.wr_id = posted.wr_id;
    model.opcode = RDMA_WR_RECV;
    model.qpn = qpn;
    model.wqe_index = posted.index;
    model.wqe_wrap = posted.wrap;
    model.rq_cqe = 1'b1;
    model.srfq = 1'b1;
    model.variant = RDMA_CQE_VARIANT_RQ_SRFQ;
    model.polarity = polarity;
    model.packet_opcode = 8'h01;
    model.ecode = RDMA_CMQ_SUCCESS_ECODE;
    model.payload_len = 32;
    model.immediate_data = 32'h0;
    model.signature = 8'h0;
    model.rqe_cpl = 1'b1;
    model.srfqn = srqn[11:0];
    model.srfqe_wrap = posted.wrap;
    model.srfqe_index = posted.index[14:0];
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

  // 功能：create_shared_srq_poll_route 为 poll focused fixture 创建 owned-backing
  //   SRQ 与引用该 SRQ 的真实 RC QP，并把 QP attach 到指定 CQ，交付可供
  //   post_recv/publish_cqe/poll_cqe 使用的 shared receive route。
  // 输入/输出及副作用：label、fixture、target_cq 为输入；srq/srq_qp 与四个
  //   lifecycle flag、status 为输出；成功时 queue/QP executor 会新增资源和
  //   engine attachment，所有权仍由调用方按 flag 逆序回收；srq_attached 明确
  //   记录 attach_qp 成功后由 QP 借用建立的 SRQ attachment。
  // 失败/边界：fixture dependency、request allocation/clone、CMQ create/cast 或
  //   attach 失败时保留已置位 flag、清晰错误 status 和部分输出；调用方必须继续
  //   cleanup，不能因为 SRQ QP 创建失败而跳过已成功创建的 SRQ。
  task automatic create_shared_srq_poll_route(
    string label,
    rdma_queue_data_engine_fixture fixture,
    rdma_cq target_cq,
    output rdma_srq srq,
    output rdma_qp srq_qp,
    output bit srq_created,
    output bit srq_qp_created,
    output bit srq_qp_attached,
    output bit srq_attached,
    output rdma_status status
  );
    rdma_create_srq_req srq_request;
    rdma_create_qp_req qp_request;
    rdma_resource created_resource;
    rdma_control_result control_result;

    srq = null;
    srq_qp = null;
    srq_created = 1'b0;
    srq_qp_created = 1'b0;
    srq_qp_attached = 1'b0;
    srq_attached = 1'b0;
    status = rdma_status::make(
      RDMA_SC_INVALID_STATE, "shared-SRQ poll route is incomplete");
    if (fixture == null || fixture.binding == null || fixture.pd == null ||
        fixture.pd.handle == null || target_cq == null ||
        target_cq.handle == null || fixture.queue_executor == null ||
        fixture.qp_executor == null || fixture.engine == null)
      return;

    srq_request = rdma_create_srq_req::type_id::create(
      {label, "_srq_request"});
    if (srq_request == null) begin
      status = rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "shared-SRQ poll request allocation failed");
      return;
    end
    srq_request.owner = fixture.binding.make_handle();
    srq_request.depth = 16;
    srq_request.max_sge = 4;
    srq_request.limit_threshold = 16;
    srq_request.pd_h = rdma_clone_handle_value(
      fixture.pd.handle, {label, "_srq_pd"});
    srq_request.payload_backing.mode = RDMA_QUEUE_BACKING_OWNED;
    if (srq_request.owner == null || srq_request.pd_h == null) begin
      status = rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "shared-SRQ poll handle clone failed");
      return;
    end
    created_resource = null;
    control_result = null;
    fixture.queue_executor.create_locked(
      fixture.binding, fixture.binding.make_handle(), srq_request, 64'h2133,
      created_resource, control_result);
    status = control_result == null ?
      rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "shared-SRQ poll create returned no control result") :
      control_result.status;
    if (status == null || !status.ok() || created_resource == null ||
        !$cast(srq, created_resource)) begin
      if (status == null || status.ok())
        status = rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "shared-SRQ poll create returned wrong resource");
      return;
    end
    srq_created = 1'b1;

    qp_request = rdma_create_qp_req::type_id::create(
      {label, "_qp_request"});
    if (qp_request == null) begin
      status = rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "shared-SRQ poll QP request allocation failed");
      return;
    end
    qp_request.owner = fixture.binding.make_handle();
    qp_request.transport = RDMA_TRANSPORT_RC;
    qp_request.sq_depth = 16;
    qp_request.rq_depth = 16;
    qp_request.max_send_sge = 4;
    qp_request.max_recv_sge = 4;
    qp_request.max_inline_data = 32;
    qp_request.pd_h = rdma_clone_handle_value(
      fixture.pd.handle, {label, "_qp_pd"});
    qp_request.send_cq_h = rdma_clone_handle_value(
      target_cq.handle, {label, "_send_cq"});
    qp_request.recv_cq_h = rdma_clone_handle_value(
      target_cq.handle, {label, "_recv_cq"});
    qp_request.srq_h = rdma_clone_handle_value(
      srq.handle, {label, "_srq"});
    qp_request.context_attrs = fixture.make_transport_attrs(
      {label, "_attrs"}, RDMA_TRANSPORT_RC);
    if (qp_request.owner == null || qp_request.pd_h == null ||
        qp_request.send_cq_h == null || qp_request.recv_cq_h == null ||
        qp_request.srq_h == null || qp_request.context_attrs == null) begin
      status = rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "shared-SRQ poll QP request is incomplete");
      return;
    end
    control_result = null;
    fixture.qp_executor.create_locked(
      fixture.binding, fixture.binding.make_handle(), qp_request, 64'h2134,
      srq_qp, control_result);
    status = control_result == null ?
      rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "shared-SRQ poll QP create returned no control result") :
      control_result.status;
    if (status == null || !status.ok() || srq_qp == null)
      return;
    srq_qp_created = 1'b1;
    status = fixture.engine.attach_qp(srq_qp.handle);
    if (status == null || !status.ok())
      return;
    srq_qp_attached = 1'b1;
    srq_attached = 1'b1;
    status = rdma_status::success();
  endtask

  // 功能：destroy_shared_srq_poll_route 先撤销 QP 借用的 SRQ engine attachment，
  //   再通过公开 executor 回收 poll task 创建的 SRQ；调用方应在此 task 前先销毁
  //   引用 SRQ 的 QP，确保 QP link、SRQ attachment 与 SRFQ backing 依赖顺序闭合。
  // 输入/输出及副作用：fixture、srq_h、created、srq_attached、transaction_id 为
  //   输入，status 为输出；created=1 时按 detach→destroy 顺序提交 cleanup，不直接
  //   改写 manager 私有表；即使 srq_attached=0 也会探测一次 detach，以清理
  //   attach_qp 部分失败后可能残留的 SRQ attachment；明确的“未附着”状态可安全忽略。
  // 失败/边界：created=0 是幂等成功；依赖、handle、transaction 或 control result
  //   缺失时返回明确失败；SRQ detach 失败时仍尝试 destroy 并返回首个错误，不能吞掉
  //   engine attachment 残留或跳过基础 fixture cleanup。
  task automatic destroy_shared_srq_poll_route(
    rdma_queue_data_engine_fixture fixture,
    rdma_handle srq_h,
    bit created,
    bit srq_attached,
    longint unsigned transaction_id,
    output rdma_status status
  );
    rdma_destroy_resource_req request;
    rdma_control_result control_result;
    rdma_status detach_status;
    rdma_status destroy_status;

    status = rdma_status::make(
      RDMA_SC_INVALID_STATE, "shared-SRQ poll teardown is incomplete");
    if (!created) begin
      status = rdma_status::success();
      return;
    end
    if (fixture == null || fixture.binding == null ||
        fixture.queue_executor == null || srq_h == null ||
        transaction_id == 0)
      return;
    status = rdma_status::success();
    if (fixture.engine == null) begin
      if (srq_attached)
        status = rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "shared-SRQ poll detach requires queue-data engine");
    end
    else begin
      detach_status = fixture.engine.detach(srq_h);
      if (detach_status == null)
        detach_status = rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "shared-SRQ poll detach returned null status");
      if (!detach_status.ok() &&
          !(detach_status.code == RDMA_SC_INVALID_STATE &&
            detach_status.message == "queue is not attached"))
        status = detach_status;
    end
    request = rdma_destroy_resource_req::type_id::create(
      "shared_srq_poll_destroy");
    if (request == null) begin
      if (status == null || status.ok())
        status = rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "shared-SRQ poll destroy request allocation failed");
      return;
    end
    request.owner = fixture.binding.make_handle();
    request.target_h = srq_h;
    if (request.owner == null) begin
      if (status == null || status.ok())
        status = rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "shared-SRQ poll destroy owner clone failed");
      return;
    end
    control_result = null;
    fixture.queue_executor.destroy_locked(
      fixture.binding, fixture.binding.make_handle(), request,
      transaction_id, control_result);
    destroy_status = control_result == null ?
      rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "shared-SRQ poll destroy returned no control result") :
      control_result.status;
    if (destroy_status == null)
      destroy_status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "shared-SRQ poll destroy returned null status");
    if (status == null || status.ok())
      status = destroy_status;
  endtask

  // 功能：check_shared_srq_receive_cqe_e2e 在真实 shared-SRQ/QP/CQ lifecycle
  //   route 上先验证 publish 与 poll 两侧 srfq/topology 相反的 CQE 都被原子
  //   拒绝，再执行 post_recv→公开 publish_cqe(rq_cqe=1,srfq=1)→poll_cqe，确认
  //   receive completion 释放共享 SRQ ledger，而不是负责完成的 QP 私有 RQ。
  // 输入/输出及副作用：无显式参数；任务创建带 CQC context shadow 的基础 fixture，
  //   通过本测试的独立 route helper 增加 fixture-scope SRQ 与 RC QP，发布/消费一条
  //   SRFQ receive CQE，先由 probe 在已提交槽位中只翻转 wire bit，再读取 SRQ、
  //   私有 RQ、CQ 的 occupancy/cursor 与 detached result，最后按 QP→SRQ→基础
  //   fixture 顺序释放全部资源。
  // 失败/边界：setup、SRQ route、request/post、polarity、CQE 构造、publish、poll、
  //   hostile image 恢复、overlay/ledger/cursor 查询或第二次空轮询任一步失败均
  //   报告 UVM_ERROR；任何 early disable 都继续销毁已创建的 SRQ QP/SRQ，避免共享
  //   CQ/PD 被提前释放。
  task automatic check_shared_srq_receive_cqe_e2e();
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_data_engine_probe probe;
    rdma_srq srq;
    rdma_qp srq_qp;
    rdma_post_recv_req request;
    rdma_post_recv_req released_request;
    rdma_sge sge;
    rdma_queue_post_result posted;
    rdma_hw_cqe_model cqe;
    rdma_queue_device_publish_result published;
    rdma_queue_completion_result completion;
    rdma_queue_completion_result malformed_completion;
    rdma_status setup_status;
    rdma_status status;
    rdma_status clone_status;
    rdma_status cqe_status;
    rdma_status malformed_status;
    rdma_status malformed_poll_status;
    rdma_status cleanup_status;
    bit srq_created;
    bit srq_qp_created;
    bit srq_qp_attached;
    bit srq_attached;
    int unsigned used;
    int unsigned producer_index;
    int unsigned consumer_index;
    int unsigned before_srq_used;
    int unsigned before_srq_pi;
    int unsigned before_srq_ci;
    int unsigned before_cq_used;
    int unsigned before_cq_pi;
    int unsigned before_cq_ci;
    int unsigned poll_before_srq_used;
    int unsigned poll_before_srq_pi;
    int unsigned poll_before_srq_ci;
    int unsigned poll_before_cq_used;
    int unsigned poll_before_cq_pi;
    int unsigned poll_before_cq_ci;
    bit pending;
    bit before_srq_pending;
    bit before_srq_pi_wrap;
    bit before_srq_ci_wrap;
    bit before_cq_pending;
    bit before_cq_pi_wrap;
    bit before_cq_ci_wrap;
    bit poll_before_srq_pending;
    bit poll_before_srq_pi_wrap;
    bit poll_before_srq_ci_wrap;
    bit poll_before_cq_pending;
    bit poll_before_cq_pi_wrap;
    bit poll_before_cq_ci_wrap;
    bit producer_wrap;
    bit consumer_wrap;
    bit malformed_rejection_ok;
    bit malformed_poll_rejection_ok;
    bit polarity;

    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "shared_srq_receive_cqe_fixture");
    srq = null;
    probe = null;
    srq_qp = null;
    srq_created = 1'b0;
    srq_qp_created = 1'b0;
    srq_qp_attached = 1'b0;
    srq_attached = 1'b0;
    begin : shared_srq_receive_cqe_flow
      if (fixture == null) begin
        `uvm_error("SHARED_SRQ_CQE_FIXTURE",
                   "shared-SRQ receive CQE fixture allocation failed")
        disable shared_srq_receive_cqe_flow;
      end

      // CQ poll 的 CI/wrap 仍必须来自 CQC context shadow；SRQ route 额外借用
      // 同一 CQ，但其 WQE ledger 由独立 SRQ runtime 拥有。最后一个参数启用
      // focused probe，使测试能在已提交 CQE 上做受控 wire-image mutation；生产
      // poll/publish 实现仍由同一基类 task 执行。
      fixture.setup(setup_status, 16, RDMA_CQE_BYTES, 16, 16,
                    1'b1, 1'b0, 1'b1);
      if (setup_status == null || !setup_status.ok()) begin
        `uvm_error("SHARED_SRQ_CQE_SETUP",
                   setup_status == null ? "null setup status" :
                   setup_status.convert2string())
        disable shared_srq_receive_cqe_flow;
      end
      if (!$cast(probe, fixture.engine) || probe == null) begin
        `uvm_error("SHARED_SRQ_CQE_PROBE",
                   "shared-SRQ poll fixture did not create queue-data probe")
        disable shared_srq_receive_cqe_flow;
      end

      // 独立 helper 通过本 fixture 的 queue/QP executor 创建真实 SRQ/QP route；
      // 资源所有权仍由本 task 的 explicit flags 与 fixture executor 管理，不依赖
      // 其他测试 class 的字段或 run_phase 上下文。
      create_shared_srq_poll_route(
        "shared_srq_receive", fixture, fixture.cq, srq, srq_qp,
        srq_created, srq_qp_created, srq_qp_attached, srq_attached, status);
      if (status == null || !status.ok() || srq == null || srq.handle == null ||
          srq_qp == null || srq_qp.handle == null || !srq_created ||
          !srq_qp_created || !srq_qp_attached || !srq_attached) begin
        `uvm_error("SHARED_SRQ_CQE_ROUTE",
                   status == null ? "null SRQ route status" :
                   status.convert2string())
        disable shared_srq_receive_cqe_flow;
      end

      request = rdma_post_recv_req::type_id::create(
        "shared_srq_receive_request");
      sge = rdma_sge::type_id::create("shared_srq_receive_sge");
      clone_status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "shared-SRQ request handle clone was not attempted");
      if (request != null)
        request.owner = fixture.binding.make_handle();
      if (request != null)
        clone_status = clone_test_handle(
          srq.handle, request.target_h);
      if (request != null && clone_status != null && clone_status.ok())
        clone_status = clone_test_handle(
          srq_qp.handle, request.completion_qp_h);
      if (sge != null) begin
        sge.iova.value = 64'h0000_3000_0000_0000;
        sge.length = 128;
        sge.lkey = 32'h090a_0b0c;
      end
      if (request != null && sge != null)
        request.sges.push_back(sge);
      if (request == null || sge == null || clone_status == null ||
          !clone_status.ok() || request.owner == null ||
          request.target_h == null || request.completion_qp_h == null) begin
        `uvm_error("SHARED_SRQ_CQE_REQUEST",
                   clone_status == null ? "null SRQ request status" :
                   clone_status.convert2string())
        disable shared_srq_receive_cqe_flow;
      end
      request.wr_id = 64'hbabe_cafe_0000_1320;

      posted = null;
      fixture.engine.post_recv(request, posted, status);
      if (status == null || !status.ok() || posted == null ||
          posted.status == null || !posted.status.ok() || posted.index != 0 ||
          posted.wrap != 1'b0 || posted.image == null ||
          posted.image.bytes.size() != RDMA_WQE_BYTES) begin
        `uvm_error("SHARED_SRQ_CQE_POST",
                   status == null ? "null shared-SRQ post status" :
                   status.convert2string())
        disable shared_srq_receive_cqe_flow;
      end

      used = 0;
      pending = 1'b1;
      status = fixture.engine.query_runtime_occupancy(
        srq.handle, RDMA_QUEUE_RUNTIME_SRQ, used, pending);
      if (status == null || !status.ok() || used != 1 || pending) begin
        `uvm_error("SHARED_SRQ_CQE_POST_CREDIT",
                   status == null ? "null SRQ occupancy status" :
                   status.convert2string())
        disable shared_srq_receive_cqe_flow;
      end
      // 基础 fixture QP 仍携带独立私有 RQ；共享 SRQ post 不得伪造或消耗该账本。
      status = fixture.engine.query_runtime_occupancy(
        fixture.qp.handle, RDMA_QUEUE_RUNTIME_RQ, used, pending);
      if (status == null || !status.ok() || used != 0 || pending) begin
        `uvm_error("SHARED_SRQ_CQE_PRIVATE_RQ_BASELINE",
                   status == null ? "null private RQ baseline status" :
                   status.convert2string())
        disable shared_srq_receive_cqe_flow;
      end

      polarity = 1'b0;
      cqe_status = fixture.engine.query_runtime_producer_polarity(
        fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, polarity);
      if (cqe_status == null || !cqe_status.ok()) begin
        `uvm_error("SHARED_SRQ_CQE_POLARITY",
                   cqe_status == null ? "null CQ polarity status" :
                   cqe_status.convert2string())
        disable shared_srq_receive_cqe_flow;
      end
      cqe = make_cqe_for_outstanding_shared_srq_receive(
        srq_qp.handle, srq_qp.local_qp_id, srq.local_srq_id, posted, polarity,
        cqe_status);
      if (cqe_status == null || !cqe_status.ok() || cqe == null ||
          cqe.rq_cqe != 1'b1 || cqe.srfq != 1'b1 ||
          cqe.variant != RDMA_CQE_VARIANT_RQ_SRFQ ||
          cqe.srfqn != srq.local_srq_id[11:0] ||
          cqe.srfqe_wrap != posted.wrap ||
          cqe.srfqe_index != posted.index[14:0]) begin
        `uvm_error("SHARED_SRQ_CQE_MODEL",
                   cqe_status == null ? "null shared-SRQ CQE status" :
                   cqe_status.convert2string())
        disable shared_srq_receive_cqe_flow;
      end

      // 在真实 shared-SRQ route 上先投递一份 SRFQ 位相反的 CQE。该 hostile
      // admission 必须在 producer reservation 前拒绝，且不能改变 SRQ/CQ 的
      // occupancy 或 cursor；随后恢复原始 model，继续执行合法正向链。
      status = fixture.engine.query_runtime_occupancy(
        srq.handle, RDMA_QUEUE_RUNTIME_SRQ, before_srq_used,
        before_srq_pending);
      if (status == null || !status.ok()) begin
        `uvm_error("SHARED_SRQ_CQE_MISMATCH_BASELINE",
                   status == null ? "null SRQ baseline status" :
                   status.convert2string())
        disable shared_srq_receive_cqe_flow;
      end
      status = fixture.engine.query_runtime_cursors(
        srq.handle, RDMA_QUEUE_RUNTIME_SRQ, before_srq_pi,
        before_srq_pi_wrap, before_srq_ci, before_srq_ci_wrap);
      if (status == null || !status.ok()) begin
        `uvm_error("SHARED_SRQ_CQE_MISMATCH_SRQ_CURSOR",
                   status == null ? "null SRQ baseline cursor status" :
                   status.convert2string())
        disable shared_srq_receive_cqe_flow;
      end
      status = fixture.engine.query_runtime_occupancy(
        fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, before_cq_used,
        before_cq_pending);
      if (status == null || !status.ok()) begin
        `uvm_error("SHARED_SRQ_CQE_MISMATCH_CQ_BASELINE",
                   status == null ? "null CQ baseline status" :
                   status.convert2string())
        disable shared_srq_receive_cqe_flow;
      end
      status = fixture.engine.query_runtime_cursors(
        fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, before_cq_pi,
        before_cq_pi_wrap, before_cq_ci, before_cq_ci_wrap);
      if (status == null || !status.ok()) begin
        `uvm_error("SHARED_SRQ_CQE_MISMATCH_CQ_CURSOR",
                   status == null ? "null CQ baseline cursor status" :
                   status.convert2string())
        disable shared_srq_receive_cqe_flow;
      end

      cqe.srfq = 1'b0;
      malformed_rejection_ok = 1'b0;
      malformed_status = null;
      published = null;
      fixture.engine.publish_cqe(fixture.cq.handle, cqe,
                                  published, malformed_status);
      if (malformed_status != null &&
          malformed_status.code == RDMA_SC_INVALID_ARGUMENT &&
          published == null)
        malformed_rejection_ok = 1'b1;
      status = fixture.engine.query_runtime_occupancy(
        srq.handle, RDMA_QUEUE_RUNTIME_SRQ, used, pending);
      if (!malformed_rejection_ok || status == null || !status.ok() ||
          used != before_srq_used || pending != before_srq_pending)
        `uvm_error("SHARED_SRQ_CQE_MISMATCH_SRFQ",
                   malformed_status == null ?
                   "SRFQ/topology mismatch was not rejected" :
                   malformed_status.convert2string())
      status = fixture.engine.query_runtime_cursors(
        srq.handle, RDMA_QUEUE_RUNTIME_SRQ, producer_index,
        producer_wrap, consumer_index, consumer_wrap);
      if (!malformed_rejection_ok || status == null || !status.ok() ||
          producer_index != before_srq_pi ||
          producer_wrap != before_srq_pi_wrap ||
          consumer_index != before_srq_ci ||
          consumer_wrap != before_srq_ci_wrap)
        `uvm_error("SHARED_SRQ_CQE_MISMATCH_SRQ_CURSOR",
                   "SRQ cursor changed after rejected CQE")
      status = fixture.engine.query_runtime_occupancy(
        fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, used, pending);
      if (!malformed_rejection_ok || status == null || !status.ok() ||
          used != before_cq_used || pending != before_cq_pending)
        `uvm_error("SHARED_SRQ_CQE_MISMATCH_CQ",
                   "CQ occupancy changed after rejected CQE")
      status = fixture.engine.query_runtime_cursors(
        fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, producer_index,
        producer_wrap, consumer_index, consumer_wrap);
      if (!malformed_rejection_ok || status == null || !status.ok() ||
          producer_index != before_cq_pi ||
          producer_wrap != before_cq_pi_wrap ||
          consumer_index != before_cq_ci ||
          consumer_wrap != before_cq_ci_wrap)
        `uvm_error("SHARED_SRQ_CQE_MISMATCH_CQ_CURSOR",
                   "CQ cursor changed after rejected CQE")
      cqe.srfq = 1'b1;

      published = null;
      fixture.engine.publish_cqe(fixture.cq.handle, cqe, published, status);
      if (status == null || !status.ok() || published == null ||
          published.status == null || !published.status.ok() ||
          published.index != 0 || published.wrap != 1'b0 ||
          !published.occupancy_valid || published.occupancy != 1 ||
          published.image == null ||
          published.image.bytes.size() != RDMA_CQE_BYTES) begin
        `uvm_error("SHARED_SRQ_CQE_PUBLISH",
                   status == null ? "null shared-SRQ CQE publish status" :
                   status.convert2string())
        disable shared_srq_receive_cqe_flow;
      end

      // publish 已经把合法 CQE 提交到 slot/occupancy 后，probe 只改写该 committed
      // image 的 qword0[58]，从而绕过 publish-side gate 直接验证 poll-side
      // resolve_cqe_variant_for_image；probe 不触碰 CQ/SRQ runtime，故拒绝前后的
      // cursor/occupancy 应保持完全一致。验证后立即恢复 srfq=1，再走真实 poll。
      status = fixture.engine.query_runtime_occupancy(
        srq.handle, RDMA_QUEUE_RUNTIME_SRQ, poll_before_srq_used,
        poll_before_srq_pending);
      if (status == null || !status.ok()) begin
        `uvm_error("SHARED_SRQ_CQE_POLL_MISMATCH_BASELINE",
                   status == null ? "null SRQ poll baseline status" :
                   status.convert2string())
        disable shared_srq_receive_cqe_flow;
      end
      status = fixture.engine.query_runtime_cursors(
        srq.handle, RDMA_QUEUE_RUNTIME_SRQ, poll_before_srq_pi,
        poll_before_srq_pi_wrap, poll_before_srq_ci,
        poll_before_srq_ci_wrap);
      if (status == null || !status.ok()) begin
        `uvm_error("SHARED_SRQ_CQE_POLL_MISMATCH_SRQ_CURSOR",
                   status == null ? "null SRQ poll baseline cursor status" :
                   status.convert2string())
        disable shared_srq_receive_cqe_flow;
      end
      status = fixture.engine.query_runtime_occupancy(
        fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, poll_before_cq_used,
        poll_before_cq_pending);
      if (status == null || !status.ok()) begin
        `uvm_error("SHARED_SRQ_CQE_POLL_MISMATCH_CQ_BASELINE",
                   status == null ? "null CQ poll baseline status" :
                   status.convert2string())
        disable shared_srq_receive_cqe_flow;
      end
      status = fixture.engine.query_runtime_cursors(
        fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, poll_before_cq_pi,
        poll_before_cq_pi_wrap, poll_before_cq_ci,
        poll_before_cq_ci_wrap);
      if (status == null || !status.ok()) begin
        `uvm_error("SHARED_SRQ_CQE_POLL_MISMATCH_CQ_CURSOR",
                   status == null ? "null CQ poll baseline cursor status" :
                   status.convert2string())
        disable shared_srq_receive_cqe_flow;
      end

      status = probe.probe_rewrite_committed_cqe_srfq_bit(
        fixture.cq.handle, 1'b0);
      if (status == null || !status.ok()) begin
        `uvm_error("SHARED_SRQ_CQE_POLL_MUTATION",
                   status == null ? "null CQE SRFQ mutation status" :
                   status.convert2string())
        disable shared_srq_receive_cqe_flow;
      end
      malformed_completion = null;
      malformed_poll_status = null;
      fixture.engine.poll_cqe(fixture.cq.handle, 0,
                              malformed_completion, malformed_poll_status);
      malformed_poll_rejection_ok =
        malformed_poll_status != null &&
        malformed_poll_status.code == RDMA_SC_INVALID_ARGUMENT &&
        malformed_completion == null;
      status = probe.probe_rewrite_committed_cqe_srfq_bit(
        fixture.cq.handle, 1'b1);
      if (status == null || !status.ok()) begin
        `uvm_error("SHARED_SRQ_CQE_POLL_RESTORE",
                   status == null ? "null CQE SRFQ restore status" :
                   status.convert2string())
        disable shared_srq_receive_cqe_flow;
      end
      status = fixture.engine.query_runtime_occupancy(
        srq.handle, RDMA_QUEUE_RUNTIME_SRQ, used, pending);
      if (!malformed_poll_rejection_ok || status == null || !status.ok() ||
          used != poll_before_srq_used || pending != poll_before_srq_pending)
        `uvm_error("SHARED_SRQ_CQE_POLL_MISMATCH_SRFQ",
                   malformed_poll_status == null ?
                   "poll-side SRFQ/topology mismatch was not rejected" :
                   malformed_poll_status.convert2string())
      status = fixture.engine.query_runtime_cursors(
        srq.handle, RDMA_QUEUE_RUNTIME_SRQ, producer_index,
        producer_wrap, consumer_index, consumer_wrap);
      if (!malformed_poll_rejection_ok || status == null || !status.ok() ||
          producer_index != poll_before_srq_pi ||
          producer_wrap != poll_before_srq_pi_wrap ||
          consumer_index != poll_before_srq_ci ||
          consumer_wrap != poll_before_srq_ci_wrap)
        `uvm_error("SHARED_SRQ_CQE_POLL_MISMATCH_SRQ_CURSOR",
                   "SRQ cursor changed after poll-side rejected CQE")
      status = fixture.engine.query_runtime_occupancy(
        fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, used, pending);
      if (!malformed_poll_rejection_ok || status == null || !status.ok() ||
          used != poll_before_cq_used || pending != poll_before_cq_pending)
        `uvm_error("SHARED_SRQ_CQE_POLL_MISMATCH_CQ",
                   "CQ occupancy changed after poll-side rejected CQE")
      status = fixture.engine.query_runtime_cursors(
        fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, producer_index,
        producer_wrap, consumer_index, consumer_wrap);
      if (!malformed_poll_rejection_ok || status == null || !status.ok() ||
          producer_index != poll_before_cq_pi ||
          producer_wrap != poll_before_cq_pi_wrap ||
          consumer_index != poll_before_cq_ci ||
          consumer_wrap != poll_before_cq_ci_wrap)
        `uvm_error("SHARED_SRQ_CQE_POLL_MISMATCH_CQ_CURSOR",
                   "CQ cursor changed after poll-side rejected CQE")

      completion = null;
      fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
      if (status == null || !status.ok() || completion == null ||
          completion.cqe == null || completion.cqe.rq_cqe != 1'b1 ||
          completion.cqe.srfq != 1'b1 ||
          completion.cqe.variant != RDMA_CQE_VARIANT_RQ_SRFQ ||
          completion.cqe.qpn != srq_qp.local_qp_id ||
          completion.cqe.wqe_index != posted.index ||
          completion.cqe.wqe_wrap != posted.wrap ||
          completion.cqe.wr_id != posted.wr_id ||
          completion.cqe.opcode != RDMA_WR_RECV ||
          completion.cqe.rqe_cpl != 1'b1 ||
          completion.cqe.srfqn != srq.local_srq_id[11:0] ||
          completion.cqe.srfqe_wrap != posted.wrap ||
          completion.cqe.srfqe_index != posted.index[14:0] ||
          completion.completion_status == null ||
          !completion.completion_status.ok() ||
          completion.released_slots.size() != 1 ||
          completion.released_slots[0] == null ||
          completion.released_slots[0].wr_id != posted.wr_id ||
          completion.released_slots[0].index != posted.index ||
          completion.released_slots[0].wrap != posted.wrap ||
          completion.released_slots[0].completion_status == null ||
          !completion.released_slots[0].completion_status.ok()) begin
        `uvm_error("SHARED_SRQ_CQE_POLL",
                   status == null ? "null shared-SRQ CQE poll status" :
                   status.convert2string())
        disable shared_srq_receive_cqe_flow;
      end
      if (completion.released_slots[0].request_snapshot == null ||
          !$cast(released_request,
                 completion.released_slots[0].request_snapshot) ||
          released_request == null || released_request.target_h == null ||
          released_request.target_h.kind != RDMA_RESOURCE_SRQ ||
          !released_request.target_h.same_instance(srq.handle) ||
          released_request.completion_qp_h == null ||
          !released_request.completion_qp_h.same_instance(srq_qp.handle)) begin
        `uvm_error("SHARED_SRQ_CQE_LEDGER_TARGET",
                   "released ledger does not retain shared-SRQ target")
        disable shared_srq_receive_cqe_flow;
      end

      status = fixture.engine.query_runtime_occupancy(
        srq.handle, RDMA_QUEUE_RUNTIME_SRQ, used, pending);
      if (status == null || !status.ok() || used != 0 || pending)
        `uvm_error("SHARED_SRQ_CQE_SRQ_RELEASE",
                   status == null ? "null SRQ release status" :
                   status.convert2string())
      status = fixture.engine.query_runtime_occupancy(
        fixture.qp.handle, RDMA_QUEUE_RUNTIME_RQ, used, pending);
      if (status == null || !status.ok() || used != 0 || pending)
        `uvm_error("SHARED_SRQ_CQE_PRIVATE_RQ_UNTOUCHED",
                   status == null ? "null private RQ post-poll status" :
                   status.convert2string())
      status = fixture.engine.query_runtime_occupancy(
        fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, used, pending);
      if (status == null || !status.ok() || used != 0 || pending)
        `uvm_error("SHARED_SRQ_CQE_CQ_RELEASE",
                   status == null ? "null CQ release status" :
                   status.convert2string())

      status = fixture.engine.query_runtime_cursors(
        srq.handle, RDMA_QUEUE_RUNTIME_SRQ, producer_index,
        producer_wrap, consumer_index, consumer_wrap);
      if (status == null || !status.ok() || producer_index != 1 ||
          producer_wrap != 1'b0 || consumer_index != 1 ||
          consumer_wrap != 1'b0)
        `uvm_error("SHARED_SRQ_CQE_SRQ_CURSOR",
                   status == null ? "null SRQ cursor status" :
                   status.convert2string())
      status = fixture.engine.query_runtime_cursors(
        fixture.qp.handle, RDMA_QUEUE_RUNTIME_RQ, producer_index,
        producer_wrap, consumer_index, consumer_wrap);
      if (status == null || !status.ok() || producer_index != 0 ||
          producer_wrap != 1'b0 || consumer_index != 0 ||
          consumer_wrap != 1'b0)
        `uvm_error("SHARED_SRQ_CQE_PRIVATE_RQ_CURSOR",
                   status == null ? "null private RQ cursor status" :
                   status.convert2string())
      status = fixture.engine.query_runtime_cursors(
        fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, producer_index,
        producer_wrap, consumer_index, consumer_wrap);
      if (status == null || !status.ok() || producer_index != 1 ||
          producer_wrap != 1'b0 || consumer_index != 1 ||
          consumer_wrap != 1'b0)
        `uvm_error("SHARED_SRQ_CQE_CQ_CURSOR",
                   status == null ? "null CQ cursor status" :
                   status.convert2string())

      completion = null;
      fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
      if (status == null || status.code != RDMA_SC_QUEUE_EMPTY ||
          completion != null)
        `uvm_error("SHARED_SRQ_CQE_EMPTY",
                   status == null ? "null second shared-SRQ poll status" :
                   status.convert2string())
    end

    // 设计说明：SRQ QP 的 link 必须先从 engine 撤销，随后再撤销 attach_qp
    // 隐式建立的 SRQ attachment，最后才销毁 SRQ；基础 fixture 的 cleanup 只认识
    // 自身 QP/CQ，因此这里显式回收 helper 新增的非拥有 route。
    if (srq_qp_created) begin
      fixture.destroy_lifecycle_owned_qp(
        srq_qp == null ? null : srq_qp.handle, 1'b1, srq_qp_attached,
        64'h2131, cleanup_status);
      if (cleanup_status == null || !cleanup_status.ok())
        `uvm_error("SHARED_SRQ_CQE_QP_CLEANUP",
                   cleanup_status == null ? "null SRQ QP cleanup status" :
                   cleanup_status.convert2string())
      else begin
        srq_qp_created = 1'b0;
        srq_qp_attached = 1'b0;
      end
    end
    if (srq_created) begin
      destroy_shared_srq_poll_route(
        fixture, srq == null ? null : srq.handle, 1'b1, srq_attached, 64'h2132,
        cleanup_status);
      if (cleanup_status == null || !cleanup_status.ok())
        `uvm_error("SHARED_SRQ_CQE_SRQ_CLEANUP",
                   cleanup_status == null ? "null SRQ cleanup status" :
                   cleanup_status.convert2string())
      else
        begin
          srq_created = 1'b0;
          srq_attached = 1'b0;
        end
    end
    if (fixture != null && fixture.needs_cleanup()) begin
      fixture.cleanup(cleanup_status);
      if (cleanup_status == null || !cleanup_status.ok())
        `uvm_error("SHARED_SRQ_CQE_CLEANUP",
                   cleanup_status == null ? "null fixture cleanup status" :
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

  // 功能：check_ud_receive_replay_e2e 在真实 UD QP/RQ route 上注入一次 RQE
  //   Host-memory 写失败，确认 post_recv 保存的 detached producer evidence 可被
  //   caller-confirmed recovery 重放，随后再经 RQ/SRFQ CQE publish→poll 释放同一
  //   UD 私有 RQ ledger。
  // 输入/输出及副作用：无显式参数；任务创建带 CQC context shadow 的 lifecycle
  //   fixture，切换共享 CQ 到 UD route，向 Host-memory/doorbell/runtime 写入并读取
  //   detached evidence，最后由 fixture cleanup 释放 UD QP、CQ、PD 与 Function 资源。
  // 失败/边界：基础 route 未切换、target-h/owner/epoch 不完整、首写未进入 pending、
  //   未确认 retry 被接受、replay 未恢复 RQ image/cursor、CQE route/variant 不符或
  //   RQ/CQ ledger 未各释放一项时报告 UVM_ERROR；任一 early disable 都继续执行
  //   cleanup，不把失败的 post result 当成可完成 WQE。
  task automatic check_ud_receive_replay_e2e();
    rdma_queue_data_engine_fixture fixture;
    rdma_post_recv_req request;
    rdma_queue_post_result posted;
    rdma_queue_post_result recovered_posted;
    rdma_queue_pending_operation pending;
    rdma_hw_cqe_model cqe;
    rdma_queue_device_publish_result published;
    rdma_queue_completion_result completion;
    rdma_status setup_status;
    rdma_status status;
    rdma_status cqe_status;
    rdma_status clone_status;
    rdma_status cleanup_status;
    rdma_status injected;
    rdma_handle target_copy;
    byte expected_rqe[];
    byte actual_rqe[];
    int unsigned used;
    int unsigned producer_index;
    int unsigned consumer_index;
    bit pending_flag;
    bit producer_wrap;
    bit consumer_wrap;
    bit polarity;

    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "ud_receive_replay_fixture");
    begin : ud_receive_replay_flow
      if (fixture == null) begin
        `uvm_error("UD_RECV_REPLAY_FIXTURE",
                   "UD receive replay fixture allocation failed")
        disable ud_receive_replay_flow;
      end

      fixture.setup(setup_status, 16, RDMA_CQE_BYTES, 16, 16,
                    1'b1, 1'b0, 1'b0);
      if (setup_status == null || !setup_status.ok()) begin
        `uvm_error("UD_RECV_REPLAY_SETUP",
                   setup_status == null ? "null setup status" :
                   setup_status.convert2string())
        disable ud_receive_replay_flow;
      end
      fixture.setup_transport_qps(status);
      if (status == null || !status.ok() || fixture.ud_qp == null ||
          fixture.ud_qp.handle == null) begin
        `uvm_error("UD_RECV_REPLAY_QP",
                   status == null ? "UD transport QP setup failed" :
                   status.convert2string())
        disable ud_receive_replay_flow;
      end

      // 同一 CQ 不能同时以 RC/UD 两种 variant 发布；先撤销基础 route，再
      // 冻结 UD CQ/QP attachment，确保 receive CQE 的 SRFQ overlay 由真实 UD
      // link authority 解析，而不是由测试默认 transport 猜测。
      status = fixture.engine.detach(fixture.qp.handle);
      if (status == null || !status.ok()) begin
        `uvm_error("UD_RECV_REPLAY_DETACH_QP",
                   status == null ? "base QP detach failed" :
                   status.convert2string())
        disable ud_receive_replay_flow;
      end
      fixture.qp_attached = 1'b0;
      status = fixture.engine.detach(fixture.cq.handle);
      if (status == null || !status.ok()) begin
        `uvm_error("UD_RECV_REPLAY_DETACH_CQ",
                   status == null ? "base CQ detach failed" :
                   status.convert2string())
        disable ud_receive_replay_flow;
      end
      fixture.cq_attached = 1'b0;
      status = fixture.engine.attach_cq(fixture.cq.handle,
                                        RDMA_TRANSPORT_UD);
      if (status == null || !status.ok()) begin
        `uvm_error("UD_RECV_REPLAY_ATTACH_CQ",
                   status == null ? "UD CQ attach failed" :
                   status.convert2string())
        disable ud_receive_replay_flow;
      end
      fixture.cq_attached = 1'b1;
      status = fixture.engine.attach_qp(fixture.ud_qp.handle);
      if (status == null || !status.ok()) begin
        `uvm_error("UD_RECV_REPLAY_ATTACH_QP",
                   status == null ? "UD QP attach failed" :
                   status.convert2string())
        disable ud_receive_replay_flow;
      end
      fixture.ud_qp_attached = 1'b1;

      request = fixture.make_recv(64'hbabe_cafe_0000_1320);
      target_copy = null;
      clone_status = clone_test_handle(fixture.ud_qp.handle, target_copy);
      if (request == null || clone_status == null || !clone_status.ok() ||
          target_copy == null) begin
        `uvm_error("UD_RECV_REPLAY_REQUEST",
                   clone_status == null ? "UD receive target clone failed" :
                   clone_status.convert2string())
        disable ud_receive_replay_flow;
      end
      request.target_h = target_copy;

      injected = rdma_status::make(
        RDMA_SC_DMA_TRANSLATION, "injected UD receive RQE write failure");
      status = fixture.mem.fail_next("write", injected);
      if (status == null || !status.ok()) begin
        `uvm_error("UD_RECV_REPLAY_INJECT",
                   status == null ? "null write-fault injection status" :
                   status.convert2string())
        disable ud_receive_replay_flow;
      end
      posted = null;
      fixture.engine.post_recv(request, posted, status);
      if (status == null || status.ok() || posted != null) begin
        `uvm_error("UD_RECV_REPLAY_INITIAL_FAIL",
                   status == null ? "null initial post status" :
                   status.convert2string())
        disable ud_receive_replay_flow;
      end

      // 保存 recovery 的 immutable image；后续只比较实际 RQ slot，不从 request
      // 重新编码，避免测试掩盖 replay 是否真正使用 admission-time evidence。
      pending = null;
      status = fixture.engine.query_runtime_pending(
        fixture.ud_qp.handle, RDMA_QUEUE_RUNTIME_RQ, pending);
      if (status == null || !status.ok() || pending == null ||
          !pending.producer || pending.kind != RDMA_QUEUE_RUNTIME_RQ ||
          pending.cursor == null || pending.cursor.index != 0 ||
          pending.cursor.wrap != 1'b0 || pending.image == null ||
          pending.image.bytes.size() != RDMA_WQE_BYTES) begin
        `uvm_error("UD_RECV_REPLAY_PENDING",
                   status == null ? "UD receive pending evidence unavailable" :
                   status.convert2string())
        disable ud_receive_replay_flow;
      end
      expected_rqe = new[pending.image.bytes.size()];
      foreach (expected_rqe[i]) expected_rqe[i] = pending.image.bytes[i];

      fixture.engine.recover_queue(
        fixture.ud_qp.handle, RDMA_QUEUE_RECOVERY_RETRY_PENDING,
        1'b0, status);
      if (status == null || status.code != RDMA_SC_INVALID_ARGUMENT) begin
        `uvm_error("UD_RECV_REPLAY_CONFIRM",
                   "unconfirmed UD receive recovery was accepted")
        disable ud_receive_replay_flow;
      end
      fixture.engine.recover_queue(
        fixture.ud_qp.handle, RDMA_QUEUE_RECOVERY_RETRY_PENDING,
        1'b1, status);
      if (status == null || !status.ok()) begin
        `uvm_error("UD_RECV_REPLAY_RETRY",
                   status == null ? "null UD recovery status" :
                   status.convert2string())
        disable ud_receive_replay_flow;
      end

      used = 0;
      pending_flag = 1'b1;
      status = fixture.engine.query_runtime_occupancy(
        fixture.ud_qp.handle, RDMA_QUEUE_RUNTIME_RQ, used, pending_flag);
      if (status == null || !status.ok() || used != 1 || pending_flag) begin
        `uvm_error("UD_RECV_REPLAY_CREDIT",
                   status == null ? "null UD RQ occupancy status" :
                   status.convert2string())
        disable ud_receive_replay_flow;
      end
      if (fixture.ud_qp.qp_plan == null || fixture.ud_qp.qp_plan.rq_ref == null ||
          fixture.ud_qp.qp_plan.rq_ref.mapping == null)
        status = rdma_status::make(
          RDMA_SC_INVALID_STATE, "UD QP RQ backing is unavailable for replay readback");
      else
        status = fixture.mem.read(
          fixture.ud_qp.qp_plan.rq_ref.mapping,
          fixture.ud_qp.qp_plan.rq_ref.mapping_offset,
          RDMA_WQE_BYTES, actual_rqe);
      if (status == null || !status.ok() || actual_rqe.size() != expected_rqe.size())
        `uvm_error("UD_RECV_REPLAY_IMAGE",
                   status == null ? "UD RQE replay readback failed" :
                   status.convert2string())
      else begin
        foreach (expected_rqe[i]) begin
          if (actual_rqe[i] !== expected_rqe[i])
            `uvm_error("UD_RECV_REPLAY_IMAGE",
                       $sformatf("replayed RQE byte %0d differs from pending image",
                                 i))
        end
      end

      // recover_queue 不返回 post result；构造一个仅含 recovery cursor/WR 的
      // detached witness，供 CQE helper 验证 poll release 的仍是同一 RQ slot。
      recovered_posted = rdma_queue_post_result::type_id::create(
        "ud_receive_recovered_posted");
      target_copy = null;
      clone_status = clone_test_handle(fixture.ud_qp.handle, target_copy);
      if (recovered_posted == null || clone_status == null ||
          !clone_status.ok() || target_copy == null) begin
        `uvm_error("UD_RECV_REPLAY_WITNESS",
                   clone_status == null ? "UD recovered witness clone failed" :
                   clone_status.convert2string())
        disable ud_receive_replay_flow;
      end
      recovered_posted.queue_h = target_copy;
      recovered_posted.wr_id = request.wr_id;
      recovered_posted.index = 0;
      recovered_posted.wrap = 1'b0;
      recovered_posted.status = rdma_status::success();
      if (recovered_posted == null || recovered_posted.queue_h == null ||
          recovered_posted.status == null || !recovered_posted.status.ok()) begin
        `uvm_error("UD_RECV_REPLAY_WITNESS",
                   "recovered UD receive witness is incomplete")
        disable ud_receive_replay_flow;
      end

      polarity = 1'b0;
      cqe_status = fixture.engine.query_runtime_producer_polarity(
        fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, polarity);
      if (cqe_status == null || !cqe_status.ok()) begin
        `uvm_error("UD_RECV_REPLAY_POLARITY",
                   cqe_status == null ? "null UD CQ polarity status" :
                   cqe_status.convert2string())
        disable ud_receive_replay_flow;
      end
      cqe = make_cqe_for_outstanding_receive(
        fixture.ud_qp.handle, fixture.ud_qp.local_qp_id,
        recovered_posted, polarity, cqe_status);
      if (cqe_status == null || !cqe_status.ok() || cqe == null) begin
        `uvm_error("UD_RECV_REPLAY_CQE",
                   cqe_status == null ? "null UD receive CQE status" :
                   cqe_status.convert2string())
        disable ud_receive_replay_flow;
      end
      published = null;
      fixture.engine.publish_cqe(fixture.cq.handle, cqe, published, status);
      if (status == null || !status.ok() || published == null ||
          published.image == null || !published.occupancy_valid ||
          published.occupancy != 1) begin
        `uvm_error("UD_RECV_REPLAY_PUBLISH",
                   status == null ? "null UD receive publish status" :
                   status.convert2string())
        disable ud_receive_replay_flow;
      end
      completion = null;
      fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
      if (status == null || !status.ok() || completion == null ||
          completion.cqe == null || completion.cqe.rq_cqe != 1'b1 ||
          completion.cqe.variant != RDMA_CQE_VARIANT_RQ_SRFQ ||
          completion.cqe.qpn != fixture.ud_qp.local_qp_id ||
          completion.cqe.wr_id != request.wr_id ||
          completion.released_slots.size() != 1 ||
          completion.released_slots[0] == null ||
          completion.released_slots[0].wr_id != request.wr_id ||
          completion.completion_status == null ||
          !completion.completion_status.ok()) begin
        `uvm_error("UD_RECV_REPLAY_POLL",
                   status == null ? "null UD receive poll status" :
                   status.convert2string())
        disable ud_receive_replay_flow;
      end
      status = fixture.engine.query_runtime_occupancy(
        fixture.ud_qp.handle, RDMA_QUEUE_RUNTIME_RQ, used, pending_flag);
      if (status == null || !status.ok() || used != 0 || pending_flag)
        `uvm_error("UD_RECV_REPLAY_RQ_RELEASE",
                   status == null ? "null UD RQ release status" :
                   status.convert2string())
      status = fixture.engine.query_runtime_occupancy(
        fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, used, pending_flag);
      if (status == null || !status.ok() || used != 0 || pending_flag)
        `uvm_error("UD_RECV_REPLAY_CQ_RELEASE",
                   status == null ? "null UD CQ release status" :
                   status.convert2string())
      status = fixture.engine.query_runtime_cursors(
        fixture.ud_qp.handle, RDMA_QUEUE_RUNTIME_RQ, producer_index,
        producer_wrap, consumer_index, consumer_wrap);
      if (status == null || !status.ok() || producer_index != 1 ||
          producer_wrap != 1'b0 || consumer_index != 1 ||
          consumer_wrap != 1'b0)
        `uvm_error("UD_RECV_REPLAY_CURSOR",
                   status == null ? "null UD RQ cursor status" :
                   status.convert2string())
    end

    if (fixture != null && fixture.needs_cleanup()) begin
      fixture.cleanup(cleanup_status);
      if (cleanup_status == null || !cleanup_status.ok())
        `uvm_error("UD_RECV_REPLAY_CLEANUP",
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
    check_shared_srq_receive_cqe_e2e();
    check_ud_receive_replay_e2e();
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
