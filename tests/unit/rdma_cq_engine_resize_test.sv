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
    rdma_resource before_resource;
    rdma_resource after_resource;
    rdma_cq before_cq;
    rdma_cq after_cq;
    rdma_dma_mapping before_mapping;
    rdma_dma_mapping after_mapping;
    rdma_queue_runtime_state_e sq_state;
    rdma_queue_runtime_state_e rq_state;
    int unsigned allocate_calls_before;
    int unsigned allocate_calls_after;
    int unsigned release_calls_before;
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

    // Snapshot the manager-authoritative CQ before every resize attempt.  The
    // ring mapping is an owned capability and must be replaced only after a
    // candidate has been fully validated.
    status = fixture.manager.lookup(fixture.cq.handle, before_resource);
    if (status == null || !status.ok() || !$cast(before_cq, before_resource) ||
        before_cq.queue_plan == null || before_cq.queue_plan.refs.size() == 0)
      `uvm_fatal("CQ_RESIZE_AUTH", "CQ authority snapshot failed")
    before_mapping = null;
    foreach (before_cq.queue_plan.refs[i])
      if (before_cq.queue_plan.refs[i] != null &&
          before_cq.queue_plan.refs[i].role == RDMA_QUEUE_ROLE_CQ_RING)
        before_mapping = before_cq.queue_plan.refs[i].mapping;
    if (before_mapping == null)
      `uvm_fatal("CQ_RESIZE_AUTH", "CQ ring mapping snapshot is missing")
    allocate_calls_before = 0;
    release_calls_before = 0;
    foreach (fixture.mem.calls[i]) begin
      if (fixture.mem.calls[i] != null && fixture.mem.calls[i].method_name == "allocate")
        allocate_calls_before++;
      if (fixture.mem.calls[i] != null && fixture.mem.calls[i].method_name == "release")
        release_calls_before++;
    end

    // An allocation failure must be observable and must leave both the
    // authority geometry and the old mapping untouched.
    fixture.mem.fail_next("allocate",
      rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED, "injected resize allocation failure"));
    status = facade.resize(fixture.cq.handle, 32, 128);
    if (status == null || status.ok())
      `uvm_error("CQ_RESIZE_ALLOC_FAIL", "allocation failure was accepted")
    status = fixture.manager.lookup(fixture.cq.handle, after_resource);
    if (status == null || !status.ok() || !$cast(after_cq, after_resource) ||
        after_cq.depth != before_cq.depth ||
        after_cq.cqe_size_bytes != before_cq.cqe_size_bytes ||
        after_cq.queue_plan == null || after_cq.queue_plan.refs.size() == 0)
      `uvm_error("CQ_RESIZE_ROLLBACK", "allocation failure changed CQ authority")
    after_mapping = null;
    foreach (after_cq.queue_plan.refs[i])
      if (after_cq.queue_plan.refs[i] != null &&
          after_cq.queue_plan.refs[i].role == RDMA_QUEUE_ROLE_CQ_RING)
        after_mapping = after_cq.queue_plan.refs[i].mapping;
    if (after_mapping == null || after_mapping.iova.value != before_mapping.iova.value ||
        after_mapping.size != before_mapping.size ||
        after_mapping.state != before_mapping.state)
      `uvm_error("CQ_RESIZE_ROLLBACK", "allocation failure changed CQ ring backing")
    allocate_calls_after = 0;
    foreach (fixture.mem.calls[j]) begin
      if (fixture.mem.calls[j] != null && fixture.mem.calls[j].method_name == "allocate")
        allocate_calls_after++;
    end
    if (allocate_calls_after != allocate_calls_before + 1)
      `uvm_error("CQ_RESIZE_ALLOC_CALL", "resize did not issue exactly one allocation")

    // A successful resize must allocate a fresh mapping sized for the new
    // geometry and publish that mapping and geometry atomically.
    status = facade.resize(fixture.cq.handle, 32, 128);
    if (status == null || !status.ok())
      `uvm_error("CQ_RESIZE_VALID", "valid resize was rejected")
    status = fixture.manager.lookup(fixture.cq.handle, after_resource);
    if (status == null || !status.ok() || !$cast(after_cq, after_resource) ||
        after_cq.depth != 32 || after_cq.cqe_size_bytes != 128 ||
        after_cq.queue_plan == null || after_cq.queue_plan.rings.size() != 1 ||
        after_cq.queue_plan.rings[0].depth != 32 ||
        after_cq.queue_plan.rings[0].entry_size_bytes != 128 ||
        after_cq.queue_plan.refs.size() == 0)
      `uvm_error("CQ_RESIZE_AUTHORITY", "successful resize geometry was not published")
    after_mapping = null;
    foreach (after_cq.queue_plan.refs[i])
      if (after_cq.queue_plan.refs[i] != null &&
          after_cq.queue_plan.refs[i].role == RDMA_QUEUE_ROLE_CQ_RING)
        after_mapping = after_cq.queue_plan.refs[i].mapping;
    if (after_mapping == null ||
        after_mapping.size < 32 * 128 ||
        after_mapping.iova.value == before_mapping.iova.value)
      `uvm_error("CQ_RESIZE_MAPPING", "successful resize did not replace mapping identity/size")
    status = fixture.engine.query_runtime_state(
      fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, sq_state);
    if (status == null || !status.ok() || sq_state != RDMA_QUEUE_RUNTIME_ACTIVE)
      `uvm_error("CQ_RESIZE_DEPENDENT_SQ", "SQ dependent runtime was not restored ACTIVE")
    status = fixture.engine.query_runtime_state(
      fixture.qp.handle, RDMA_QUEUE_RUNTIME_RQ, rq_state);
    if (status == null || !status.ok() || rq_state != RDMA_QUEUE_RUNTIME_ACTIVE)
      `uvm_error("CQ_RESIZE_DEPENDENT_RQ", "RQ dependent runtime was not restored ACTIVE")

    // Invalid geometry is rejected before allocation and leaves the newly
    // published mapping/authority unchanged.
    allocate_calls_before = 0;
    foreach (fixture.mem.calls[i])
      if (fixture.mem.calls[i] != null && fixture.mem.calls[i].method_name == "allocate")
        allocate_calls_before++;
    status = facade.resize(fixture.cq.handle, 7, 64);
    if (status == null || status.ok())
      `uvm_error("CQ_RESIZE_GEOMETRY", "invalid resize geometry was accepted")
    status = fixture.manager.lookup(fixture.cq.handle, before_resource);
    if (status == null || !status.ok() || !$cast(before_cq, before_resource) ||
        before_cq.depth != 32 || before_cq.cqe_size_bytes != 128 ||
        before_cq.queue_plan == null || before_cq.queue_plan.refs.size() == 0)
      `uvm_error("CQ_RESIZE_GEOMETRY_ROLLBACK", "invalid resize changed authority")
    before_mapping = null;
    foreach (before_cq.queue_plan.refs[i])
      if (before_cq.queue_plan.refs[i] != null &&
          before_cq.queue_plan.refs[i].role == RDMA_QUEUE_ROLE_CQ_RING)
        before_mapping = before_cq.queue_plan.refs[i].mapping;
    if (before_mapping == null || before_mapping.iova.value != after_mapping.iova.value ||
        before_mapping.size != after_mapping.size ||
        before_mapping.state != after_mapping.state)
      `uvm_error("CQ_RESIZE_GEOMETRY_ROLLBACK", "invalid resize changed CQ ring backing")
    allocate_calls_after = 0;
    foreach (fixture.mem.calls[j])
      if (fixture.mem.calls[j] != null && fixture.mem.calls[j].method_name == "allocate")
        allocate_calls_after++;
    if (allocate_calls_after != allocate_calls_before)
      `uvm_error("CQ_RESIZE_GEOMETRY_ALLOC", "invalid geometry unexpectedly allocated backing")
    layout = rdma_cqe_layout::for_bytes(128, 16);
    layout.bytes = 48;
    if (layout.valid())
      `uvm_error("CQ_LAYOUT_MUTATION", "tampered layout was accepted")
    phase.drop_objection(this);
  endtask
endclass
