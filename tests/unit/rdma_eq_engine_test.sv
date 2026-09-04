// 目录：测试层 unit/rdma_eq_engine_test.sv，覆盖 CEQ/AEQ facade 的消费入口。
// 职责：验证 EQ facade 将 CEQ/AEQ 查询交给共享 runtime，并拒绝把 CEQ handle 当作 AEQ 使用。
// 依赖：rdma_core_pkg、queue-data fixture、mock Host-memory/PCIe 后端。
// 所有权与生命周期：测试只拥有本地 fixture；EQ facade 借用共享 delegate 和 router 引用。

class rdma_eq_engine_test extends uvm_test;
  `uvm_component_utils(rdma_eq_engine_test)

  // 功能：创建 UVM EQ 测试组件并保存父组件关系，不预先登记事件队列。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：CEQ/AEQ attachment 由 run_phase 显式建立，失败时停止后续访问；非零超时的空环返回 TIMEOUT。
  function new(string name = "rdma_eq_engine_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：配置 EQ facade，消费空 CEQ 并验证 AEQ 入口不会复用错误的 CEQ attachment。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：未登记的 AEQ、错误 Function 或 stale handle 必须返回错误且不发布 event。
  task run_phase(uvm_phase phase);
    rdma_queue_data_engine_fixture fixture;
    rdma_eq_engine facade;
    rdma_queue_event_result event_result;
    rdma_create_ceq_req ceq_request;
    rdma_queue_resource ceq_resource;
    rdma_control_result create_result;
    rdma_ceq runtime_ceq;
    rdma_status status;

    phase.raise_objection(this);
    fixture = rdma_queue_data_engine_fixture::type_id::create("eq_fixture");
    fixture.setup(status);
    if (status == null || !status.ok()) begin
      `uvm_error("EQ_FIXTURE", "queue-data fixture setup failed")
      phase.drop_objection(this);
      return;
    end
    // fixture.ceq is a dependency-only resource created before the CQ and has
    // no queue plan.  Build a lifecycle-owned CEQ here so the facade exercises
    // the real Host-memory ring/backing contract instead of a synthetic handle.
    ceq_request = rdma_create_ceq_req::type_id::create("eq_ceq_request");
    ceq_request.owner = fixture.binding.make_handle();
    ceq_request.depth = 16;
    ceq_request.vector_id = 1;
    ceq_request.ring_backing.mode = RDMA_QUEUE_BACKING_OWNED;
    fixture.queue_executor.create_locked(fixture.binding,
                                         fixture.binding.make_handle(),
                                         ceq_request, 64'h1003,
                                         ceq_resource, create_result);
    if (create_result == null || create_result.status == null ||
        !create_result.status.ok() || ceq_resource == null ||
        !$cast(runtime_ceq, ceq_resource)) begin
      `uvm_error("EQ_CREATE", create_result == null || create_result.status == null ?
                 "CEQ lifecycle create returned no status" :
                 create_result.status.convert2string())
      phase.drop_objection(this);
      return;
    end
    status = fixture.engine.attach_ceq(runtime_ceq.handle);
    if (status == null || !status.ok()) begin
      `uvm_error("EQ_ATTACH", status == null ? "CEQ attachment setup failed: null status" :
                 status.convert2string())
      phase.drop_objection(this);
      return;
    end

    facade = rdma_eq_engine::type_id::create("eq_facade");
    status = facade.configure(fixture.manager, fixture.binding, fixture.mem,
                              fixture.scheduler, fixture.registry, 2us,
                              fixture.engine);
    if (status == null || !status.ok()) begin
      `uvm_error("EQ_CONFIGURE", "EQ facade configuration failed")
      phase.drop_objection(this);
      return;
    end

    facade.poll_ceqe(runtime_ceq.handle, event_result, status);
    // The configured non-zero timeout is forwarded to the shared engine, so
    // an empty CEQ is reported as TIMEOUT after the wait interval.
    if (status == null || status.code != RDMA_SC_TIMEOUT || event_result != null)
      `uvm_error("CEQ_FORWARD", "EQ facade did not forward empty CEQ poll")

    event_result = null;
    facade.poll_aeqe(runtime_ceq.handle, event_result, status);
    if (status == null || status.ok() || event_result != null)
      `uvm_error("AEQ_KIND", "EQ facade accepted a CEQ handle in AEQ path")

    phase.drop_objection(this);
  endtask
endclass
