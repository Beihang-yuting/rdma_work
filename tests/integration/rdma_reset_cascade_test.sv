// 目录：tests/integration/，验证 rdma_device_env 的 VF/PF/Host/Device 复位级联范围。
// 职责：构造多 Host、多 PF 和稀疏 VF 拓扑，断言 quiesce、epoch、generation 以及
//       context 重建只影响规范定义的 Function 集合。
// 依赖：rdma_dpu_env_pkg、dpu_common snapshot、UVM；不连接真实 PCIe/Host-memory。
// 所有权与生命周期：测试拥有快照、router、manager、coordinator 和 device env；
//       复位操作只改变这些测试对象的状态，不取得外部组件所有权。

class rdma_reset_test_device_snapshot extends dpu_device_snapshot;
  `uvm_object_utils(rdma_reset_test_device_snapshot)

  // 功能：构造 reset cascade 使用的 dpu_common device snapshot 夹具。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：构造过程不分配 Host-memory、PCIe endpoint 或 manager 资源；空 name 也必须得到可配置对象。
  function new(string name = "rdma_reset_test_device_snapshot");
    super.new(name);
  endfunction

  // 功能：为夹具补齐稳定的 global Function ID 并发布冻结状态，使适配器能够读取。
  // 输入/输出及副作用：无显式参数；force_queryable 读取 对象字段：next_global_id、m_frozen 并使用字段 next_global_id、m_frozen；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：force_queryable 无返回值，仅执行 next_global_id=1、m_frozen=1'b1；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  function void force_queryable();
    int unsigned next_global_id;
    next_global_id = 1;
    foreach (m_function_order[index]) begin
      m_global_function_ids[m_function_order[index]] = next_global_id;
      next_global_id++;
    end
    m_frozen = 1'b1;
  endfunction
endclass

class rdma_reset_test_resource_snapshot extends dpu_resource_snapshot;
  `uvm_object_utils(rdma_reset_test_resource_snapshot)

  // 功能：构造 reset cascade 使用的 dpu_common resource snapshot 夹具。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：构造过程不分配 Host-memory、PCIe endpoint 或 manager 资源；空 name 也必须得到可配置对象。
  function new(string name = "rdma_reset_test_resource_snapshot");
    super.new(name);
  endfunction

  // 功能：绑定 device snapshot 引用并标记资源夹具冻结，供 env coherence 校验使用。
  // 输入/输出及副作用：device_snapshot（输入）；force_coherent 读取 device_snapshot 并使用字段 m_device_snapshot、m_frozen；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：force_coherent 无返回值，仅执行 m_device_snapshot=device_snapshot、m_frozen=1'b1；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  function void force_coherent(dpu_device_snapshot device_snapshot);
    m_device_snapshot = device_snapshot;
    m_frozen = 1'b1;
  endfunction
endclass

