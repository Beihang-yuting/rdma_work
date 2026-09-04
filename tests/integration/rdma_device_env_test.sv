// 目录：tests/integration/，验证 rdma_device_env 对 dpu_common Function 的枚举索引。
// 职责：确保每个冻结 Function 都建立独立 context，并可按完整 identity 或 Function
//       handle 查询；不验证队列编码，也不连接真实 PCIe/Host-memory 数据面。
// 依赖：rdma_dpu_env_pkg、现有 dpu snapshot fixture、dpu_resource_manager 和 UVM。
// 所有权与生命周期：测试拥有快照、router、manager、coordinator 和 device env；
//       env/context 只保存外部依赖引用，测试结束时随 UVM 对象生命周期结束。

class rdma_device_env_test extends uvm_test;
  `uvm_component_utils(rdma_device_env_test)

  // 功能：构造 device env 枚举测试组件；测试主体在 run_phase() 中执行。
  function new(string name = "rdma_device_env_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：返回单 PF fixture 使用的 Host/PF key，和 dpu_common snapshot 查询保持一致。
  function automatic dpu_function_key_t make_key();
    dpu_function_key_t key;
    key.host_id = 0;
    key.pf_id = 0;
    key.kind = DPU_FUNCTION_PF;
    key.vf_id = 0;
    return key;
  endfunction

  // 功能：构造带真实 PCIe ID、三类 BAR、global ID 的冻结 device/resource snapshot。
  // 输出：通过 output 返回两份相互关联的测试快照；任何夹具错误直接报告 fatal。
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
  // 副作用：只创建集成层对象并读取索引，不触发 queue allocation 或外部 I/O。
  task run_phase(uvm_phase phase);
    rdma_dpu_test_device_snapshot device_snapshot;
    rdma_dpu_test_resource_snapshot resource_snapshot;
    dpu_resource_manager dpu_manager;
    rdma_host_mem_router host_mem;
    rdma_pcie_router pcie;
    rdma_reset_coordinator coordinator;
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
    end
    phase.drop_objection(this);
  endtask
endclass
