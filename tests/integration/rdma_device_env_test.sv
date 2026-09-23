// 目录/层次：tests/integration/ 集成测试层，验证 rdma_device_env 对 dpu_common Function 的枚举索引。
// 职责：确保每个冻结 Function 都建立独立 context，并可按完整 identity 或 Function
//       handle 查询；不验证队列编码，也不连接真实 PCIe/Host-memory 数据面。
// 依赖：rdma_dpu_env_pkg、现有 dpu snapshot fixture、dpu_resource_manager 和 UVM。
// 所有权与生命周期：测试拥有快照、router、manager、coordinator 和 device env；
//       env/context 只保存外部依赖引用，测试显式调用 close() 验证双侧 detach、lease
//       释放和重复 close 的幂等语义，外部快照/manager 仍由测试持有。

class rdma_device_env_test extends uvm_test;
  `uvm_component_utils(rdma_device_env_test)

  // 功能：构造 device env 枚举测试组件；测试主体在 run_phase() 中执行。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：构造过程不分配 Host-memory、PCIe endpoint 或 manager 资源；空 name 也必须得到可配置对象。
  function new(string name = "rdma_device_env_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：返回单 PF fixture 使用的 Host/PF key，和 dpu_common snapshot 查询保持一致。
  // 输入/输出及副作用：无显式参数；make_key 读取局部计算结果，并使用字段 key.host_id、key.pf_id、key.kind、key.vf_id；函数返回 dpu_function_key_t，不取得调用方资源所有权。
  // 失败/边界：输入为空、类型不匹配或字段组合非法时返回空值/错误；不得发布不完整快照。
  function automatic dpu_function_key_t make_key();
    dpu_function_key_t key;
    key.host_id = 0;
    key.pf_id = 0;
    key.kind = DPU_FUNCTION_PF;
    key.vf_id = 0;
    return key;
  endfunction

  // 功能：构造带真实 PCIe ID、三类 BAR、global ID 的冻结 device/resource snapshot。
  // 输入/输出及副作用：device_snapshot（输出）、resource_snapshot（输出）；build_snapshots 驱动下游事务，并写入 device_snapshot、resource_snapshot；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：输入为空、类型不匹配或字段组合非法时返回空值/错误；不得发布不完整快照。
  task automatic build_snapshots(
    output rdma_dpu_test_device_snapshot device_snapshot,
    output rdma_dpu_test_resource_snapshot resource_snapshot
  );
    dpu_function_key_t key;
    dpu_pcie_function_id_t pcie_id;
    dpu_bar_pair_lease_t bar;
    dpu_dut_caps caps;
    string why;

    key = make_key();
    device_snapshot = rdma_dpu_test_device_snapshot::type_id::create(
      "device_env_device_snapshot");
    caps = dpu_dut_caps::type_id::create("device_env_caps");
    pcie_id.domain.host_id = 0;
    pcie_id.domain.segment_id = 3;
    pcie_id.bdf = 16'h0210;
    if (!device_snapshot.set_dut_caps(caps, why) ||
        !device_snapshot.add_function(key, pcie_id, why))
      `uvm_fatal("DEV_ENV", {"device fixture failed: ", why})

    bar.role = DPU_BAR_DEVICE_MEMORY;
    bar.even_bar_id = 0;
    bar.base = 64'h0000_0001_1000_0000;
    bar.size = 64'h0000_0000_0020_0000;
    if (!device_snapshot.add_bar(key, bar, why))
      `uvm_fatal("DEV_ENV", {"device BAR fixture failed: ", why})
    bar.role = DPU_BAR_MAILBOX;
    bar.even_bar_id = 2;
    bar.base = 64'h0000_0001_1020_0000;
    bar.size = 64'h0000_0000_0001_0000;
    if (!device_snapshot.add_bar(key, bar, why))
      `uvm_fatal("DEV_ENV", {"mailbox BAR fixture failed: ", why})
    bar.role = DPU_BAR_MSIX;
    bar.even_bar_id = 4;
    bar.base = 64'h0000_0001_1030_0000;
    bar.size = 64'h0000_0000_0001_0000;
    if (!device_snapshot.add_bar(key, bar, why))
      `uvm_fatal("DEV_ENV", {"MSI-X BAR fixture failed: ", why})
    device_snapshot.force_queryable();

    resource_snapshot = rdma_dpu_test_resource_snapshot::type_id::create(
      "device_env_resource_snapshot");
    resource_snapshot.force_coherent(device_snapshot);
  endtask

  // 功能：验证 device env build 后可按 identity 和 Function handle 找到同一 context。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：仿真超时、事务返回错误或断言不满足时报告 UVM_ERROR/UVM_FATAL；空 fixture 不得被当作成功。
  task run_phase(uvm_phase phase);
    rdma_dpu_test_device_snapshot device_snapshot;
    rdma_dpu_test_resource_snapshot resource_snapshot;
    dpu_resource_manager dpu_manager;
    rdma_host_mem_router host_mem;
    rdma_pcie_router pcie;
    rdma_reset_coordinator coordinator;
    rdma_reset_coordinator foreign_coordinator;
    rdma_device_env env;
    rdma_function_identity identity;
    rdma_function_context found_context;
    rdma_handle function_h;
    rdma_status status;
    dpu_function_key_t key;
    uvm_object registry;

    phase.raise_objection(this);
    build_snapshots(device_snapshot, resource_snapshot);
    dpu_manager = dpu_resource_manager::type_id::create("dpu_manager");
    host_mem = rdma_host_mem_router::type_id::create("device_env_host_mem");
    pcie = rdma_pcie_router::type_id::create("device_env_pcie");
    coordinator = rdma_reset_coordinator::type_id::create("device_env_reset");
    key = make_key();

    status = rdma_device_env::build(
      device_snapshot, resource_snapshot, dpu_manager, host_mem, pcie,
      registry, 1ns, env, coordinator);
    if (!status.ok() || env == null)
      `uvm_error("DEV_ENV", "device env build failed")
    else begin
      identity = env.get_identity(key);
      if (identity == null)
        `uvm_error("DEV_ENV", "device env did not index Function identity")
      status = env.find_function(identity, found_context);
      if (!status.ok() || found_context == null)
        `uvm_error("DEV_ENV", "identity lookup did not find context")

      function_h = rdma_handle::type_id::create("device_env_function_handle");
      function_h.kind = RDMA_RESOURCE_FUNCTION;
      function_h.function_uid = identity.function_uid;
      function_h.object_id = identity.global_function_id;
      function_h.generation = identity.generation;
      status = env.find_handle(function_h, found_context);
      if (!status.ok() || found_context == null)
        `uvm_error("DEV_ENV", "Function handle lookup did not find context")

      // close 原子性边界：故意把 retained context 的 coordinator 引用改成未 claim 的
      // foreign coordinator。预检必须在 detach 前拒绝，旧 coordinator 的 lease、router
      // 双侧绑定、registration ledger 和 context 值图都应保持不变；恢复引用后再验证
      // 正常 close，覆盖失败后可重试的生命周期契约。
      foreign_coordinator = rdma_reset_coordinator::type_id::create(
        "device_env_foreign_close_coordinator"
      );
      found_context.reset_coordinator = foreign_coordinator;
      status = env.close();
      if (status == null || status.ok())
        `uvm_error("DEV_ENV_LIFECYCLE",
                   "close accepted a context with foreign coordinator authority")
      if (!coordinator.lease_held() || !coordinator.host_router_bound() ||
          coordinator.function_count() == 0 ||
          found_context.identity == null || found_context.binding == null)
        `uvm_error("DEV_ENV_LIFECYCLE",
                   "failed close detached router/lease or mutated context state")
      found_context.reset_coordinator = coordinator;

      // Batch109 生命周期边界：build 成功后 env 独占 coordinator lease，close() 必须
      // 先清掉 coordinator/router 双侧绑定，再清理 context/identity 引用。close() 返回
      // 前不应留下可被旧 identity 或 handle 查询到的 context，也不能让已关闭 env 再次
      // 发起 reset；重复 close 则必须保持幂等成功。
      status = env.close();
      if (status == null || !status.ok())
        `uvm_error("DEV_ENV_LIFECYCLE", "device env close returned an error")
      if (coordinator == null)
        `uvm_error("DEV_ENV_LIFECYCLE", "close fixture lost coordinator handle")
      else if (coordinator.lease_held() || coordinator.host_router_bound() ||
               coordinator.function_count() != 0)
        `uvm_error("DEV_ENV_LIFECYCLE",
                   "close left coordinator lease, router binding, or registration ledger active")
      if (env.context_count() != 0 || env.get_identity(key) != null ||
          found_context == null || found_context.reset_coordinator != null ||
          env.device_snapshot != null || env.resources != null ||
          env.resource_manager != null || env.host_mem != null || env.pcie != null)
        `uvm_error("DEV_ENV_LIFECYCLE",
                   "device env close did not atomically release lease and references")
      if (found_context.state != RDMA_CONTEXT_QUARANTINED ||
          found_context.identity != null || found_context.binding != null ||
          found_context.resources != null || found_context.resource_manager != null ||
          found_context.host_mem != null || found_context.pcie != null)
        `uvm_error("DEV_ENV_LIFECYCLE",
                   "retained Function context was not quarantined on close")
      status = found_context.activate();
      if (status == null || status.code != RDMA_SC_INVALID_STATE)
        `uvm_error("DEV_ENV_LIFECYCLE",
                   "retained quarantined context accepted activate")
      status = found_context.reset(2, 1);
      if (status == null || status.code != RDMA_SC_INVALID_STATE)
        `uvm_error("DEV_ENV_LIFECYCLE",
                   "retained quarantined context accepted reset")
      status = found_context.lookup_queue(function_h);
      if (status == null || status.code != RDMA_SC_INVALID_STATE)
        `uvm_error("DEV_ENV_LIFECYCLE",
                   "retained quarantined context accepted queue lookup")
      status = env.request_device_reset();
      if (status == null || status.code != RDMA_SC_INVALID_STATE)
        `uvm_error("DEV_ENV_LIFECYCLE",
                   "closed device env accepted a reset request")
      status = env.find_function(identity, found_context);
      if (status == null || status.code != RDMA_SC_INVALID_STATE ||
          found_context != null)
        `uvm_error("DEV_ENV_LIFECYCLE",
                   "closed device env retained a Function lookup path")
      status = env.close();
      if (status == null || !status.ok())
        `uvm_error("DEV_ENV_LIFECYCLE", "repeated device env close was not idempotent")
    end
    phase.drop_objection(this);
  endtask
endclass