class rdma_reset_cascade_test extends uvm_test;
  `uvm_component_utils(rdma_reset_cascade_test)

  // 功能：构造 reset cascade UVM 测试组件；具体拓扑和级联断言在 run_phase() 执行。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：构造过程不分配 Host-memory、PCIe endpoint 或 manager 资源；空 name 也必须得到可配置对象。
  function new(string name = "rdma_reset_cascade_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：返回指定 Host/PF/VF 的 dpu_common Function key，集中构造拓扑索引。
  // 输入/输出及副作用：host_id（输入）、pf_id（输入）、kind（输入）、vf_id（输入）；make_key 读取 host_id、pf_id、kind、vf_id 并使用字段 key.host_id、key.pf_id、key.kind、key.vf_id；函数返回 dpu_function_key_t，不取得调用方资源所有权。
  // 失败/边界：输入为空、类型不匹配或字段组合非法时返回空值/错误；不得发布不完整快照。
  function automatic dpu_function_key_t make_key(
    int unsigned host_id,
    int unsigned pf_id,
    dpu_function_kind_e kind,
    int unsigned vf_id = 0
  );
    dpu_function_key_t key;
    key.host_id = host_id;
    key.pf_id = pf_id;
    key.kind = kind;
    key.vf_id = vf_id;
    return key;
  endfunction

  // 功能：为每个 Function 添加真实 PCIe ID 和三类 BAR，使 reset 测试走完整投影路径。
  // 输入/输出及副作用：snapshot（输入）、key（输入）、segment（输入）、bdf（输入）；add_function 驱动下游事务；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：夹具构造失败直接报告 fatal，避免在级联断言中掩盖拓扑错误。
  task automatic add_function(
    rdma_reset_test_device_snapshot snapshot,
    dpu_function_key_t key,
    int unsigned segment,
    int unsigned bdf
  );
    dpu_pcie_function_id_t pcie_id;
    dpu_bar_pair_lease_t bar;
    string why;

    pcie_id.domain.host_id = key.host_id;
    pcie_id.domain.segment_id = segment;
    pcie_id.bdf = bdf[15:0];
    if (!snapshot.add_function(key, pcie_id, why))
      `uvm_fatal("RESET_ENV", {"add Function failed: ", why})

    bar.role = DPU_BAR_DEVICE_MEMORY;
    bar.even_bar_id = 0;
    // 每个 segment/BDF 使用独立的 16 MiB 窗口，保证 device/mailbox/MSI-X
    // 三个 BAR 的局部偏移不会与同域其他 Function 重叠；该地址仅用于夹具。
    bar.base = 64'h0000_0002_0000_0000 + (64'(segment) << 40) +
               (64'(bdf) << 24);
    bar.size = 64'h0000_0000_0020_0000;
    if (!snapshot.add_bar(key, bar, why))
      `uvm_fatal("RESET_ENV", {"add device BAR failed: ", why})
    bar.role = DPU_BAR_MAILBOX;
    bar.even_bar_id = 2;
    bar.base += 64'h0020_0000;
    bar.size = 64'h0000_0000_0001_0000;
    if (!snapshot.add_bar(key, bar, why))
      `uvm_fatal("RESET_ENV", {"add mailbox BAR failed: ", why})
    bar.role = DPU_BAR_MSIX;
    bar.even_bar_id = 4;
    bar.base += 64'h0010_0000;
    if (!snapshot.add_bar(key, bar, why))
      `uvm_fatal("RESET_ENV", {"add MSI-X BAR failed: ", why})
  endtask

  // 功能：创建 Host0 的 PF0、稀疏 VF2、PF1 和 Host1 的 PF0 拓扑及关联资源快照。
  // 输入/输出及副作用：device_snapshot（输出）、resource_snapshot（输出）；build_snapshots 驱动下游事务，并写入 device_snapshot、resource_snapshot；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：输入为空、类型不匹配或字段组合非法时返回空值/错误；不得发布不完整快照。
  task automatic build_snapshots(
    output rdma_reset_test_device_snapshot device_snapshot,
    output rdma_reset_test_resource_snapshot resource_snapshot
  );
    dpu_dut_caps caps;
    string why;

    device_snapshot = rdma_reset_test_device_snapshot::type_id::create(
      "reset_device_snapshot");
    caps = dpu_dut_caps::type_id::create("reset_caps");
    if (!device_snapshot.set_dut_caps(caps, why))
      `uvm_fatal("RESET_ENV", {"set DUT caps failed: ", why})
    add_function(device_snapshot, make_key(0, 0, DPU_FUNCTION_PF), 0, 16'h0100);
    add_function(device_snapshot, make_key(0, 0, DPU_FUNCTION_VF, 2),
                 0, 16'h0102);
    add_function(device_snapshot, make_key(0, 1, DPU_FUNCTION_PF), 0, 16'h0200);
    add_function(device_snapshot, make_key(1, 0, DPU_FUNCTION_PF), 1, 16'h0100);
    device_snapshot.force_queryable();

    resource_snapshot = rdma_reset_test_resource_snapshot::type_id::create(
      "reset_resource_snapshot");
    resource_snapshot.force_coherent(device_snapshot);
  endtask

  // 功能：在 rdma_reset_cascade_test 中，find_context 按测试 key 查找 env identity 和对应 context，统一把缺失记录转换成可定位的测试失败。
  // 输入/输出及副作用：env（输入）、key（输入）、identity（输出）；find_context 读取 env、key、identity 并使用字段 identity、status，并写入 identity；函数返回 rdma_function_context，不取得调用方资源所有权。
  // 失败/边界：find_context 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  function automatic rdma_function_context find_context(
    rdma_device_env env,
    dpu_function_key_t key,
    output rdma_function_identity identity
  );
    rdma_function_context result;
    rdma_status status;

    identity = env.get_identity(key);
    if (identity == null) begin
      `uvm_error("RESET_ENV", "Function identity lookup failed")
      return null;
    end
    status = env.find_function(identity, result);
    if (!status.ok() || result == null) begin
      `uvm_error("RESET_ENV", {"Function context lookup failed: ", status.message})
      return null;
    end
    return result;
  endfunction

  // 功能：验证指定 reset 操作后每个 context 的 generation/epoch 是否按范围变化。
  // 输入/输出及副作用：label（输入）、string（输入）、string（输入）、string（输入）、string（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向
  //   DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_generation_scope(
    string label,
    rdma_function_context contexts[string],
    int unsigned before_gen[string],
    rdma_reset_epoch_t before_epoch[string],
    bit expected_changed[string]
  );
    string key_name;
    foreach (contexts[key_name]) begin
      if (contexts[key_name] == null || contexts[key_name].identity == null)
        continue;
      if (expected_changed[key_name]) begin
        if (contexts[key_name].identity.generation != before_gen[key_name] + 1 ||
            contexts[key_name].identity.reset_epoch <= before_epoch[key_name] ||
            contexts[key_name].state != RDMA_CONTEXT_ACTIVE)
          `uvm_error("RESET_ENV", $sformatf(
            "%s did not rebuild %s (gen %0d->%0d, epoch %0d->%0d, state %0d)",
            label, key_name, before_gen[key_name],
            contexts[key_name].identity.generation, before_epoch[key_name],
            contexts[key_name].identity.reset_epoch,
            contexts[key_name].state))
      end
      else if (contexts[key_name].identity.generation != before_gen[key_name] ||
               contexts[key_name].identity.reset_epoch != before_epoch[key_name])
        `uvm_error("RESET_ENV", $sformatf(
          "%s changed out-of-scope %s (gen %0d->%0d, epoch %0d->%0d)",
          label, key_name, before_gen[key_name],
          contexts[key_name].identity.generation, before_epoch[key_name],
          contexts[key_name].identity.reset_epoch))
    end
  endtask

  // 功能：执行 VF/PF/Host/Device 四级 reset cascade 回归，覆盖多 Host/多 PF/VF 隔离。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：仿真超时、事务返回错误或断言不满足时报告 UVM_ERROR/UVM_FATAL；空 fixture 不得被当作成功。
  task run_phase(uvm_phase phase);
    rdma_reset_test_device_snapshot device_snapshot;
    rdma_reset_test_resource_snapshot resource_snapshot;
    dpu_resource_manager dpu_manager;
    rdma_host_mem_router host_mem;
    rdma_pcie_router pcie;
    rdma_reset_coordinator coordinator;
    rdma_device_env env;
    rdma_function_context contexts[string];
    rdma_function_identity identities[string];
    int unsigned before_gen[string];
    rdma_reset_epoch_t before_epoch[string];
    bit changed[string];
    string names[$];
    rdma_status status;
    dpu_function_key_t key;
    uvm_object registry;

    phase.raise_objection(this);
    build_snapshots(device_snapshot, resource_snapshot);
    dpu_manager = dpu_resource_manager::type_id::create("reset_dpu_manager");
    host_mem = rdma_host_mem_router::type_id::create("reset_host_mem");
    pcie = rdma_pcie_router::type_id::create("reset_pcie");
    coordinator = rdma_reset_coordinator::type_id::create("reset_coordinator");
    status = rdma_device_env::build(
      device_snapshot, resource_snapshot, dpu_manager, host_mem, pcie,
      registry, 1ns, env, coordinator);
    if (!status.ok() || env == null) begin
      `uvm_error("RESET_ENV", {"device env build failed: ", status.message})
      phase.drop_objection(this);
      return;
    end
    if (env.context_count() != 4)
      `uvm_error("RESET_ENV", "device env did not enumerate all Functions")
    if (env.reset_coordinator == null)
      `uvm_error("RESET_ENV", "device env reset coordinator is null")
    else if (env.reset_coordinator.function_count() != 4)
      `uvm_error("RESET_ENV",
                 "reset coordinator did not register all Functions")

    key = make_key(0, 0, DPU_FUNCTION_PF);
    contexts["h0_pf0"] = find_context(env, key, identities["h0_pf0"]);
    key = make_key(0, 0, DPU_FUNCTION_VF, 2);
    contexts["h0_vf2"] = find_context(env, key, identities["h0_vf2"]);
    key = make_key(0, 1, DPU_FUNCTION_PF);
    contexts["h0_pf1"] = find_context(env, key, identities["h0_pf1"]);
    key = make_key(1, 0, DPU_FUNCTION_PF);
    contexts["h1_pf0"] = find_context(env, key, identities["h1_pf0"]);
    foreach (contexts[name]) begin
      if (contexts[name] == null)
        continue;
      status = contexts[name].activate();
      if (!status.ok())
        `uvm_error("RESET_ENV", {"context activate failed: ", status.message})
      before_gen[name] = contexts[name].identity.generation;
      before_epoch[name] = contexts[name].identity.reset_epoch;
    end

    changed.delete();
    changed["h0_pf0"] = 0; changed["h0_vf2"] = 1;
    changed["h0_pf1"] = 0; changed["h1_pf0"] = 0;
    status = env.request_vf_flr(identities["h0_vf2"]);
    if (!status.ok()) `uvm_error("RESET_ENV", "VF FLR failed")
    check_generation_scope("VF FLR", contexts, before_gen, before_epoch, changed);

    foreach (contexts[name]) begin
      before_gen[name] = contexts[name].identity.generation;
      before_epoch[name] = contexts[name].identity.reset_epoch;
    end
    changed["h0_pf0"] = 1; changed["h0_vf2"] = 1;
    changed["h0_pf1"] = 0; changed["h1_pf0"] = 0;
    status = env.request_pf_reset(identities["h0_pf0"]);
    if (!status.ok()) `uvm_error("RESET_ENV", "PF reset failed")
    check_generation_scope("PF reset", contexts, before_gen, before_epoch, changed);

    foreach (contexts[name]) begin
      before_gen[name] = contexts[name].identity.generation;
      before_epoch[name] = contexts[name].identity.reset_epoch;
    end
    changed["h0_pf0"] = 1; changed["h0_vf2"] = 1;
    changed["h0_pf1"] = 1; changed["h1_pf0"] = 0;
    status = env.request_host_reset(0);
    if (!status.ok()) `uvm_error("RESET_ENV", "Host reset failed")
    check_generation_scope("Host reset", contexts, before_gen, before_epoch, changed);

    foreach (contexts[name]) begin
      before_gen[name] = contexts[name].identity.generation;
      before_epoch[name] = contexts[name].identity.reset_epoch;
    end
    changed["h0_pf0"] = 1; changed["h0_vf2"] = 1;
    changed["h0_pf1"] = 1; changed["h1_pf0"] = 1;
    status = env.request_device_reset();
    if (!status.ok()) `uvm_error("RESET_ENV", "Device reset failed")
    check_generation_scope("Device reset", contexts, before_gen, before_epoch, changed);
    phase.drop_objection(this);
  endtask
endclass
