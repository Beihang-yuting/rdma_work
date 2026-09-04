// 目录：测试层 unit/rdma_sq_engine_test.sv，覆盖 SQ facade 的转发契约。
// 职责：验证 SQ facade 只调用共享 queue-data runtime，并在 Function 身份失配时拒绝请求。
// 依赖：rdma_core_pkg、现有 queue-data fixture、mock Host-memory/PCIe 后端。
// 所有权与生命周期：测试只拥有本地 fixture；facade 和 delegate 的生命周期由本测试管理，
// 外部后端引用不由 facade 接管。

class rdma_sq_engine_test extends uvm_test;
  `uvm_component_utils(rdma_sq_engine_test)

  // 功能：创建 UVM 测试组件并保留父组件关系，不初始化任何外部队列资源。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：参数为空时仍交由 UVM 处理，真正的依赖校验在 run_phase 中完成。
  function new(string name = "rdma_sq_engine_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：配置 SQ facade，验证 post_send 转发到唯一 queue-data engine，并检查跨 Function 请求被隔离。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：共享 delegate 未配置、请求为空或 Function UID/generation 不一致时不得发布结果。
  task run_phase(uvm_phase phase);
    rdma_queue_data_engine_fixture fixture;
    rdma_sq_engine facade;
    rdma_queue_post_result result;
    rdma_post_send_req foreign_request;
    rdma_status status;

    phase.raise_objection(this);
    fixture = rdma_queue_data_engine_fixture::type_id::create("sq_fixture");
    fixture.setup(status);
    if (status == null || !status.ok()) begin
      `uvm_error("SQ_FIXTURE", "queue-data fixture setup failed")
      phase.drop_objection(this);
      return;
    end

    facade = rdma_sq_engine::type_id::create("sq_facade");
    status = facade.configure(fixture.manager, fixture.binding, fixture.mem,
                              fixture.scheduler, fixture.registry, 2us,
                              fixture.engine);
    if (status == null || !status.ok()) begin
      `uvm_error("SQ_CONFIGURE", "SQ facade configuration failed")
      phase.drop_objection(this);
      return;
    end

    facade.post_send(fixture.make_send(64'h1010), result, status);
    if (status == null || !status.ok() || result == null || result.index != 0 ||
        result.image == null)
      `uvm_error("SQ_FORWARD", "SQ facade did not publish delegate post result")

    // Same local QP number is not sufficient authority: a foreign Function UID
    // must be rejected before the shared runtime can reserve another slot.
    foreign_request = fixture.make_send(64'h2020);
    foreign_request.qp_h.function_uid = fixture.binding.function_uid ^ 64'h1;
    result = null;
    facade.post_send(foreign_request, result, status);
    if (status == null || status.ok() || result != null)
      `uvm_error("SQ_ISOLATION", "SQ facade accepted a foreign Function handle")

    phase.drop_objection(this);
  endtask
endclass
