// 目录/层次：tests/integration/ 集成测试层，验证单 Function context 的生命周期和 authority 隔离。
// 职责：覆盖 context 构造、activate/quiesce/reset 状态迁移，以及 queue handle
//       查询在错误边界上的 fail-closed 行为；不连接真实 PCIe/Host-memory。
// 依赖：rdma_dpu_env_pkg、rdma_function_identity、dpu_resource_snapshot 和 UVM。
// 所有权与生命周期：测试拥有 identity、snapshot、router 和 context；context 只保存
//       外部 snapshot/router 的非拥有引用，测试结束后统一释放 UVM 对象。

class rdma_context_test_resource_snapshot extends dpu_resource_snapshot;
  `uvm_object_utils(rdma_context_test_resource_snapshot)

  // 功能：构造可被 context build 接受的测试资源快照对象。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：构造过程不分配 Host-memory、PCIe endpoint 或 manager 资源；空 name 也必须得到可配置对象。
  function new(string name = "rdma_context_test_resource_snapshot");
    super.new(name);
  endfunction

  // 功能：将测试快照标记为冻结；该夹具不伪造任何 queue/resource binding。
  // 输入/输出及副作用：无显式参数；force_frozen 读取 对象字段：m_frozen 并使用字段 m_frozen；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：force_frozen 无返回值，仅执行 m_frozen=1'b1；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  function void force_frozen();
    m_frozen = 1'b1;
  endfunction
endclass

// 设计说明：该 wrapper 只在本测试的故障窗口内替代一个 UVM object registry，
// 用于验证 context build/reset 对 factory 返回 null 的 fail-closed 和失败原子性。
// 生产代码仍通过标准 type_id::create() 运行，wrapper 在窗口外委托原 registry。
class rdma_context_factory_fault_wrapper extends uvm_object_wrapper;
  protected string wrapper_type_name;
  protected uvm_object_wrapper delegate;
  protected bit armed_state;

  // 功能：保存目标类型的原 registry，并以关闭故障状态初始化 wrapper。
  // 输入/输出及副作用：name/delegate_value 为输入；保存 delegate 非拥有引用，不创建 RDMA 对象。
  // 失败/边界：delegate_value 为空时关闭窗口的 create 也返回 null，调用方必须检查 fixture。
  function new(string name, uvm_object_wrapper delegate_value);
    wrapper_type_name = name;
    delegate = delegate_value;
    armed_state = 1'b0;
  endfunction

  // 功能：在故障窗口返回 null，否则转发目标 registry 的 object 创建请求。
  // 输入/输出及副作用：name 为 UVM object 名；返回新对象或 null，不修改外部账本。
  // 失败/边界：armed 时始终返回 null；关闭窗口但 delegate 缺失时同样 fail-closed。
  virtual function uvm_object create_object(string name = "");
    if (armed_state || delegate == null)
      return null;
    return delegate.create_object(name);
  endfunction

  // 功能：返回 wrapper 在 UVM factory 中显示的稳定类型名。
  // 输入/输出及副作用：无输入；只读返回 wrapper_type_name，不创建或修改对象。
  // 失败/边界：名称仅供 factory 诊断，不可作为动态类型 authority。
  virtual function string get_type_name();
    return wrapper_type_name;
  endfunction

  // 功能：开启当前目标类型的 null factory 故障窗口。
  // 输入/输出及副作用：无输入输出；设置 armed_state，后续 create_object 均返回 null。
  // 失败/边界：重复调用只覆盖同一窗口状态，不更换 delegate 或 factory 注册。
  function void arm();
    armed_state = 1'b1;
  endfunction

  // 功能：关闭 null factory 故障窗口并恢复原 registry 委托。
  // 输入/输出及副作用：无输入输出；清除 armed_state，不影响已经创建的对象。
  // 失败/边界：重复关闭幂等；factory type override 本身保留供后续窗口复用。
  function void disarm();
    armed_state = 1'b0;
  endfunction
endclass

class rdma_function_context_test extends uvm_test;
  `uvm_component_utils(rdma_function_context_test)
  protected uvm_object_wrapper saved_binding_override;
  protected uvm_object_wrapper saved_context_override;
  protected uvm_object_wrapper saved_coordinator_override;
  protected uvm_object_wrapper saved_identity_override;
  protected uvm_object_wrapper saved_handle_override;

  // 功能：恢复本测试覆盖的 context/binding/coordinator/identity/handle factory 到进入测试前的 override。
  // 输入/输出及副作用：无输入；仅在原 override 不是请求类型自身时写回全局 factory，
  //   避免 UVM 对 base->base 的清理调用发出 TYPDUP/TPREGR warning。
  // 失败/边界：只应在所有故障窗口关闭后调用；若原 factory 无显式 override，则保留
  //   已 disarm 的 passthrough wrapper，行为等价且不会产生 warning。
  function automatic void reset_context_factory_state();
    uvm_factory factory;

    factory = uvm_factory::get();
    if (saved_binding_override != null &&
        saved_binding_override != rdma_function_binding::get_type())
      factory.set_type_override_by_type(
        rdma_function_binding::get_type(), saved_binding_override, 1'b1);
    if (saved_context_override != null &&
        saved_context_override != rdma_function_context::get_type())
      factory.set_type_override_by_type(
        rdma_function_context::get_type(), saved_context_override, 1'b1);
    if (saved_coordinator_override != null &&
        saved_coordinator_override != rdma_reset_coordinator::get_type())
      factory.set_type_override_by_type(
        rdma_reset_coordinator::get_type(), saved_coordinator_override, 1'b1);
    if (saved_identity_override != null &&
        saved_identity_override != rdma_function_identity::get_type())
      factory.set_type_override_by_type(
        rdma_function_identity::get_type(), saved_identity_override, 1'b1);
    if (saved_handle_override != null &&
        saved_handle_override != rdma_function_handle::get_type())
      factory.set_type_override_by_type(
        rdma_function_handle::get_type(), saved_handle_override, 1'b1);
  endfunction

  // 功能：构造 UVM Function context 生命周期测试组件。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：构造过程不分配 Host-memory、PCIe endpoint 或 manager 资源；空 name 也必须得到可配置对象。
  function new(string name = "rdma_function_context_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：创建一个具有完整 Host/root/PF BDF authority 的 identity 夹具。
  // 输入/输出及副作用：无显式参数；make_identity 读取局部计算结果，并使用字段 key.root_id、key.host_topology_key、key.function_kind、key.vf_index、key.parent_pf_bdf、key.bdf、identity、status；函数返回 rdma_function_identity，不取得调用方资源所有权。
  // 失败/边界：输入为空、类型不匹配或字段组合非法时返回空值/错误；不得发布不完整快照。
  function automatic rdma_function_identity make_identity();
    rdma_function_identity identity;
    rdma_function_key_t key;
    rdma_status status;

    key.root_id = 2;
    key.host_topology_key = 7;
    key.function_kind = RDMA_FUNCTION_PF;
    key.vf_index = 0;
    key.parent_pf_bdf = '0;
    key.bdf = '{segment:16'h2, bus:8'h20, device:5'h3,
                function_num:3'h0};
    identity = rdma_function_identity::type_id::create("context_identity");
    status = identity.configure(key, 17, 64'h7000_0000_0000_0001, 1, 0);
    if (!status.ok())
      `uvm_fatal("CTX", {"identity fixture failed: ", status.message})
    return identity;
  endfunction

  // 功能：验证 context 的 build→activate→quiesce→reset 迁移和 queue 查询边界。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：仿真超时、事务返回错误或断言不满足时报告 UVM_ERROR/UVM_FATAL；空 fixture 不得被当作成功。
  task run_phase(uvm_phase phase);
    rdma_function_identity identity;
    rdma_context_test_resource_snapshot resources;
    rdma_host_mem_router host_mem;
    rdma_pcie_router pcie;
    rdma_function_context ctx;
    rdma_handle absent_queue;
    uvm_object registry;
    rdma_reset_coordinator coordinator;
    rdma_reset_coordinator null_coordinator;
    rdma_function_binding source_binding;
    rdma_function_binding null_binding;
    rdma_status status;
    rdma_status failure_status;
    rdma_function_context failed_context;
    rdma_function_context reset_context;
    rdma_function_context mismatch_context;
    rdma_function_context candidate_context;
    rdma_function_reset_candidate reset_candidate;
    rdma_function_identity old_identity;
    rdma_function_identity candidate_old_identity;
    rdma_function_identity mismatched_identity;
    rdma_function_binding old_binding;
    rdma_function_binding candidate_old_binding;
    rdma_function_binding mismatched_binding;
    rdma_function_context_state_e candidate_old_state;
    rdma_context_factory_fault_wrapper binding_fault;
    rdma_context_factory_fault_wrapper context_fault;
    rdma_context_factory_fault_wrapper coordinator_fault;
    rdma_context_factory_fault_wrapper identity_fault;
    rdma_context_factory_fault_wrapper handle_fault;
    uvm_factory factory;

    phase.raise_objection(this);
    identity = make_identity();
    resources = rdma_context_test_resource_snapshot::type_id::create(
      "context_resources");
    resources.force_frozen();
    host_mem = rdma_host_mem_router::type_id::create("context_host_mem");
    pcie = rdma_pcie_router::type_id::create("context_pcie");
    source_binding = rdma_function_binding::type_id::create(
      "context_source_binding");
    if (source_binding == null)
      `uvm_fatal("CTX", "source binding fixture allocation failed")
    status = source_binding.configure_identity(identity);
    if (status == null || !status.ok())
      `uvm_fatal("CTX", "source binding fixture configuration failed")

    status = rdma_function_context::build(
      identity, resources, host_mem, pcie, registry, 1ns, ctx,
      coordinator, source_binding);
    if (!status.ok() || ctx == null)
      `uvm_error("CTX", "context build failed")
    else begin
      status = ctx.activate();
      if (!status.ok() || ctx.state != RDMA_CONTEXT_ACTIVE)
        `uvm_error("CTX", "context did not activate")

      status = ctx.quiesce();
      if (!status.ok() || ctx.state != RDMA_CONTEXT_QUIESCING)
        `uvm_error("CTX", "context did not quiesce")

      status = ctx.reset(2, 9);
      if (!status.ok() || ctx.state != RDMA_CONTEXT_ACTIVE ||
          ctx.identity.generation != 2 ||
          ctx.identity.reset_epoch != 9)
        `uvm_error("CTX", "context reset did not publish new incarnation")

      absent_queue = rdma_handle::type_id::create("absent_queue");
      status = ctx.lookup_queue(absent_queue);
      if (status == null || status.ok())
        `uvm_error("CTX", "missing queue lookup was not rejected")
    end
    if (ctx != null)
      coordinator = ctx.reset_coordinator;

    // 显式 source_binding 必须与 source_identity 是同一 incarnation；否则
    // context 不能把错误 Function 的 owner handle 带入共享 coordinator。
    mismatched_identity = make_identity();
    status = mismatched_identity.configure(
      mismatched_identity.key, mismatched_identity.global_function_id,
      mismatched_identity.function_uid, 77, mismatched_identity.reset_epoch);
    mismatched_binding = rdma_function_binding::type_id::create(
      "mismatched_context_binding");
    if (mismatched_binding == null || status == null || !status.ok())
      `uvm_fatal("CTX", "mismatched identity fixture allocation failed")
    status = mismatched_binding.configure_identity(mismatched_identity);
    if (status == null || !status.ok())
      `uvm_fatal("CTX", "mismatched binding fixture configuration failed")
    mismatch_context = null;
    failure_status = rdma_function_context::build(
      identity, resources, host_mem, pcie, registry, 1ns, mismatch_context,
      coordinator, mismatched_binding);
    if (failure_status == null ||
        failure_status.code != RDMA_SC_INVALID_ARGUMENT ||
        mismatch_context != null)
      `uvm_error("CTX_AUTHORITY", "mismatched binding identity was accepted")

    // build_shared 的三个 factory 边界必须返回非空 RESOURCE_EXHAUSTED，且
    // output context 保持 null；故障 wrapper 关闭后仍委托原 registry。
    factory = uvm_factory::get();
    binding_fault = new("context_binding_fault",
                        rdma_function_binding::get_type());
    context_fault = new("context_object_fault",
                        rdma_function_context::get_type());
    coordinator_fault = new("context_coordinator_fault",
                            rdma_reset_coordinator::get_type());
    identity_fault = new("context_identity_fault",
                         rdma_function_identity::get_type());
    handle_fault = new("context_handle_fault",
                       rdma_function_handle::get_type());
    saved_binding_override = factory.find_override_by_type(
      rdma_function_binding::get_type(), "");
    saved_context_override = factory.find_override_by_type(
      rdma_function_context::get_type(), "");
    saved_coordinator_override = factory.find_override_by_type(
      rdma_reset_coordinator::get_type(), "");
    saved_identity_override = factory.find_override_by_type(
      rdma_function_identity::get_type(), "");
    saved_handle_override = factory.find_override_by_type(
      rdma_function_handle::get_type(), "");
    factory.set_type_override_by_type(
      rdma_function_binding::get_type(), binding_fault, 1'b1);
    factory.set_type_override_by_type(
      rdma_function_context::get_type(), context_fault, 1'b1);
    factory.set_type_override_by_type(
      rdma_reset_coordinator::get_type(), coordinator_fault, 1'b1);
    factory.set_type_override_by_type(
      rdma_function_identity::get_type(), identity_fault, 1'b1);
    factory.set_type_override_by_type(
      rdma_function_handle::get_type(), handle_fault, 1'b1);

    failed_context = null;
    binding_fault.arm();
    failure_status = rdma_function_context::build(
      identity, resources, host_mem, pcie, registry, 1ns, failed_context,
      null_coordinator, null_binding);
    if (failure_status == null || failure_status.code != RDMA_SC_RESOURCE_EXHAUSTED ||
        failed_context != null)
      `uvm_error("CTX_FACTORY", "null binding factory result was not rejected atomically")
    binding_fault.disarm();

    failed_context = null;
    context_fault.arm();
    failure_status = rdma_function_context::build(
      identity, resources, host_mem, pcie, registry, 1ns, failed_context,
      coordinator, source_binding);
    if (failure_status == null || failure_status.code != RDMA_SC_RESOURCE_EXHAUSTED ||
        failed_context != null)
      `uvm_error("CTX_FACTORY", "null context factory result was not rejected atomically")
    context_fault.disarm();

    failed_context = null;
    coordinator_fault.arm();
    failure_status = rdma_function_context::build(
      identity, resources, host_mem, pcie, registry, 1ns, failed_context,
      null_coordinator, source_binding);
    if (failure_status == null || failure_status.code != RDMA_SC_RESOURCE_EXHAUSTED ||
        failed_context != null)
      `uvm_error("CTX_FACTORY", "null coordinator factory result was not rejected atomically")
    coordinator_fault.disarm();

    // reset 的候选 binding 尚未提交时，identity/binding/state 必须保持旧组合。
    // 先用正常 registry 建立独立 context，再分别注入 identity/binding/owner null。
      failure_status = rdma_function_context::build(
        identity, resources, host_mem, pcie, registry, 1ns, reset_context,
        coordinator, source_binding);
    if (failure_status == null || !failure_status.ok() || reset_context == null)
      `uvm_error("CTX_FACTORY", "reset atomicity fixture build failed")
    else begin
      old_identity = reset_context.identity;
      old_binding = reset_context.binding;
      handle_fault.arm();
      failure_status = reset_context.activate();
      if (failure_status == null ||
          failure_status.code != RDMA_SC_RESOURCE_EXHAUSTED ||
          reset_context.state != RDMA_CONTEXT_DISCOVERED ||
          reset_context.binding.state != RDMA_BIND_DISCOVERED ||
          reset_context.binding.owner_h != null)
        `uvm_error("CTX_ACTIVATE", "null owner handle changed undiscovered context")
      handle_fault.disarm();

      identity_fault.arm();
      failure_status = reset_context.reset(3, 10);
      if (failure_status == null || failure_status.code != RDMA_SC_RESOURCE_EXHAUSTED ||
          reset_context.identity != old_identity || reset_context.binding != old_binding ||
          reset_context.identity.generation != 1)
        `uvm_error("CTX_RESET", "null reset identity factory result changed old composition")
      identity_fault.disarm();

      reset_context.binding = null;
      binding_fault.arm();
      failure_status = reset_context.reset(3, 10);
      if (failure_status == null || failure_status.code != RDMA_SC_RESOURCE_EXHAUSTED ||
          reset_context.identity != old_identity || reset_context.identity.generation != 1 ||
          reset_context.state != RDMA_CONTEXT_DISCOVERED)
        `uvm_error("CTX_RESET", "null reset binding factory result changed old identity/state")
      binding_fault.disarm();
      reset_context.binding = old_binding;

      old_binding.owner_h = null;
      old_binding.state = RDMA_BIND_DISCOVERED;
      handle_fault.arm();
      failure_status = reset_context.reset(3, 10);
      if (failure_status == null || failure_status.code != RDMA_SC_RESOURCE_EXHAUSTED ||
          reset_context.identity != old_identity || reset_context.binding != old_binding ||
          reset_context.identity.generation != 1 ||
          reset_context.state != RDMA_CONTEXT_DISCOVERED)
        `uvm_error("CTX_RESET", "null reset owner handle changed old composition")
      handle_fault.disarm();
    end

    // Batch101 focused commit seam：candidate 在 epoch/状态发布前完成 prepare+validate；
    // 随后 arm identity/binding/owner factory，commit 仍必须只交换已准备句柄，不能再次
    // 触发 clone、identity_snapshot() 或 owner-handle factory。
    candidate_context = null;
    failure_status = rdma_function_context::build(
      identity, resources, host_mem, pcie, registry, 1ns, candidate_context,
      coordinator, source_binding);
    if (failure_status == null || !failure_status.ok() ||
        candidate_context == null)
      `uvm_error("CTX_RESET_ATOMICITY",
                 "candidate commit fixture build failed")
    else begin
      failure_status = candidate_context.activate();
      if (failure_status == null || !failure_status.ok())
        `uvm_error("CTX_RESET_ATOMICITY",
                   "candidate commit fixture activation failed")
      candidate_old_identity = candidate_context.identity;
      candidate_old_binding = candidate_context.binding;
      candidate_old_state = candidate_context.state;
      reset_candidate = null;
      failure_status = candidate_context.quiesce();
      if (failure_status == null || !failure_status.ok())
        `uvm_error("CTX_RESET_ATOMICITY",
                   "candidate commit fixture quiesce failed")
      failure_status = candidate_context.prepare_reset(
        candidate_old_identity.generation + 1,
        candidate_old_identity.reset_epoch + 1,
        reset_candidate);
      if (failure_status == null || !failure_status.ok() ||
          reset_candidate == null)
        `uvm_error("CTX_RESET_ATOMICITY",
                   "reset candidate prepare failed")
      else begin
        failure_status = candidate_context.validate_reset_candidate(
          reset_candidate);
        if (failure_status == null || !failure_status.ok() ||
            !reset_candidate.validation_complete)
          `uvm_error("CTX_RESET_ATOMICITY",
                     "reset candidate validation failed")
        identity_fault.arm();
        binding_fault.arm();
        handle_fault.arm();
        failure_status = candidate_context.commit_reset(reset_candidate);
        identity_fault.disarm();
        binding_fault.disarm();
        handle_fault.disarm();
        if (failure_status == null || !failure_status.ok() ||
            candidate_context.identity != reset_candidate.identity ||
            candidate_context.binding != reset_candidate.binding ||
            candidate_context.identity == candidate_old_identity ||
            candidate_context.binding == candidate_old_binding ||
            candidate_context.state != RDMA_CONTEXT_ACTIVE ||
            candidate_context.identity.generation !=
              candidate_old_identity.generation + 1 ||
            candidate_context.identity.reset_epoch !=
              candidate_old_identity.reset_epoch + 1)
          `uvm_error("CTX_RESET_ATOMICITY",
                     "validated reset commit did not publish detached candidate")
      end
    end
    reset_context_factory_state();
    phase.drop_objection(this);
  endtask
endclass
