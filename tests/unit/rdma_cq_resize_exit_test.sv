// 目录/层次：tests/unit；职责：验证 CQ resize 统一回滚出口与发布后恢复之间的边界。
// 依赖：完整 queue-data lifecycle fixture、真实 manager/runtime 与 mock Host-memory。
// 所有权与生命周期：每个 case 拥有独立 fixture 和隔离 factory；完成 recovery 后聚合
//   cleanup 并检查零 live allocation；resize 返回立即恢复原 factory，probe 只借用锁。

// 设计说明：只在指定候选的创建点返回 null；可在首次命中时嵌套另一 engine 的 resize，
// 用真实 factory 回调验证两个自动调用的失败出口互不干扰。
class rdma_cq_resize_null_wrapper extends uvm_object_wrapper;
  int unsigned hits;
  rdma_queue_data_engine nested_engine;
  rdma_handle nested_cq;
  rdma_status nested_status;

  // 功能：构造单个候选创建故障的计数器，默认尚未命中。
  // 输入/输出及副作用：无输入；hits=0，嵌套引用/status 为空，不安装 override 或取得资源。
  // 失败/边界：必须由 case 按精确 instance 名注册，不可全局覆盖所有同类对象。
  function new();
    hits = 0;
    nested_engine = null;
    nested_cq = null;
    nested_status = null;
  endfunction

  // 功能：模拟指定 CQ resize 候选创建失败，并记录该失败点实际被执行。
  // 输入/输出及副作用：name 为 factory 请求名；递增 hits 并返回 null；首次命中且
  //   nested_engine 非空时先嵌套其 32×64 resize，保存返回 status，不取得引用所有权。
  // 失败/边界：每次命中均失败；hits 门禁防止无限递归；caller 必须提供有效 nested_cq，
  //   并在外层 resize 返回后恢复原 factory。
  virtual function uvm_object create_object(string name = "");
    hits++;
    if (hits == 1 && nested_engine != null)
      nested_status = nested_engine.resize_cq(nested_cq, 32, 64);
    return null;
  endfunction

  // 功能：提供隔离 factory 中 null wrapper 的稳定类型名。
  // 输入/输出及副作用：无输入；返回常量名称，不改变命中次数。
  // 失败/边界：名称仅供 UVM 注册，不能作为 CQ 资源或恢复 identity。
  virtual function string get_type_name();
    return "rdma_cq_resize_null_wrapper";
  endfunction
endclass

// 设计说明：不代理 resize；只观察生产函数返回后是否恰好剩一个 semaphore token。
class rdma_cq_resize_exit_probe extends rdma_queue_data_engine;
  `uvm_object_utils(rdma_cq_resize_exit_probe)

  // 功能：建立未配置的 engine，保留基类的唯一 resize 锁及空 attachment 索引。
  // 输入/输出及副作用：name 透传基类；不附着或申请任何 CQ backing。
  // 失败/边界：业务前必须由 fixture.setup 完成配置，probe 不绕过 admission。
  function new(string name = "rdma_cq_resize_exit_probe");
    super.new(name);
  endfunction

  // 功能：验证 resize 返回后锁未泄漏也未重复归还。
  // 输入/输出及副作用：无输入；临时取最多两个 token 后原数归还，正确时返回 1。
  // 失败/边界：空锁、取不到第一个或能取得第二个均返回 0；不修正错误 token 数。
  function bit has_one_resize_token();
    bit first;
    bit second;

    if (resize_lock == null)
      return 1'b0;
    first = resize_lock.try_get(1);
    second = resize_lock.try_get(1);
    if (first) resize_lock.put(1);
    if (second) resize_lock.put(1);
    return first && !second;
  endfunction
endclass

// 设计说明：复用已有 dependent restore 注入，补齐发布后旧 CQ detach 的独立窗口。
class rdma_cq_resize_exit_runtime extends rdma_resize_fault_runtime;
  `uvm_object_utils(rdma_cq_resize_exit_runtime)
  static bit fail_detach;

  // 功能：构造默认 detached runtime，保留真实账本与基类 begin/restore 故障开关。
  // 输入/输出及副作用：name 传给基类；不分配 mapping，不改变静态注入开关。
  // 失败/边界：case 必须在 setup 前清零静态开关，避免跨 fixture 注入。
  function new(string name = "rdma_cq_resize_exit_runtime");
    super.new(name);
  endfunction

  // 功能：在已发布 resize 清理旧 CQ 时注入一次 detach 失败。
  // 输入/输出及副作用：无输入；命中时清除 fail_detach 并保留 QUIESCING 状态。
  // 失败/边界：仅 CQ 且 fail_detach=1 返回 RESOURCE_BUSY；其余沿基类真实 detach。
  virtual function rdma_status detach_quiesced();
    if (kind == RDMA_QUEUE_RUNTIME_CQ && fail_detach) begin
      fail_detach = 1'b0;
      return rdma_status::make(RDMA_SC_RESOURCE_BUSY, "injected old CQ detach");
    end
    return super.detach_quiesced();
  endfunction
