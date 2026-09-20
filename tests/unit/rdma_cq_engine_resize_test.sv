// 目录：测试层 unit/rdma_cq_engine_resize_test.sv。
// 职责：验证 CQ facade resize 的几何校验、游标保留和失败回滚契约。
// 依赖：rdma_queue_data_engine_fixture、rdma_cq_engine；不拥有生产资源。
// 所有权与生命周期：fixture 仅由测试持有，resize 失败时旧 attachment 仍由 engine 管理。

// 功能：为 CQ resize 回归注入指定 runtime 的 begin/restore 失败，模拟
//       dependent quiesce 部分成功后后端恢复连续失败的故障窗口。
// 输入/输出及副作用：静态注入开关只影响本测试创建的 runtime；super 调用
//       保留正常 runtime 的状态迁移和账本语义。
// 失败/边界：只对匹配 kind 的下一次 begin 或有限次数 restore 返回故障，
//       计数耗尽后自动回到正常实现，不修改生产 runtime 的默认行为。
class rdma_resize_fault_runtime extends rdma_queue_runtime;
  `uvm_object_utils(rdma_resize_fault_runtime)

  static rdma_queue_runtime_kind_e fail_begin_kind;
  static bit fail_begin_once;
  static rdma_queue_runtime_kind_e fail_restore_kind;
  static int unsigned restore_failures;

  // 功能：构造故障注入 runtime，保持基类默认的 detached 状态和空账本。
  // 输入/输出及副作用：name（输入）；仅建立 UVM 对象，不分配外部 backing。
  // 失败/边界：构造不会触发注入；注入开关由测试 task 显式设置并清理。
  function new(string name = "rdma_resize_fault_runtime");
    super.new(name);
  endfunction

  // 功能：在匹配的 dependent runtime 首次 begin_quiesce 时注入失败，
  //       让同一 resize 事务出现“前一项已切换、后一项拒绝”的部分进度。
  // 输入/输出及副作用：无显式参数；匹配时只消费静态一次性开关，
  //       不改变 runtime state；否则调用基类并执行真实状态迁移。
  // 失败/边界：仅当 fail_begin_once 且 kind 等于 fail_begin_kind 时返回
  //       RESOURCE_BUSY；其余调用保持基类对 state/pending/used 的检查。
  virtual function rdma_status begin_quiesce();
    if (fail_begin_once && kind == fail_begin_kind) begin
      fail_begin_once = 1'b0;
      return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                               "injected dependent begin quiesce failure");
    end
    return super.begin_quiesce();
  endfunction

  // 功能：在匹配的 dependent runtime restore_active 时按计数注入故障，
  //       覆盖 quiesce 内部回滚和 abort/retry 两个连续恢复点。
  // 输入/输出及副作用：无显式参数；匹配且计数非零时只递减注入计数，
  //       保留 QUIESCING state；否则调用基类恢复 ACTIVE。
  // 失败/边界：计数耗尽后恢复正常；非匹配 kind 不消费计数，也不改变状态。
  virtual function rdma_status restore_active();
    if (restore_failures != 0 && kind == fail_restore_kind) begin
      restore_failures--;
      return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                               "injected dependent restore failure");
    end
    return super.restore_active();
  endfunction
endclass

class rdma_cq_engine_resize_test extends uvm_test;
  `uvm_component_utils(rdma_cq_engine_resize_test)

  // 功能：构造 resize 测试组件。
  // 输入/输出及副作用：name/parent 为 UVM 输入；仅建立组件层级。
  // 失败/边界：父组件为空由 UVM 框架处理，不访问外部资源。
  function new(string name="rdma_cq_engine_resize_test", uvm_component parent=null);
    super.new(name,parent);
  endfunction

  // 功能：make_resize_rc_attrs 为本测试创建第二个 RC QP 所需的独立上下文属性，
  // 使该 QP 可以把共享 SRQ 作为 receive source 并挂接到被 resize 的 CQ。
  // 输入/输出及副作用：name 为对象命名输入；函数返回深度独立的
  // rdma_qp_context_attributes，不修改 fixture、manager 或 Host-memory。
  // 失败/边界：任一 UVM 子对象创建失败会返回带空字段的属性对象，后续 QP
  // request.validate/生命周期执行器必须拒绝该请求而不能发布半成品 QP。
  function automatic rdma_qp_context_attributes make_resize_rc_attrs(string name);
    rdma_qp_context_attributes attrs;
    rdma_qpc_rc_ext ext;

    attrs = rdma_qp_context_attributes::type_id::create({name, "_attrs"});
    attrs.path_mtu_bytes = 4096;
    attrs.pkey = 16'hbeef;
    attrs.address_vector = rdma_address_vector::type_id::create({name, "_av"});
    attrs.address_vector.destination_mac = 48'h1122_3344_5566;
    attrs.address_vector.traffic_class = 8'h02;
    attrs.behavior = rdma_qpc_behavior::type_id::create({name, "_behavior"});
    attrs.behavior.transport_version = 1;
    ext = rdma_qpc_rc_ext::type_id::create({name, "_rc"});
    ext.remote_qpn = 24'h456789;
    ext.send_psn = 24'h123456;
    ext.recv_psn = 24'h654321;
    ext.retry_count = 2;
    ext.rnr_retry_count = 2;
    attrs.transport_ext = ext;
    return attrs;
  endfunction

  // 功能：配置 CQ facade，验证合法 resize 成功及非法 resize 保留旧 ring。
  // 输入/输出及副作用：phase 为输入；驱动 facade resize 并检查状态码，
  //       只修改本测试 fixture 的 backing 和 runtime。
  // 失败/边界：fixture 配置、合法 resize 或 rollback 断言失败时报告 UVM
  //       error；所有外部 mapping 在 task 结束前由 fixture 清理。
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
    longint unsigned same_size_mapping_iova;
    int unsigned same_size_allocate_calls;
    int unsigned live_before_cleanup_failure;
    int unsigned live_after_cleanup_failure;
    int unsigned live_after_cleanup_retry;
    rdma_create_srq_req srq_request;
    rdma_create_qp_req srq_qp_request;
    rdma_queue_resource srq_resource;
    rdma_control_result srq_result;
    rdma_srq srq;
    rdma_qp srq_qp;
    rdma_queue_runtime_state_e srq_state;
    rdma_handle recovery_retry_h;
    int unsigned original_generation;
    phase.raise_objection(this);

    // 让 engine 创建的 runtime 使用可注入子类；本场景先验证部分
    // dependent quiesce 失败时，恢复 authority 是否被持久化，再清除注入
    // 继续执行本测试其余 resize 覆盖。
    rdma_queue_runtime::type_id::set_type_override(
      rdma_resize_fault_runtime::get_type());
    rdma_resize_fault_runtime::fail_begin_kind = RDMA_QUEUE_RUNTIME_RQ;
    rdma_resize_fault_runtime::fail_begin_once = 1'b1;
    rdma_resize_fault_runtime::fail_restore_kind = RDMA_QUEUE_RUNTIME_SQ;
    rdma_resize_fault_runtime::restore_failures = 2;
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

    // authority 漂移门禁：resize 必须在触碰 delegate 前拒绝旧 generation，
    // 且不能分配候选 backing 或改变 manager-authoritative CQ ring。
    begin : generation_drift_resize_gate
      rdma_status drift_status;
      rdma_resource drift_before_resource;
      rdma_resource drift_after_resource;
      rdma_cq drift_before_cq;
      rdma_cq drift_after_cq;
      rdma_dma_mapping drift_before_mapping;
      rdma_dma_mapping drift_after_mapping;
      int unsigned saved_generation;
      int unsigned allocate_count_before;
      int unsigned allocate_count_after;

      drift_status = fixture.manager.lookup(fixture.cq.handle,
                                             drift_before_resource);
      if (drift_status == null || !drift_status.ok() ||
          !$cast(drift_before_cq, drift_before_resource))
        `uvm_error("CQ_RESIZE_AUTHORITY_DRIFT",
                   "generation-drift precondition lookup failed")
      drift_before_mapping = null;
      if (drift_before_cq != null && drift_before_cq.queue_plan != null)
        foreach (drift_before_cq.queue_plan.refs[i])
          if (drift_before_cq.queue_plan.refs[i] != null &&
              drift_before_cq.queue_plan.refs[i].role == RDMA_QUEUE_ROLE_CQ_RING)
            drift_before_mapping = drift_before_cq.queue_plan.refs[i].mapping;

      allocate_count_before = 0;
      foreach (fixture.mem.calls[i])
        if (fixture.mem.calls[i] != null &&
            fixture.mem.calls[i].method_name == "allocate")
          allocate_count_before++;

      saved_generation = fixture.binding.generation;
      fixture.binding.generation = saved_generation + 1;
      drift_status = facade.resize(fixture.cq.handle, 32, 128);
      if (drift_status == null ||
          drift_status.code != RDMA_SC_STALE_GENERATION)
        `uvm_error("CQ_RESIZE_AUTHORITY_DRIFT",
                   "generation drift was not rejected as STALE_GENERATION")

      fixture.binding.generation = saved_generation;
      drift_status = fixture.manager.lookup(fixture.cq.handle,
                                             drift_after_resource);
      if (drift_status == null || !drift_status.ok() ||
          !$cast(drift_after_cq, drift_after_resource) ||
          drift_after_cq.depth != drift_before_cq.depth ||
          drift_after_cq.cqe_size_bytes != drift_before_cq.cqe_size_bytes)
        `uvm_error("CQ_RESIZE_AUTHORITY_DRIFT",
                   "generation drift changed CQ geometry")
      drift_after_mapping = null;
      if (drift_after_cq != null && drift_after_cq.queue_plan != null)
        foreach (drift_after_cq.queue_plan.refs[i])
          if (drift_after_cq.queue_plan.refs[i] != null &&
              drift_after_cq.queue_plan.refs[i].role == RDMA_QUEUE_ROLE_CQ_RING)
            drift_after_mapping = drift_after_cq.queue_plan.refs[i].mapping;
      if (drift_before_mapping == null || drift_after_mapping == null ||
          drift_after_mapping.iova.value != drift_before_mapping.iova.value)
        `uvm_error("CQ_RESIZE_AUTHORITY_DRIFT",
                   "generation drift replaced CQ ring backing")
      allocate_count_after = 0;
      foreach (fixture.mem.calls[i])
        if (fixture.mem.calls[i] != null &&
            fixture.mem.calls[i].method_name == "allocate")
          allocate_count_after++;
      if (allocate_count_after != allocate_count_before)
        `uvm_error("CQ_RESIZE_AUTHORITY_DRIFT",
                   "generation drift invoked backing allocation")
    end

    status = facade.resize(fixture.cq.handle, 32, 64);
    if (status == null || status.code != RDMA_SC_RECOVERY_REQUIRED)
      `uvm_error("CQ_RESIZE_DEPENDENT_RECOVERY",
                 "dependent restore failure was not retained as recovery")
    if (!fixture.engine.has_pending_cq_resize(fixture.cq.handle))
      `uvm_error("CQ_RESIZE_DEPENDENT_RECOVERY",
                 "dependent restore failure lost CQ recovery authority")
    rdma_resize_fault_runtime::fail_begin_once = 1'b0;
    rdma_resize_fault_runtime::restore_failures = 0;
    status = fixture.engine.retry_cq_resize_cleanup(fixture.cq.handle);
    if (status == null || !status.ok())
      `uvm_error("CQ_RESIZE_DEPENDENT_RECOVERY",
                 "dependent restore recovery retry did not complete")

    // 额外建立一个使用共享 SRQ 的 RC QP，直接覆盖 CQ resize 对 SRQ
    // dependent runtime 的 quiesce/restore 路径；该 fixture 只在本测试中
    // 增加，不改变其他 queue-data-engine 测试的默认资源拓扑。
    srq_request = rdma_create_srq_req::type_id::create("resize_srq_request");
    srq_request.owner = fixture.binding.make_handle();
    srq_request.depth = 64;
    srq_request.max_sge = 2;
    srq_request.limit_threshold = 16;
    srq_request.pd_h = rdma_clone_handle_value(fixture.pd.handle,
                                                "resize SRQ PD");
    srq_request.payload_backing.mode = RDMA_QUEUE_BACKING_OWNED;
    fixture.queue_executor.create_locked(
      fixture.binding, fixture.binding.make_handle(), srq_request, 64'h1003,
      srq_resource, srq_result);
    if (srq_result == null || !srq_result.ok() ||
        !$cast(srq, srq_resource) || srq == null) begin
      `uvm_error("CQ_RESIZE_SRQ_SETUP", "shared SRQ fixture creation failed")
    end
    else begin
      srq_qp_request = rdma_create_qp_req::type_id::create(
        "resize_srq_qp_request");
      srq_qp_request.owner = fixture.binding.make_handle();
      srq_qp_request.transport = RDMA_TRANSPORT_RC;
      srq_qp_request.sq_depth = 16;
      srq_qp_request.rq_depth = srq.depth;
      srq_qp_request.max_send_sge = 4;
      srq_qp_request.max_recv_sge = 4;
      srq_qp_request.max_inline_data = 512;
      srq_qp_request.sq_backing.mode = RDMA_QUEUE_BACKING_OWNED;
      srq_qp_request.sq_sgb_backing.mode = RDMA_QUEUE_BACKING_OWNED;
      srq_qp_request.rq_backing.mode = RDMA_QUEUE_BACKING_OWNED;
      srq_qp_request.pd_h = rdma_clone_handle_value(fixture.pd.handle,
                                                     "resize SRQ QP PD");
      srq_qp_request.send_cq_h = rdma_clone_handle_value(
        fixture.cq.handle, "resize SRQ QP send CQ");
      srq_qp_request.recv_cq_h = rdma_clone_handle_value(
        fixture.cq.handle, "resize SRQ QP receive CQ");
      srq_qp_request.srq_h = rdma_clone_handle_value(
        srq.handle, "resize SRQ QP source");
      srq_qp_request.context_attrs = make_resize_rc_attrs(
        "resize_srq_qp");
      fixture.qp_executor.create_locked(
        fixture.binding, fixture.binding.make_handle(), srq_qp_request,
        64'h1004, srq_qp, srq_result);
      if (srq_result == null || !srq_result.ok() || srq_qp == null) begin
        `uvm_error("CQ_RESIZE_SRQ_QP_SETUP",
                   "shared SRQ QP fixture creation failed")
      end
      else begin
        status = fixture.engine.attach_qp(srq_qp.handle);
        if (status == null || !status.ok())
          `uvm_error("CQ_RESIZE_SRQ_ATTACH",
                     "shared SRQ QP data attachment failed")
      end
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

    // 驱动在请求深度等于当前 ibcq->cqe 时直接成功返回，不分配候选
    // backing，也不改变 mapping identity；模型必须保持相同的 no-op 语义。
    same_size_mapping_iova = before_mapping.iova.value;
    same_size_allocate_calls = 0;
    foreach (fixture.mem.calls[i])
      if (fixture.mem.calls[i] != null &&
          fixture.mem.calls[i].method_name == "allocate")
        same_size_allocate_calls++;
    status = facade.resize(fixture.cq.handle, 16, 64);
    if (status == null || !status.ok())
      `uvm_error("CQ_RESIZE_SAME_SIZE", "same-size resize was not a no-op")
    status = fixture.manager.lookup(fixture.cq.handle, after_resource);
    if (status == null || !status.ok() || !$cast(after_cq, after_resource) ||
        after_cq.depth != 16 || after_cq.cqe_size_bytes != 64)
      `uvm_error("CQ_RESIZE_SAME_SIZE", "same-size resize changed geometry")
    after_mapping = null;
    if (after_cq != null && after_cq.queue_plan != null)
      foreach (after_cq.queue_plan.refs[i])
        if (after_cq.queue_plan.refs[i] != null &&
            after_cq.queue_plan.refs[i].role == RDMA_QUEUE_ROLE_CQ_RING)
          after_mapping = after_cq.queue_plan.refs[i].mapping;
    if (after_mapping == null ||
        after_mapping.iova.value != same_size_mapping_iova)
      `uvm_error("CQ_RESIZE_SAME_SIZE", "same-size resize replaced backing")
    allocate_calls_after = 0;
    foreach (fixture.mem.calls[j])
      if (fixture.mem.calls[j] != null &&
          fixture.mem.calls[j].method_name == "allocate")
        allocate_calls_after++;
    if (allocate_calls_after != same_size_allocate_calls)
      `uvm_error("CQ_RESIZE_SAME_SIZE", "same-size resize allocated backing")

    allocate_calls_before = 0;
    foreach (fixture.mem.calls[i]) begin
      if (fixture.mem.calls[i] != null && fixture.mem.calls[i].method_name == "allocate")
        allocate_calls_before++;
    end

    // An allocation failure must be observable and must leave both the
    // authority geometry and the old mapping untouched.
    fixture.mem.fail_next("allocate",
      rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED, "injected resize allocation failure"));
    status = facade.resize(fixture.cq.handle, 32, 64);
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
    status = facade.resize(fixture.cq.handle, 32, 64);
    if (status == null || !status.ok())
      `uvm_error("CQ_RESIZE_VALID", "valid resize was rejected")
    status = fixture.manager.lookup(fixture.cq.handle, after_resource);
    if (status == null || !status.ok() || !$cast(after_cq, after_resource) ||
        after_cq.depth != 32 || after_cq.cqe_size_bytes != 64 ||
        after_cq.queue_plan == null || after_cq.queue_plan.rings.size() != 1 ||
        after_cq.queue_plan.rings[0].depth != 32 ||
        after_cq.queue_plan.rings[0].entry_size_bytes != 64 ||
        after_cq.queue_plan.refs.size() == 0)
      `uvm_error("CQ_RESIZE_AUTHORITY", "successful resize geometry was not published")
    after_mapping = null;
    foreach (after_cq.queue_plan.refs[i])
      if (after_cq.queue_plan.refs[i] != null &&
          after_cq.queue_plan.refs[i].role == RDMA_QUEUE_ROLE_CQ_RING)
        after_mapping = after_cq.queue_plan.refs[i].mapping;
    if (after_mapping == null ||
        after_mapping.size < 32 * 64 ||
        after_mapping.iova.value == before_mapping.iova.value)
      `uvm_error("CQ_RESIZE_MAPPING", "successful resize did not replace mapping identity/size")

    // 驱动明确拒绝 shrink，且 CQC_RESIZE 没有 CQE width 字段；两种请求
    // 都必须在发布前拒绝，并保留当前 32x64 authority。
    status = facade.resize(fixture.cq.handle, 16, 64);
    if (status == null || status.ok())
      `uvm_error("CQ_RESIZE_SHRINK", "driver-unsupported CQ shrink was accepted")
    status = facade.resize(fixture.cq.handle, 64, 128);
    if (status == null || status.ok())
      `uvm_error("CQ_RESIZE_WIDTH", "driver-unsupported CQE width change was accepted")
    status = fixture.manager.lookup(fixture.cq.handle, after_resource);
    if (status == null || !status.ok() || !$cast(after_cq, after_resource) ||
        after_cq.depth != 32 || after_cq.cqe_size_bytes != 64)
      `uvm_error("CQ_RESIZE_GEOMETRY_ROLLBACK",
                 "rejected shrink/width resize changed authority")

    status = fixture.engine.query_runtime_state(
      fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, sq_state);
    if (status == null || !status.ok() || sq_state != RDMA_QUEUE_RUNTIME_ACTIVE)
      `uvm_error("CQ_RESIZE_DEPENDENT_SQ", "SQ dependent runtime was not restored ACTIVE")
    status = fixture.engine.query_runtime_state(
      fixture.qp.handle, RDMA_QUEUE_RUNTIME_RQ, rq_state);
    if (status == null || !status.ok() || rq_state != RDMA_QUEUE_RUNTIME_ACTIVE)
      `uvm_error("CQ_RESIZE_DEPENDENT_RQ", "RQ dependent runtime was not restored ACTIVE")
    if (srq != null && srq_qp != null) begin
      status = fixture.engine.query_runtime_state(
        srq.handle, RDMA_QUEUE_RUNTIME_SRQ, srq_state);
      if (status == null || !status.ok() ||
          srq_state != RDMA_QUEUE_RUNTIME_ACTIVE)
        `uvm_error("CQ_RESIZE_DEPENDENT_SRQ",
                   "SRQ dependent runtime was not restored ACTIVE")
    end

    // 发布后旧 backing 的释放可能失败；engine 必须保留可重试的 recovery
    // authority，不能只返回错误而丢失旧 mapping 的释放入口。
    live_before_cleanup_failure = fixture.mem.live_allocations();
    fixture.mem.fail_next("release",
      rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                        "injected published resize cleanup failure"));
    status = facade.resize(fixture.cq.handle, 64, 64);
    if (status == null || status.code != RDMA_SC_RECOVERY_REQUIRED)
      `uvm_error("CQ_RESIZE_RECOVERY_STATUS",
                 "published cleanup failure did not require recovery")
    if (!fixture.engine.has_pending_cq_resize(fixture.cq.handle))
      `uvm_error("CQ_RESIZE_RECOVERY_RECORD",
                 "published cleanup failure lost recovery authority")
    live_after_cleanup_failure = fixture.mem.live_allocations();
    if (live_after_cleanup_failure != live_before_cleanup_failure + 1)
      `uvm_error("CQ_RESIZE_RECOVERY_LEAK",
                 "candidate backing was not retained while old cleanup was pending")
    // pending recovery 必须阻止并发 detach/reconfigure，避免调用方绕过
    // engine-owned record 丢失旧 backing 的唯一释放入口。
    status = fixture.engine.detach(fixture.cq.handle);
    if (status == null || status.code != RDMA_SC_RECOVERY_REQUIRED)
      `uvm_error("CQ_RESIZE_RECOVERY_DETACH",
                 "CQ detach bypassed pending cleanup recovery")
    status = fixture.engine.configure(fixture.manager, fixture.binding,
                                      fixture.mem, fixture.scheduler,
                                      fixture.registry, 2us);
    if (status == null || status.code != RDMA_SC_RECOVERY_REQUIRED)
      `uvm_error("CQ_RESIZE_RECOVERY_CONFIG",
                 "engine reconfigure bypassed pending cleanup recovery")
    // 模拟 CQ resize 发布后发生 Function reset：新的调用上下文携带当前
    // generation，但 recovery 仍必须能通过稳定的 Function/object identity
    // 找到旧 generation 的 release authority 并完成清理。
    original_generation = fixture.binding.generation;
    recovery_retry_h = rdma_clone_handle_value(
      fixture.cq.handle, "CQ resize generation-reset retry");
    recovery_retry_h.generation = original_generation + 1;
    fixture.binding.generation = original_generation + 1;
    status = fixture.engine.retry_cq_resize_cleanup(recovery_retry_h);
    fixture.binding.generation = original_generation;
    if (status == null || !status.ok())
      `uvm_error("CQ_RESIZE_RECOVERY_GENERATION_RETRY",
                 "generation-reset cleanup authority could not be retried")
    if (fixture.engine.has_pending_cq_resize(fixture.cq.handle))
      `uvm_error("CQ_RESIZE_RECOVERY_CLEAR",
                 "completed CQ cleanup recovery record was not cleared")
    live_after_cleanup_retry = fixture.mem.live_allocations();
    if (live_after_cleanup_retry != live_before_cleanup_failure)
      `uvm_error("CQ_RESIZE_RECOVERY_RELEASE",
                 "CQ cleanup retry did not release the old backing")

    // recovery resize 已经发布了新的 64x64 authority；非法 geometry 的
    // 回滚断言必须以该最新 mapping 为基准，不能继续比较上一次 32x64 快照。
    status = fixture.manager.lookup(fixture.cq.handle, after_resource);
    after_mapping = null;
    if (status == null || !status.ok() || !$cast(after_cq, after_resource) ||
        after_cq.queue_plan == null)
      `uvm_error("CQ_RESIZE_RECOVERY_AUTH", "recovery resize authority snapshot failed")
    else
      foreach (after_cq.queue_plan.refs[i])
        if (after_cq.queue_plan.refs[i] != null &&
            after_cq.queue_plan.refs[i].role == RDMA_QUEUE_ROLE_CQ_RING)
          after_mapping = after_cq.queue_plan.refs[i].mapping;
    if (after_mapping == null)
      `uvm_error("CQ_RESIZE_RECOVERY_AUTH", "recovery resize ring mapping snapshot is missing")

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
        before_cq.depth != 64 || before_cq.cqe_size_bytes != 64 ||
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

    // 驱动对 URC CQ 明确返回 -EOPNOTSUPP；在释放本测试建立的 QP/CQ
    // attachment 后复用同一 authoritative CQ，以 URC transport 重新挂接，
    // 验证 resize 入口不会把不支持的命令提交到硬件。
    if (srq_qp != null) begin
      status = fixture.engine.detach(srq_qp.handle);
      if (status == null || !status.ok())
        `uvm_error("CQ_RESIZE_URC_SETUP", "shared SRQ QP detach failed")
    end
    status = fixture.engine.detach(fixture.qp.handle);
    if (status == null || !status.ok())
      `uvm_error("CQ_RESIZE_URC_SETUP", "fixture QP detach failed")
    status = fixture.engine.detach(fixture.cq.handle);
    if (status == null || !status.ok())
      `uvm_error("CQ_RESIZE_URC_SETUP", "fixture CQ detach failed")
    status = fixture.engine.attach_cq(fixture.cq.handle, RDMA_TRANSPORT_URC);
    if (status == null || !status.ok())
      `uvm_error("CQ_RESIZE_URC_SETUP", "URC CQ reattach failed")
    status = facade.resize(fixture.cq.handle, 128, 64);
    if (status == null || status.code != RDMA_SC_UNSUPPORTED_OPCODE)
      `uvm_error("CQ_RESIZE_URC", "URC CQ resize was not rejected")

    // reset epoch 漂移门禁：更新 binding identity 后，resize 仍必须在
    // delegate 入口前返回 STALE_GENERATION，并且不分配新 ring。
    begin : reset_epoch_drift_resize_gate
      rdma_function_identity drift_identity;
      rdma_status drift_status;
      rdma_resource drift_before_resource;
      rdma_resource drift_after_resource;
      rdma_cq drift_before_cq;
      rdma_cq drift_after_cq;
      rdma_dma_mapping drift_before_mapping;
      rdma_dma_mapping drift_after_mapping;
      rdma_reset_epoch_t saved_epoch;
      int unsigned allocate_count_before;
      int unsigned allocate_count_after;

      allocate_count_before = 0;
      foreach (fixture.mem.calls[i])
        if (fixture.mem.calls[i] != null &&
            fixture.mem.calls[i].method_name == "allocate")
          allocate_count_before++;

      drift_status = fixture.manager.lookup(fixture.cq.handle,
                                             drift_before_resource);
      if (drift_status == null || !drift_status.ok() ||
          !$cast(drift_before_cq, drift_before_resource))
        `uvm_error("CQ_RESIZE_AUTHORITY_DRIFT",
                   "reset-epoch precondition lookup failed")
      drift_before_mapping = null;
      if (drift_before_cq != null && drift_before_cq.queue_plan != null)
        foreach (drift_before_cq.queue_plan.refs[i])
          if (drift_before_cq.queue_plan.refs[i] != null &&
              drift_before_cq.queue_plan.refs[i].role == RDMA_QUEUE_ROLE_CQ_RING)
            drift_before_mapping = drift_before_cq.queue_plan.refs[i].mapping;

      drift_identity = fixture.binding.function_identity_snapshot();
      if (drift_identity == null) begin
        `uvm_error("CQ_RESIZE_AUTHORITY_DRIFT",
                   "reset-epoch identity snapshot failed")
      end
      else begin
        saved_epoch = drift_identity.reset_epoch;
        drift_identity.reset_epoch = saved_epoch + 1;
        drift_status = fixture.binding.configure_identity(drift_identity);
        if (drift_status == null || !drift_status.ok())
          `uvm_error("CQ_RESIZE_AUTHORITY_DRIFT",
                     "reset-epoch drift setup failed")
        drift_status = facade.resize(fixture.cq.handle, 128, 64);
        if (drift_status == null ||
            drift_status.code != RDMA_SC_STALE_GENERATION)
          `uvm_error("CQ_RESIZE_AUTHORITY_DRIFT",
                     "reset-epoch drift was not rejected as STALE_GENERATION")
        drift_identity.reset_epoch = saved_epoch;
        drift_status = fixture.binding.configure_identity(drift_identity);
        if (drift_status == null || !drift_status.ok())
          `uvm_error("CQ_RESIZE_AUTHORITY_DRIFT",
                     "reset-epoch authority restore failed")

        drift_status = fixture.manager.lookup(fixture.cq.handle,
                                               drift_after_resource);
        if (drift_status == null || !drift_status.ok() ||
            !$cast(drift_after_cq, drift_after_resource) ||
            drift_after_cq.depth != drift_before_cq.depth ||
            drift_after_cq.cqe_size_bytes != drift_before_cq.cqe_size_bytes)
          `uvm_error("CQ_RESIZE_AUTHORITY_DRIFT",
                     "reset-epoch drift changed CQ geometry")
        drift_after_mapping = null;
        if (drift_after_cq != null && drift_after_cq.queue_plan != null)
          foreach (drift_after_cq.queue_plan.refs[i])
            if (drift_after_cq.queue_plan.refs[i] != null &&
                drift_after_cq.queue_plan.refs[i].role == RDMA_QUEUE_ROLE_CQ_RING)
              drift_after_mapping = drift_after_cq.queue_plan.refs[i].mapping;
        if (drift_before_mapping == null || drift_after_mapping == null ||
            drift_after_mapping.iova.value != drift_before_mapping.iova.value)
          `uvm_error("CQ_RESIZE_AUTHORITY_DRIFT",
                     "reset-epoch drift replaced CQ ring backing")

        allocate_count_after = 0;
        foreach (fixture.mem.calls[i])
          if (fixture.mem.calls[i] != null &&
              fixture.mem.calls[i].method_name == "allocate")
            allocate_count_after++;
        if (allocate_count_after != allocate_count_before)
          `uvm_error("CQ_RESIZE_AUTHORITY_DRIFT",
                     "reset-epoch drift invoked backing allocation")
      end
    end

    layout = rdma_cqe_layout::for_bytes(128, 16);
    layout.bytes = 48;
    if (layout.valid())
      `uvm_error("CQ_LAYOUT_MUTATION", "tampered layout was accepted")
    phase.drop_objection(this);
  endtask
endclass
