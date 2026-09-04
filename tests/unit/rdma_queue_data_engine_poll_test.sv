// 目录：测试层 unit/rdma_queue_data_engine_poll_test.sv。
// 职责：验证 rdma_queue_data_engine_poll_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_queue_data_engine_poll_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_queue_data_engine_poll_test extends uvm_test;
  `uvm_component_utils(rdma_queue_data_engine_poll_test)

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_queue_data_engine_poll_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase 控制 UVM 调度；task 驱动事务、断言和 objection，测试 fixture 由本层负责清理。
  //   阶段提前结束或前置 setup 失败时必须释放 objection 并停止后续访问。
  // 失败/边界：setup 失败或阶段被终止时停止新增事务，确保 objection、临时对象和外部引用按测试生命周期收尾。
  task run_phase(uvm_phase phase);
    rdma_queue_data_engine engine;
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_completion_result completion;
    rdma_queue_post_result posted;
    rdma_queue_event_result event_result;
    rdma_status status;
    rdma_post_send_req send_request;
    rdma_xtr_v1_cqe_model cqe;
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
    cqe = rdma_xtr_v1_cqe_model::type_id::create("device_cqe");
    cqe.qp_h = rdma_clone_handle_value(fixture.qp.handle, "device CQE QP");
    cqe.qpn = fixture.qp.local_qp_id;
    cqe.wqe_index = posted.index;
    cqe.wqe_wrap = posted.wrap;
    cqe.rq_cqe = 1'b0;
    cqe.polarity = 1'b1;
    cqe.packet_opcode = 8'h01;
    cqe.ecode = XTR_V1_CMQ_SUCCESS_ECODE;
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
