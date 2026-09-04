// 目录：tests/integration/，位于 dpu_common→RDMA integration 适配层的集成测试。
// 职责：构造冻结 device/resource snapshot，验证 Function identity、真实 BAR、mailbox
//       notify aperture、MSI-X 和 DMA segment 均由 dpu_common 数据投影而来。
// 依赖：rdma_dpu_identity_adapter、rdma_dpu_env_pkg、dpu_common snapshot 类型和 UVM。
// 所有权与生命周期：测试夹具拥有 snapshot；适配器返回的 identity/binding 由测试持有至
//       run_phase() 结束，不触碰外部 PCIe 或 Host-memory 真实资源。
class rdma_dpu_test_device_snapshot extends dpu_device_snapshot;
  `uvm_object_utils(rdma_dpu_test_device_snapshot)

  // 功能：构造测试用 dpu_common device snapshot 夹具。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：构造过程不分配 Host-memory、PCIe endpoint 或 manager 资源；空 name 也必须得到可配置对象。
  function new(string name = "rdma_dpu_test_device_snapshot");
    super.new(name);
  endfunction

  // 测试夹具只需要验证查询接口；正式 resolver 仍负责完整 freeze 校验。
  // 功能：为夹具补齐 global Function ID 并标记 snapshot frozen，使 adapter 可以按
  //       生产查询接口读取；仅用于测试，不改变生产 resolver 语义。
  // 输入/输出及副作用：无显式参数；force_queryable 读取 对象字段：next_global_id、m_frozen 并使用字段 next_global_id、m_frozen；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：force_queryable 无返回值，仅执行 next_global_id=17、m_frozen=1'b1；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  function void force_queryable();
    int unsigned next_global_id;
    next_global_id = 17;
    foreach (m_function_order[index]) begin
      m_global_function_ids[m_function_order[index]] = next_global_id;
      next_global_id++;
    end
    m_frozen = 1'b1;
  endfunction
endclass

class rdma_dpu_test_resource_snapshot extends dpu_resource_snapshot;
  `uvm_object_utils(rdma_dpu_test_resource_snapshot)

  // 功能：构造测试用 dpu_common resource snapshot 夹具。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：构造过程不分配 Host-memory、PCIe endpoint 或 manager 资源；空 name 也必须得到可配置对象。
  function new(string name = "rdma_dpu_test_resource_snapshot");
    super.new(name);
  endfunction

  // 仅构造跨 snapshot 引用关系，避免测试重复实现 resource resolver。
  // 功能：建立 resource snapshot 对指定 device snapshot 的一致性引用并冻结夹具。
  // 输入/输出及副作用：device_snapshot（输入）；force_coherent 读取 device_snapshot 并使用字段 m_device_snapshot、m_frozen；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：传入 null 将由上层 adapter 的 coherence 检查拒绝。
  function void force_coherent(dpu_device_snapshot device_snapshot);
    m_device_snapshot = device_snapshot;
    m_frozen = 1'b1;
  endfunction
endclass