endclass

// 设计说明：六个创建点 × 正常/失败 rollback，加上发布后 restore/detach/release，
// 再增加不同 engine 嵌套失败；同时观察 authority、runtime、锁和 allocation，不只检查返回码。
class rdma_cq_resize_exit_test extends uvm_test;
  `uvm_component_utils(rdma_cq_resize_exit_test)

  // 功能：构造独立 resize 故障矩阵测试，不提前创建 fixture。
  // 输入/输出及副作用：name/parent 为 UVM 层级参数；仅建立组件。
  // 失败/边界：资源与 factory 的作用域全部限制在 run_case，构造不准入业务。
  function new(string name = "rdma_cq_resize_exit_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：读取 manager-authoritative CQ 的 geometry 与 mapping，断言发布阶段正确。
  // 输入/输出及副作用：fixture、depth 和 old_iova 为输入，replaced 指定是否应换 ring；
  //   返回当前 ring IOVA，只读取 detached snapshot，不改变 manager 或 attachment。
  // 失败/边界：lookup/类型/plan/ref 缺失触发 fatal；geometry/state/mapping 不符报 error。
  function longint unsigned check_authority(
    rdma_queue_data_engine_fixture fixture, int unsigned depth,
    longint unsigned old_iova, bit replaced
  );
    rdma_resource resource;
    rdma_cq cq;
    rdma_dma_mapping mapping;
    rdma_status status;

    status = fixture.manager.lookup(fixture.cq.handle, resource);
    if (status == null || !status.ok() || !$cast(cq, resource) ||
        cq == null || cq.queue_plan == null)
      `uvm_fatal("RESIZE_EXIT", "CQ authority snapshot unavailable")
    foreach (cq.queue_plan.refs[i])
      if (cq.queue_plan.refs[i] != null &&
          cq.queue_plan.refs[i].role == RDMA_QUEUE_ROLE_CQ_RING)
        mapping = cq.queue_plan.refs[i].mapping;
    if (mapping == null)
      `uvm_fatal("RESIZE_EXIT", "CQ ring mapping unavailable")
    if (cq.state != RDMA_RESOURCE_ACTIVE || cq.depth != depth ||
        cq.cqe_size_bytes != 64 || mapping.size < depth * 64 ||
        mapping.state != RDMA_MAPPING_ACTIVE ||
        (old_iova != 0 && ((mapping.iova.value != old_iova) != replaced)))
      `uvm_error("RESIZE_EXIT", "CQ authority changed at the wrong transaction stage")
    return mapping.iova.value;
  endfunction

  // 功能：确认 CQ 与两个关联工作队列都已解除 resize 屏障。
  // 输入/输出及副作用：fixture 为借用输入；查询 CQ/SQ/RQ runtime state，不修改账本。
  // 失败/边界：任一查询失败或非 ACTIVE 报 error；只在 rollback/retry 完成后调用。
  function void check_active(rdma_queue_data_engine_fixture fixture);
    rdma_queue_runtime_kind_e kinds[3] = '{
      RDMA_QUEUE_RUNTIME_CQ, RDMA_QUEUE_RUNTIME_SQ, RDMA_QUEUE_RUNTIME_RQ};
    rdma_queue_runtime_state_e state;
    rdma_status status;

    foreach (kinds[i]) begin
      status = fixture.engine.query_runtime_state(
        i == 0 ? fixture.cq.handle : fixture.qp.handle, kinds[i], state);
      if (status == null || !status.ok() || state != RDMA_QUEUE_RUNTIME_ACTIVE)
        `uvm_error("RESIZE_EXIT", "runtime was not restored ACTIVE")
    end
  endfunction

  // 功能：执行一个真实 resize 故障、恢复和再次扩容，验证统一出口的资源与锁契约。
  // 输入/输出及副作用：mode=0..11 选择六个 null 创建点及 rollback release 故障，
  //   12..14 选择发布后的 restore/detach/release；每次独立 setup、cleanup、恢复 factory。
  // 失败/边界：setup/type 缺失 fatal；其余断言 error 后仍尝试 recovery/cleanup；
  //   恢复必须无 pending、零额外 backing，并能再次扩容，最终零 live allocation。
  task run_case(int unsigned mode);
    uvm_coreservice_t core_service;
    uvm_factory saved_factory;
    uvm_default_factory local_factory;
    rdma_cq_resize_null_wrapper null_wrapper;
    rdma_queue_data_engine_fixture fixture;
    rdma_cq_resize_exit_probe probe;
    rdma_status status;
    uvm_object_wrapper candidate_type;
    string candidate_name;
    string expected_message;
    longint unsigned old_iova;
    longint unsigned published_iova;
    int unsigned live_before;
    bit prepublish;
    bit recovery_expected;

    core_service = uvm_coreservice_t::get();
    saved_factory = core_service.get_factory();
    local_factory = new();
    local_factory.set_type_override_by_type(
      rdma_queue_data_engine::get_type(), rdma_cq_resize_exit_probe::get_type());
    local_factory.set_type_override_by_type(
      rdma_queue_runtime::get_type(), rdma_cq_resize_exit_runtime::get_type());
    core_service.set_factory(local_factory);
    rdma_resize_fault_runtime::fail_begin_once = 1'b0;
    rdma_resize_fault_runtime::restore_failures = 0;
    rdma_cq_resize_exit_runtime::fail_detach = 1'b0;
    fixture = new($sformatf("resize_exit_%0d", mode));
    fixture.setup(status);
    if (status == null || !status.ok() || !$cast(probe, fixture.engine))
      `uvm_fatal("RESIZE_EXIT", "fixture setup/probe failed")
    old_iova = check_authority(fixture, 16, 0, 1'b0);
    live_before = fixture.mem.live_allocations();
    prepublish = mode < 12;
    recovery_expected = !prepublish || (mode % 2 != 0);

    // 仅候选的精确名称触发 null；rollback recovery 使用不同名称，仍正常分配。
    if (prepublish) begin
      case (mode / 2)
        0: begin
          candidate_type = rdma_queue_runtime::get_type();
          candidate_name = "cq_resize_runtime";
          expected_message = "CQ resize runtime allocation failed";
        end
        1: begin
          candidate_type = rdma_queue_backing_access::get_type();
          candidate_name = "cq_resize_backing_access";
          expected_message = "CQ resize backing access allocation failed";
        end
        2: begin
          candidate_type = rdma_queue_backing_plan::get_type();
          candidate_name = "cq_resize_plan";
          expected_message = "CQ resize queue plan allocation failed";
        end
        3: begin
          candidate_type = rdma_cq::get_type();
          candidate_name = "cq_resize_candidate";
          expected_message = "CQ resize candidate allocation failed";
        end
        4: begin
          candidate_type = rdma_cq_resize_recovery::get_type();
          candidate_name = "cq_resize_recovery";
          expected_message = "CQ resize recovery record allocation failed";
        end
        5: begin
          candidate_type = rdma_queue_data_attachment::get_type();
          candidate_name = "cq_resize_attachment";
          expected_message = "CQ resize attachment allocation failed";
        end
        default: `uvm_fatal("RESIZE_EXIT", "candidate fault index out of range")
      endcase
      null_wrapper = new();
      local_factory.set_inst_override_by_type(candidate_type, null_wrapper, candidate_name);
    end
    if ((prepublish && recovery_expected) || mode == 14)
      void'(fixture.mem.fail_next("release",
        rdma_status::make(RDMA_SC_DMA_TRANSLATION, "injected resize exit release")));
    if (mode == 12) begin
      rdma_resize_fault_runtime::fail_restore_kind = RDMA_QUEUE_RUNTIME_SQ;
      rdma_resize_fault_runtime::restore_failures = 1;
    end
    if (mode == 13)
      rdma_cq_resize_exit_runtime::fail_detach = 1'b1;

    status = fixture.engine.resize_cq(fixture.cq.handle, 32, 64);
    core_service.set_factory(saved_factory);
    if (status == null || status.code != (recovery_expected ?
        RDMA_SC_RECOVERY_REQUIRED : RDMA_SC_RESOURCE_EXHAUSTED))
      `uvm_error("RESIZE_EXIT", "unexpected resize failure code")
    if (prepublish && (null_wrapper.hits != 1 ||
        (!recovery_expected && (status == null || status.message != expected_message))))
      `uvm_error("RESIZE_EXIT", "candidate failure was skipped or diagnostic changed")
    if (rdma_resize_fault_runtime::restore_failures != 0 ||
        rdma_cq_resize_exit_runtime::fail_detach)
      `uvm_error("RESIZE_EXIT", "published failure point was not reached")
    if (!probe.has_one_resize_token())
      `uvm_error("RESIZE_EXIT", "resize failure leaked or duplicated its lock token")
    published_iova = check_authority(fixture, prepublish ? 16 : 32,
                                     old_iova, !prepublish);
    if (fixture.engine.has_pending_cq_resize(fixture.cq.handle) != recovery_expected ||
        fixture.mem.live_allocations() != live_before + int'(recovery_expected))
      `uvm_error("RESIZE_EXIT", "recovery record or retained allocation disagrees with stage")

    if (recovery_expected) begin
      status = fixture.engine.resize_cq(fixture.cq.handle, 64, 64);
      if (status == null || status.code != RDMA_SC_RECOVERY_REQUIRED ||
          !probe.has_one_resize_token())
        `uvm_error("RESIZE_EXIT", "pending cleanup gate or lock release changed")
      status = fixture.engine.retry_cq_resize_cleanup(fixture.cq.handle);
      if (status == null || !status.ok())
        `uvm_error("RESIZE_EXIT", "recorded cleanup retry failed")
    end
    void'(check_authority(fixture, prepublish ? 16 : 32, published_iova, 1'b0));
    check_active(fixture);
    if (fixture.engine.has_pending_cq_resize(fixture.cq.handle) ||
        fixture.mem.live_allocations() != live_before || !probe.has_one_resize_token())
      `uvm_error("RESIZE_EXIT", "retry left recovery, excess backing or an invalid lock")

    status = fixture.engine.resize_cq(fixture.cq.handle, 64, 64);
    if (status == null || !status.ok() || !probe.has_one_resize_token())
      `uvm_error("RESIZE_EXIT", "next resize could not complete")
    void'(check_authority(fixture, 64, published_iova, 1'b1));
    check_active(fixture);
    fixture.cleanup(status);
    if (status == null || !status.ok() || fixture.needs_cleanup() ||
        fixture.mem.live_allocations() != 0)
      `uvm_error("RESIZE_EXIT", "fixture cleanup left owned resources")
    `uvm_info("RESIZE_EXIT", $sformatf("completed resize exit case %0d", mode), UVM_LOW)
  endtask

  // 功能：在外层候选 factory 中嵌套另一 engine 的 resize，并让内外候选都创建失败。
  // 输入/输出及副作用：无参数；拥有两个独立 lifecycle fixture，精确 instance override
  //   触发两次 null，检查各自 rollback、锁及 backing，再分别扩容和 cleanup。
  // 失败/边界：嵌套返回必须为 RESOURCE_EXHAUSTED，不能被外层控制流退出中断；
  //   任一 authority/资源/锁断言失败报 error，factory 在 outer 返回后即恢复。
  task run_nested_case();
    uvm_coreservice_t core_service;
    uvm_factory saved_factory;
    uvm_default_factory local_factory;
    rdma_cq_resize_null_wrapper null_wrapper;
    rdma_queue_data_engine_fixture fixtures[2];
    rdma_cq_resize_exit_probe probes[2];
    rdma_status status;
    longint unsigned old_iova[2];
    int unsigned live_before[2];

    core_service = uvm_coreservice_t::get();
    saved_factory = core_service.get_factory();
    local_factory = new();
    local_factory.set_type_override_by_type(
      rdma_queue_data_engine::get_type(), rdma_cq_resize_exit_probe::get_type());
    core_service.set_factory(local_factory);
    foreach (fixtures[i]) begin
      fixtures[i] = new($sformatf("resize_nested_%0d", i));
      fixtures[i].setup(status);
      if (status == null || !status.ok() || !$cast(probes[i], fixtures[i].engine))
        `uvm_fatal("RESIZE_EXIT", "nested fixture setup/probe failed")
      old_iova[i] = check_authority(fixtures[i], 16, 0, 1'b0);
      live_before[i] = fixtures[i].mem.live_allocations();
    end
    null_wrapper = new();
    null_wrapper.nested_engine = fixtures[1].engine;
    null_wrapper.nested_cq = fixtures[1].cq.handle;
    local_factory.set_inst_override_by_type(
      rdma_queue_runtime::get_type(), null_wrapper, "cq_resize_runtime");
    status = fixtures[0].engine.resize_cq(fixtures[0].cq.handle, 32, 64);
    core_service.set_factory(saved_factory);
    if (null_wrapper.hits != 2 || null_wrapper.nested_status == null ||
        null_wrapper.nested_status.code != RDMA_SC_RESOURCE_EXHAUSTED ||
        status == null || status.code != RDMA_SC_RESOURCE_EXHAUSTED)
      `uvm_error("RESIZE_EXIT", "nested resize failure escaped its own activation")
    foreach (fixtures[i]) begin
      void'(check_authority(fixtures[i], 16, old_iova[i], 1'b0));
      check_active(fixtures[i]);
      if (!probes[i].has_one_resize_token() ||
          fixtures[i].engine.has_pending_cq_resize(fixtures[i].cq.handle) ||
          fixtures[i].mem.live_allocations() != live_before[i])
        `uvm_error("RESIZE_EXIT", "nested rollback left a lock or resource leak")
      status = fixtures[i].engine.resize_cq(fixtures[i].cq.handle, 64, 64);
      if (status == null || !status.ok() || !probes[i].has_one_resize_token())
        `uvm_error("RESIZE_EXIT", "nested fixture next resize failed")
      void'(check_authority(fixtures[i], 64, old_iova[i], 1'b1));
      check_active(fixtures[i]);
      fixtures[i].cleanup(status);
      if (status == null || !status.ok() || fixtures[i].needs_cleanup() ||
          fixtures[i].mem.live_allocations() != 0)
        `uvm_error("RESIZE_EXIT", "nested fixture cleanup leaked resources")
    end
    `uvm_info("RESIZE_EXIT", "completed resize exit case 15", UVM_LOW)
  endtask

  // 功能：运行完整的 16-case 发布前/后与嵌套退出矩阵，确保每种故障均进入核心回归。
  // 输入/输出及副作用：phase 控制 objection；各 case 独立资源和 factory，不共享 ring。
  // 失败/边界：case 报告错误由 UVM 汇总，全部完成后才打印计数并释放 objection。
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    for (int unsigned mode = 0; mode < 15; mode++)
      run_case(mode);
    run_nested_case();
    `uvm_info("RESIZE_EXIT", "completed 16 resize exit cases", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass
