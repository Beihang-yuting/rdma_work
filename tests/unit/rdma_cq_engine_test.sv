// 目录：测试层 unit/rdma_cq_engine_test.sv，覆盖 CQ facade 的消费顺序契约。
// 职责：验证 CQ facade 复用共享 runtime，完成 CQE 解码、CI 提交和 completion 发布。
// 依赖：rdma_core_pkg、queue-data fixture、XTR v1 CQE codec 和 mock Host-memory 后端。
// 所有权与生命周期：测试只拥有本地 fixture；CQ facade 不拥有 runtime 或 backing mapping。

class rdma_cq_engine_test extends uvm_test;
  `uvm_component_utils(rdma_cq_engine_test)

  // 功能：创建 UVM CQ 测试组件并建立父组件关系，不访问设备资源。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cq_engine_test 构造只建立本地初始状态；本地 semaphore/ledger 等按构造体显式分配，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cq_engine_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：配置 CQ facade，向共享 CQ runtime 注入一条 CQE，并验证 CI 提交后只消费一次。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：CQE owner、QPN 或 Function 不匹配时不应发布 completion；配置了非零超时时空槽位返回 TIMEOUT。
  task run_phase(uvm_phase phase);
    rdma_queue_data_engine_fixture fixture;
    rdma_cq_engine facade;
    rdma_queue_post_result posted;
    rdma_queue_completion_result completion;
    rdma_hw_cqe_model cqe;
    rdma_status status;

    phase.raise_objection(this);
    fixture = rdma_queue_data_engine_fixture::type_id::create("cq_fixture");
    fixture.setup(status);
    if (status == null || !status.ok()) begin
      `uvm_error("CQ_FIXTURE", "queue-data fixture setup failed")
      phase.drop_objection(this);
      return;
    end

    facade = rdma_cq_engine::type_id::create("cq_facade");
    status = facade.configure(fixture.manager, fixture.binding, fixture.mem,
                              fixture.scheduler, fixture.registry, 2us,
                              fixture.engine);
    if (status == null || !status.ok()) begin
      `uvm_error("CQ_CONFIGURE", "CQ facade configuration failed")
      phase.drop_objection(this);
      return;
    end

    fixture.engine.post_send(fixture.make_send(64'h5050), posted, status);
    if (status == null || !status.ok() || posted == null) begin
      `uvm_error("CQ_POST", "CQ fixture WQE post failed")
      phase.drop_objection(this);
      return;
    end
    cqe = rdma_hw_cqe_model::type_id::create("cq_device_entry");
    cqe.qp_h = rdma_clone_handle_value(fixture.qp.handle, "CQ facade QP");
    cqe.qpn = fixture.qp.local_qp_id;
    cqe.wqe_index = posted.index;
    cqe.wqe_wrap = posted.wrap;
    cqe.rq_cqe = 1'b0;
    cqe.polarity = 1'b1;
    cqe.packet_opcode = 8'h01;
    cqe.ecode = RDMA_CMQ_SUCCESS_ECODE;
    cqe.payload_len = 32;
    cqe.status = rdma_status::success();
    status = fixture.write_cq_entry(0, cqe);
    if (status == null || !status.ok()) begin
      `uvm_error("CQ_WRITE", "CQ fixture could not write device CQE")
      phase.drop_objection(this);
      return;
    end

    facade.poll_cqe(fixture.cq.handle, completion, status);
    if (status == null || !status.ok() || completion == null ||
        completion.cqe == null || completion.cqe.wr_id != 64'h5050)
      `uvm_error("CQ_FORWARD", "CQ facade did not publish decoded completion")

    completion = null;
    facade.poll_cqe(fixture.cq.handle, completion, status);
    // The non-zero facade timeout intentionally maps an empty next slot to
    // TIMEOUT.  That result proves CI advanced: a stale CI would revisit the
    // same CQE and fail WQE-release validation instead of timing out.
    if (status == null || status.code != RDMA_SC_TIMEOUT || completion != null)
      `uvm_error("CQ_CI", $sformatf("CQ facade did not preserve CI commit semantics: status=%s completion=%p",
                                      status == null ? "<null>" : status.convert2string(),
                                      completion))

    phase.drop_objection(this);
  endtask
endclass
