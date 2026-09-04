// 目录：测试层 unit/rdma_rq_engine_test.sv，覆盖 RQ facade 的转发契约。
// 职责：验证 RQ facade 复用共享 queue-data runtime，并隔离错误 Function 的接收请求。
// 依赖：rdma_core_pkg、现有 queue-data fixture、mock Host-memory/PCIe 后端。
// 所有权与生命周期：测试只拥有本地 fixture；facade 借用 delegate 和外部后端引用。

class rdma_rq_engine_test extends uvm_test;
  `uvm_component_utils(rdma_rq_engine_test)

  // 功能：创建 UVM RQ 测试组件并保存父组件关系，不分配队列或后端资源。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_rq_engine_test 构造只建立本地初始状态；本地 semaphore/ledger 等按构造体显式分配，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_rq_engine_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：配置 RQ facade 并验证 post_recv 的成功转发与 Function authority 校验。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：RQ handle 类型错误、跨 Function UID 或 backend 失败时不得产生接收结果。
  task run_phase(uvm_phase phase);
    rdma_queue_data_engine_fixture fixture;
    rdma_rq_engine facade;
    rdma_queue_post_result result;
    rdma_post_recv_req foreign_request;
    rdma_status status;

    phase.raise_objection(this);
    fixture = rdma_queue_data_engine_fixture::type_id::create("rq_fixture");
    fixture.setup(status);
    if (status == null || !status.ok()) begin
      `uvm_error("RQ_FIXTURE", "queue-data fixture setup failed")
      phase.drop_objection(this);
      return;
    end

    facade = rdma_rq_engine::type_id::create("rq_facade");
    status = facade.configure(fixture.manager, fixture.binding, fixture.mem,
                              fixture.scheduler, fixture.registry, 2us,
                              fixture.engine);
    if (status == null || !status.ok()) begin
      `uvm_error("RQ_CONFIGURE", "RQ facade configuration failed")
      phase.drop_objection(this);
      return;
    end

    facade.post_recv(fixture.make_recv(64'h3030), result, status);
    if (status == null || !status.ok() || result == null || result.index != 0 ||
        result.image == null)
      `uvm_error("RQ_FORWARD", "RQ facade did not publish delegate post result")

    foreign_request = fixture.make_recv(64'h4040);
    foreign_request.target_h.function_uid = fixture.binding.function_uid ^ 64'h1;
    result = null;
    facade.post_recv(foreign_request, result, status);
    if (status == null || status.ok() || result != null)
      `uvm_error("RQ_ISOLATION", "RQ facade accepted a foreign Function handle")

    phase.drop_objection(this);
  endtask
endclass
