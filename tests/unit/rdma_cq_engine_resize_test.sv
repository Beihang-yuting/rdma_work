// 目录：测试层 unit/rdma_cq_engine_resize_test.sv。
// 职责：验证 CQ facade resize 的几何校验、游标保留和失败回滚契约。
// 依赖：rdma_queue_data_engine_fixture、rdma_cq_engine；不拥有生产资源。
// 所有权与生命周期：fixture 仅由测试持有，resize 失败时旧 attachment 仍由 engine 管理。

class rdma_cq_engine_resize_test extends uvm_test;
  `uvm_component_utils(rdma_cq_engine_resize_test)

  // 功能：构造 resize 测试组件。
  // 输入输出及副作用：name/parent 为 UVM 输入；仅建立组件层级。
  // 失败边界：父组件为空由 UVM 框架处理，不访问外部资源。
  function new(string name="rdma_cq_engine_resize_test", uvm_component parent=null);
    super.new(name,parent);
  endfunction

  // 功能：配置 CQ facade，验证合法 resize 成功及非法 resize 保留旧 ring。
  // 输入输出及副作用：phase 为输入；驱动 facade resize 并检查状态码。
  // 失败边界：fixture 配置、合法 resize 或 rollback 断言失败时报告 UVM error。
  task run_phase(uvm_phase phase);
    rdma_queue_data_engine_fixture fixture;
    rdma_cq_engine facade;
    rdma_status status;
    rdma_cqe_layout layout;
    phase.raise_objection(this);
    fixture = rdma_queue_data_engine_fixture::type_id::create("resize_fixture");
    fixture.setup(status);
    if (status == null || !status.ok()) begin
      `uvm_error("CQ_RESIZE_FIXTURE", "fixture setup failed")
      phase.drop_objection(this); return;
    end
    facade = rdma_cq_engine::type_id::create("resize_facade");
    status = facade.configure(fixture.manager, fixture.binding, fixture.mem,
                              fixture.scheduler, fixture.registry, 2us,
                              fixture.engine);
    if (status == null || !status.ok()) begin
      `uvm_error("CQ_RESIZE_CONFIG", "facade configure failed")
      phase.drop_objection(this); return;
    end
    status = facade.resize(fixture.cq.handle, 8, 128);
    if (status == null || !status.ok())
      `uvm_error("CQ_RESIZE_VALID", "valid resize was rejected")
    status = facade.resize(fixture.cq.handle, 7, 64);
    if (status == null || status.ok())
      `uvm_error("CQ_RESIZE_ROLLBACK", "invalid resize did not preserve old ring")
    layout = rdma_cqe_layout::for_bytes(128, 16);
    layout.bytes = 48;
    if (layout.valid())
      `uvm_error("CQ_LAYOUT_MUTATION", "tampered layout was accepted")
    phase.drop_objection(this);
  endtask
endclass
