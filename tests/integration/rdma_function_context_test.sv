// 目录：tests/integration/，验证单 Function context 的生命周期和 authority 隔离。
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

class rdma_function_context_test extends uvm_test;
  `uvm_component_utils(rdma_function_context_test)

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
    rdma_function_binding source_binding;
    rdma_status status;

    phase.raise_objection(this);
    identity = make_identity();
    resources = rdma_context_test_resource_snapshot::type_id::create(
      "context_resources");
    resources.force_frozen();
    host_mem = rdma_host_mem_router::type_id::create("context_host_mem");
    pcie = rdma_pcie_router::type_id::create("context_pcie");

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
    phase.drop_objection(this);
  endtask
endclass
