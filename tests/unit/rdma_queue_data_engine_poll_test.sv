// 目录：测试层 unit/rdma_queue_data_engine_poll_test.sv。
// 职责：验证 rdma_queue_data_engine_poll_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_queue_data_engine_poll_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_queue_data_engine_poll_test extends uvm_test;
  `uvm_component_utils(rdma_queue_data_engine_poll_test)

  // 功能：构造 rdma_queue_data_engine_poll_test，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_data_engine_poll_test 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_data_engine_poll_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：在 rdma_queue_data_engine_poll_test 中，run_phase 驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：run_phase 的 setup/阶段驱动失败时停止新增事务，并按测试生命周期清理 objection 与临时引用。
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
    fixture.setup(status);
    if (status == null || !status.ok()) begin
      `uvm_error("FIXTURE_SETUP", status == null ? "null setup status" :
                 status.convert2string())
      phase.drop_objection(this);
      return;
    end

    send_request = fixture.make_send(64'h1111_2222_3333_4444);
    fixture.engine.post_send(send_request, posted, status);
    if (status == null || !status.ok() || posted == null) begin
      `uvm_error("POLL_SETUP_POST", status == null ? "null status" :
                 status.convert2string())
      phase.drop_objection(this);
      return;
    end

    // Device-side CQE production is modeled by writing a canonical 64-byte
    // entry into the lifecycle-owned CQ backing.  The polarity is the
    // literal initial owner bit from the XTR ring contract.
    cqe = rdma_hw_cqe_model::type_id::create("device_cqe");
    cqe.qp_h = rdma_clone_handle_value(fixture.qp.handle, "device CQE QP");
    cqe.qpn = fixture.qp.local_qp_id;
    cqe.wqe_index = posted.index;
    cqe.wqe_wrap = posted.wrap;
    cqe.rq_cqe = 1'b0;
    cqe.polarity = 1'b1;
    cqe.packet_opcode = 8'h01;
    cqe.ecode = RDMA_CMQ_SUCCESS_ECODE;
    cqe.payload_len = 32;
    cqe_status = rdma_status::success();
    cqe.status = cqe_status;
    status = fixture.write_cq_entry(0, cqe);
    if (status == null || !status.ok()) begin
      `uvm_error("POLL_SETUP_CQE", status == null ? "null status" :
                 status.convert2string())
      phase.drop_objection(this);
      return;
    end

    completion = null;
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
    // This assertion intentionally exercises the complete read/decode/route/
    // CI-doorbell/ledger-release transaction.  It fails against an engine
    // that checks released_slots before invoking match_and_release().
    if (status == null || !status.ok() || completion == null ||
        completion.cqe == null || completion.cqe.qpn != fixture.qp.local_qp_id ||
        completion.cqe.wr_id != send_request.wr_id ||
        completion.completion_status == null ||
        !completion.completion_status.ok())
      `uvm_error("POLL_CQE", status == null ? "null status" :
                 status.convert2string())
    if (fixture.cq.queue_plan == null || fixture.cq.queue_plan.context_ref == null)
      `uvm_error("POLL_CQE_CONTEXT", "CQ fixture lost lifecycle backing")

    // CI commit must advance the CQ runtime.  The backing entry remains in
    // memory, so a stale CI would consume the same CQE a second time instead
    // of observing the next (empty) slot.
    completion = null;
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
    if (status == null || status.code != RDMA_SC_QUEUE_EMPTY ||
        completion != null)
      `uvm_error("POLL_CQE_CI", status == null ? "null status" :
                 status.convert2string())

    phase.drop_objection(this);
  endtask
endclass