class rdma_dpu_integration_test extends uvm_test;
  `uvm_component_utils(rdma_dpu_integration_test)

  // 功能：构造 UVM dpu_common integration 测试组件。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：构造过程不分配 Host-memory、PCIe endpoint 或 manager 资源；空 name 也必须得到可配置对象。
  function new(string name="rdma_dpu_integration_test", uvm_component parent=null);
    super.new(name,parent);
  endfunction

  // 功能：返回本测试使用的 Host0/PF0 Function key，集中保持 fixture 与断言一致。
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

  // 功能：断言 binding 中指定 BAR 的 enabled/base/size 与 dpu_common fixture 完全一致。
  // 输入/输出及副作用：binding（输入）、index（输入）、base（输入）、size（输入）、label（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT
  //   转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  function automatic void expect_bar(
    rdma_function_binding binding,
    int unsigned index,
    bit [63:0] base,
    bit [63:0] size,
    string label
  );
    if (binding.pcie.bar[index] == null ||
        !binding.pcie.bar[index].enabled ||
        binding.pcie.bar[index].base.value != base ||
        binding.pcie.bar[index].size != size)
      `uvm_error("DPU_INT", {label, " was not projected from dpu_common"})
  endfunction

  // 功能：搭建冻结 dpu_common 快照并执行完整 identity/binding 投影断言，覆盖固定常量
  //       回退、notify aperture 和 DMA domain 错映射等回归风险。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：仿真超时、事务返回错误或断言不满足时报告 UVM_ERROR/UVM_FATAL；空 fixture 不得被当作成功。
  task run_phase(uvm_phase phase);
    rdma_dpu_identity_adapter adapter;
    rdma_dpu_test_device_snapshot device_snapshot;
    rdma_dpu_test_resource_snapshot resource_snapshot;
    dpu_function_key_t key;
    dpu_pcie_function_id_t pcie_id;
    dpu_bar_pair_lease_t bar;
    dpu_dut_caps caps;
    rdma_function_identity identity;
    rdma_function_binding binding;
    rdma_status status;
    string why;

    phase.raise_objection(this);
    adapter = rdma_dpu_identity_adapter::type_id::create("adapter");
    if (adapter == null)
      `uvm_fatal("DPU_INT", "adapter creation failed")

    key = make_key();
    device_snapshot = rdma_dpu_test_device_snapshot::type_id::create(
      "device_snapshot");
    caps = dpu_dut_caps::type_id::create("caps");
    pcie_id.domain.host_id = 0;
    pcie_id.domain.segment_id = 3;
    pcie_id.bdf = 16'h0210;
    if (!device_snapshot.set_dut_caps(caps, why) ||
        !device_snapshot.add_function(key, pcie_id, why))
      `uvm_fatal("DPU_INT", {"device snapshot fixture failed: ", why})

    bar.role = DPU_BAR_DEVICE_MEMORY;
    bar.even_bar_id = 0;
    bar.base = 64'h0000_0001_1000_0000;
    bar.size = 64'h0000_0000_0020_0000;
    if (!device_snapshot.add_bar(key, bar, why))
      `uvm_fatal("DPU_INT", {"device BAR0 fixture failed: ", why})
    bar.role = DPU_BAR_MAILBOX;
    bar.even_bar_id = 2;
    bar.base = 64'h0000_0001_1020_0000;
    bar.size = 64'h0000_0000_0001_0000;
    if (!device_snapshot.add_bar(key, bar, why))
      `uvm_fatal("DPU_INT", {"mailbox BAR fixture failed: ", why})
    bar.role = DPU_BAR_MSIX;
    bar.even_bar_id = 4;
    bar.base = 64'h0000_0001_1030_0000;
    bar.size = 64'h0000_0000_0001_0000;
    if (!device_snapshot.add_bar(key, bar, why))
      `uvm_fatal("DPU_INT", {"MSI-X BAR fixture failed: ", why})
    device_snapshot.force_queryable();
    resource_snapshot = rdma_dpu_test_resource_snapshot::type_id::create(
      "resource_snapshot");
    resource_snapshot.force_coherent(device_snapshot);

    status = rdma_dpu_identity_adapter::from_snapshot(
      device_snapshot, resource_snapshot, key, identity, binding);
    if (!status.ok() || identity == null || binding == null)
      `uvm_fatal("DPU_INT", {"snapshot translation failed: ", status.message})
    expect_bar(binding, 0, 64'h0000_0001_1000_0000,
               64'h0000_0000_0020_0000, "device BAR");
    expect_bar(binding, 2, 64'h0000_0001_1020_0000,
               64'h0000_0000_0001_0000, "mailbox BAR");
    expect_bar(binding, 4, 64'h0000_0001_1030_0000,
               64'h0000_0000_0001_0000, "MSI-X BAR");
    if (binding.notify_bar_id != 2 ||
        binding.notify_base.value != 64'h0000_0001_1020_0000 ||
        binding.notify_size != 64'h0000_0000_0001_0000)
      `uvm_error("DPU_INT", "notify aperture was not projected from mailbox BAR")
    if (binding.queue_dma.dma_domain_id != 3)
      `uvm_error("DPU_INT", "DMA domain did not use the PCIe segment")
    phase.drop_objection(this);
  endtask
endclass
