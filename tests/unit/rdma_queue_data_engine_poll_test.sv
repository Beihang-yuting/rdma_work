// 中文说明：rdma_queue_data_engine_poll_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_queue_data_engine_poll_test extends uvm_test;
  `uvm_component_utils(rdma_queue_data_engine_poll_test)

  function new(string name = "rdma_queue_data_engine_poll_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

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
