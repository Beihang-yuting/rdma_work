// 目录：tests/unit/，位于 integration reset coordinator 的单元测试层。
// 职责：验证 Function、PF/VF、Host、Device 四类复位范围，以及注册 identity 克隆后
//       ledger 不受调用方可变对象影响。
// 依赖：rdma_reset_coordinator、rdma_function_identity、UVM；不连接真实 PCIe/Host memory。
// 所有权与生命周期：测试构造的 identity 由测试持有，coordinator 在 register_function()
//       内部克隆并管理自己的 ledger。

// 设计说明：该 probe 只暴露 coordinator 的受保护 Host-router 绑定，供失败原子性
// 断言确认 commit_registration_atomic 在 clone 失败时没有替换旧引用；它不改变生产
// coordinator 的接口，也不拥有 router 生命周期。
class rdma_reset_coordinator_probe extends rdma_reset_coordinator;
  `uvm_object_utils(rdma_reset_coordinator_probe)

  // 功能：构造 reset coordinator probe，沿用生产 coordinator 的空 ledger 和零 epoch 默认状态。
  // 输入/输出及副作用：name（输入）；调用基类构造，不创建或接管 Host router、identity 或 epoch 资源。
  // 失败/边界：probe 仅用于读取受保护绑定，不应替代生产 coordinator 执行复位流程。
  function new(string name = "rdma_reset_coordinator_probe");
    super.new(name);
  endfunction

  // 功能：比较 coordinator 当前保存的非拥有 Host-router 引用，验证注册事务失败时旧绑定仍在。
  // 输入/输出及副作用：expected（输入）；只读 m_host_router 并返回对象身份比较结果，不修改 ledger/epoch。
  // 失败/边界：expected 为 null 时仅在 coordinator 也未绑定 router 时返回真；函数不检查 router 内部配置。
  function bit has_host_router(rdma_host_mem_router expected);
    return m_host_router === expected;
  endfunction
endclass

// 设计说明：该 identity 子类在 clone() 边界注入一次 null，模拟 coordinator 批量
// registration 的中途 Function snapshot 工厂失败；故障只影响本地测试对象。
class rdma_reset_clone_fault_identity extends rdma_function_identity;
  `uvm_object_utils(rdma_reset_clone_fault_identity)

  bit fail_clone;

  // 功能：构造可开关 identity clone 故障的测试 fixture，并初始化 fail_clone=0。
  // 输入/输出及副作用：name（输入）；建立本地 identity 默认字段和故障开关，不申请外部资源。
  // 失败/边界：fixture 必须先 configure() 成有效 identity；fail_clone=1 时不得送入非故障路径。
  function new(string name = "rdma_reset_clone_fault_identity");
    super.new(name);
    fail_clone = 1'b0;
  endfunction

  // 功能：在 coordinator snapshot clone 边界返回 null 或委托基类深拷贝，覆盖批量提交的
  //       中途失败分支；源 identity 和任何 coordinator ledger 均不被修改。
  // 输入/输出及副作用：无显式输入；fail_clone=1 返回 null，否则返回标准 identity clone。
  // 失败/边界：null clone 必须被 commit_registration_atomic 转换为 RESOURCE_EXHAUSTED，且不得发布部分 ledger。
  virtual function uvm_object clone();
    if (fail_clone)
      return null;
    return super.clone();
  endfunction
endclass

class rdma_reset_coordinator_test extends uvm_test;
  `uvm_component_utils(rdma_reset_coordinator_test)

  // 功能：构造 UVM reset coordinator 测试组件；测试场景在 run_phase() 中执行。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：构造过程不分配 Host-memory、PCIe endpoint 或 manager 资源；空 name 也必须得到可配置对象。
  function new(string name = "rdma_reset_coordinator_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：构造一个具有指定 Host/root、PF/VF parent BDF、global ID 和 UID 的 identity
  //       夹具，统一生成 reset 范围测试所需的完整 authority。
  // 输入/输出及副作用：host_key（输入）、root_id（输入）、kind（输入）、vf_index（输入）、bdf_value（输入）、parent_bdf_value（输入）、uid（输入）；输入字段被复制到返回值或
  //   output；生成结果与输入隔离，不隐式修改调用方对象。
  // 失败/边界：输入为空、类型不匹配或字段组合非法时返回空值/错误；不得发布不完整快照。
  function automatic rdma_function_identity make_identity(
    int unsigned host_key,
    int unsigned root_id,
    rdma_function_kind_e kind,
    int unsigned vf_index,
    int unsigned bdf_value,
    int unsigned parent_bdf_value,
    longint unsigned uid
  );
    rdma_function_identity identity;
    rdma_function_key_t key;
    rdma_status status;

    key.root_id = root_id;
    key.host_topology_key = host_key;
    key.function_kind = kind;
    key.vf_index = vf_index;
    key.bdf = '{segment:root_id[15:0], bus:bdf_value[15:8],
                device:bdf_value[7:3], function_num:bdf_value[2:0]};
    if (kind == RDMA_FUNCTION_PF)
      key.parent_pf_bdf = '0;
    else
      key.parent_pf_bdf = '{segment:root_id[15:0], bus:parent_bdf_value[15:8],
                            device:parent_bdf_value[7:3],
                            function_num:parent_bdf_value[2:0]};
    identity = rdma_function_identity::type_id::create("identity");
    status = identity.configure(key, uid[31:0], uid, 1, 0);
    if (!status.ok())
      `uvm_fatal("RESET", {"identity fixture failed: ", status.message})
    return identity;
  endfunction

  // 功能：依次执行 VF FLR、PF reset、Host reset 和 Device reset，并断言每种操作只
  //       推进规范定义的 Function/Host epoch；随后验证批量 identity registration 的
  //       clone/validate 失败不会发布半成品 router 或 ledger。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：仿真超时、事务返回错误或断言不满足时报告 UVM_ERROR/UVM_FATAL；空 fixture 不得被当作成功。
  task run_phase(uvm_phase phase);
    rdma_reset_coordinator coordinator;
    rdma_function_identity pf0, vf0, pf1, mutated;
    rdma_reset_epoch_t pf0_epoch, vf0_epoch, pf1_epoch;
    uvm_object cloned_object;
    rdma_status status;
    rdma_reset_coordinator_probe atomic_probe;
    rdma_host_mem_router old_router;
    rdma_host_mem_router replacement_router;
    rdma_reset_clone_fault_identity clone_fault_identity;
    rdma_function_identity invalid_identity;
    rdma_function_identity unknown_vf;
    rdma_function_identity stale_pf;
    rdma_function_identity current_pf;
    rdma_function_identity stale_vf;
    rdma_function_identity staged_identities[$];
    rdma_function_identity invalid_staged_identities[$];

    phase.raise_objection(this);
    coordinator = rdma_reset_coordinator::type_id::create("coordinator");
    pf0 = make_identity(0, 0, RDMA_FUNCTION_PF, 0, 16'h0100, 0, 10);
    vf0 = make_identity(0, 0, RDMA_FUNCTION_VF, 1, 16'h0101, 16'h0100, 11);
    pf1 = make_identity(1, 1, RDMA_FUNCTION_PF, 0, 16'h0100, 0, 20);
    coordinator.register_function(pf0);
    coordinator.register_function(vf0);
    coordinator.register_function(pf1);
    // 显式 clone 后再篡改测试副本，避免把原始 PF identity 句柄改掉；这才
    // 能验证 coordinator 注册时保存的 ledger 与调用方对象生命周期隔离。
    cloned_object = pf0.clone();
    if (cloned_object == null || !$cast(mutated, cloned_object))
      `uvm_fatal("RESET", "identity mutation clone failed")
    mutated.key.bdf.bus = 8'h7f;
    // 注册时已经 clone，修改原对象不应改变 PF0 的 reset lookup。
    if (coordinator.function_epoch_uid(pf0.function_uid) != 0)
      `uvm_error("RESET", "new Function epoch was not zero")

    // reset request 的 authority preflight 必须先拒绝未知 Function；失败不得
    // 为 unknown UID 创建 phantom Function epoch 或扩大已有 ledger。
    unknown_vf = make_identity(0, 0, RDMA_FUNCTION_VF, 9,
                               16'h0190, 16'h0100, 99);
    status = coordinator.request_vf_flr(unknown_vf);
    if (status == null || status.ok() ||
        status.code != RDMA_SC_INVALID_STATE ||
        coordinator.function_epoch_uid(unknown_vf.function_uid) != 0 ||
        coordinator.function_count() != 3)
      `uvm_error("RESET_PREFLIGHT",
                 "unknown VF reset created phantom coordinator state")

    // 同一完整 key 但 generation 已漂移的 identity 也必须在 bump 前失败，
    // 以便调用方仍可安全重试当前 incarnation。
    cloned_object = pf0.clone();
    if (cloned_object == null || !$cast(stale_pf, cloned_object))
      `uvm_fatal("RESET", "stale PF identity clone failed")
    stale_pf.generation = pf0.generation + 1;
    status = coordinator.request_pf_reset(stale_pf);
    if (status == null || status.ok() ||
        status.code != RDMA_SC_STALE_GENERATION ||
        coordinator.function_epoch_uid(pf0.function_uid) != 0 ||
        coordinator.function_epoch_uid(vf0.function_uid) != 0)
      `uvm_error("RESET_PREFLIGHT",
                 "stale PF reset changed coordinator epochs")

    // 未登记 Host 不得触发 Host epoch 或 router 通知；Host0 的正常路径随后
    // 仍按既有 scope 语义推进。
    status = coordinator.request_host_reset(99);
    if (status == null || status.ok() ||
        status.code != RDMA_SC_INVALID_STATE ||
        coordinator.host_epoch(99) != 0 || coordinator.host_epoch(0) != 0)
      `uvm_error("RESET_PREFLIGHT",
                 "unknown Host reset created phantom host epoch")

    status = coordinator.request_vf_flr(vf0);
    if (!status.ok() || coordinator.function_epoch_uid(vf0.function_uid) != 1 ||
        coordinator.function_epoch_uid(pf0.function_uid) != 0)
      `uvm_error("RESET", "VF FLR affected the wrong Function")

    status = coordinator.request_pf_reset(pf0);
    if (!status.ok() || coordinator.function_epoch_uid(pf0.function_uid) != 1 ||
        coordinator.function_epoch_uid(vf0.function_uid) != 2 ||
        coordinator.function_epoch_uid(pf1.function_uid) != 0)
      `uvm_error("RESET", "PF reset did not affect PF and descendants only")

    status = coordinator.request_host_reset(0);
    if (!status.ok() || coordinator.host_epoch(0) != 1 ||
        coordinator.host_epoch(1) != 0 ||
        coordinator.function_epoch_uid(pf0.function_uid) != 2 ||
        coordinator.function_epoch_uid(vf0.function_uid) != 3 ||
        coordinator.function_epoch_uid(pf1.function_uid) != 0)
      `uvm_error("RESET", "Host reset scope is incorrect")

    status = coordinator.request_device_reset();
    if (!status.ok() || coordinator.device_epoch() != 1 ||
        coordinator.function_epoch_uid(pf0.function_uid) != 3 ||
        coordinator.function_epoch_uid(vf0.function_uid) != 4 ||
        coordinator.function_epoch_uid(pf1.function_uid) != 1)
      `uvm_error("RESET", "Device reset did not affect all Functions")

    pf0_epoch = coordinator.function_epoch_uid(pf0.function_uid);
    vf0_epoch = coordinator.function_epoch_uid(vf0.function_uid);
    pf1_epoch = coordinator.function_epoch_uid(pf1.function_uid);
    if (pf0_epoch == 0 || vf0_epoch == 0 || pf1_epoch == 0)
      `uvm_error("RESET", "reset ledger lost a registered Function")

    // coordinator 不替换 immutable registration snapshot；当前 incarnation
    // 由已发布 Function epoch 推导，合法的 generation/reset_epoch 更新应继续
    // 通过只读 preflight，而旧 incarnation 必须被识别为 stale。
    cloned_object = pf0.clone();
    if (cloned_object == null || !$cast(current_pf, cloned_object))
      `uvm_fatal("RESET", "current PF identity clone failed")
    current_pf.generation = pf0.generation + pf0_epoch;
    current_pf.reset_epoch = pf0.reset_epoch + pf0_epoch;
    status = coordinator.validate_registered_identity(current_pf);
    if (status == null || !status.ok())
      `uvm_error("RESET_PREFLIGHT",
                 "current PF incarnation was rejected after valid resets")
    cloned_object = pf0.clone();
    if (cloned_object == null || !$cast(stale_pf, cloned_object))
      `uvm_fatal("RESET", "post-reset stale PF identity clone failed")
    status = coordinator.validate_registered_identity(stale_pf);
    if (status == null || status.code != RDMA_SC_STALE_GENERATION)
      `uvm_error("RESET_PREFLIGHT",
                 "old PF incarnation was not rejected after reset")

    // 批量 registration 必须先完成全部 identity clone，再替换 Host-router/ledger。
    // 第二个 identity 故意在 clone 边界返回 null，失败后旧 router 和空 ledger 均应保持。
    atomic_probe = rdma_reset_coordinator_probe::type_id::create(
      "atomic_registration_probe");
    old_router = rdma_host_mem_router::type_id::create(
      "atomic_registration_old_router");
    replacement_router = rdma_host_mem_router::type_id::create(
      "atomic_registration_replacement_router");
    clone_fault_identity = new("atomic_registration_clone_fault");
    status = clone_fault_identity.configure(
      pf1.key, pf1.global_function_id, pf1.function_uid + 100, 1, 0);
    if (status == null || !status.ok())
      `uvm_fatal("RESET", "clone-fault identity fixture failed")
    clone_fault_identity.fail_clone = 1'b1;
    atomic_probe.attach_host_router(old_router);
    staged_identities.push_back(pf0);
    staged_identities.push_back(clone_fault_identity);
    status = atomic_probe.commit_registration_atomic(
      replacement_router, staged_identities);
    if (status == null || status.code != RDMA_SC_RESOURCE_EXHAUSTED ||
        atomic_probe.function_count() != 0 ||
        !atomic_probe.has_host_router(old_router))
      `uvm_error("RESET_ATOMIC", "failed registration published partial state")

    // identity validate 失败也必须发生在 commit 前；故意传入未 configure 的空 identity，
    // 观察到的错误不得替换旧 router 或创建单独的 Function snapshot。
    invalid_identity = new("atomic_registration_invalid_identity");
    invalid_staged_identities.push_back(pf0);
    invalid_staged_identities.push_back(invalid_identity);
    status = atomic_probe.commit_registration_atomic(
      replacement_router, invalid_staged_identities);
    if (status == null || status.ok() ||
        atomic_probe.function_count() != 0 ||
        !atomic_probe.has_host_router(old_router))
      `uvm_error("RESET_ATOMIC", "invalid identity changed registration state")

    // 清除故障后重试同一批次，成功才允许一次性替换 router 并发布两个 snapshot。
    clone_fault_identity.fail_clone = 1'b0;
    status = atomic_probe.commit_registration_atomic(
      replacement_router, staged_identities);
    if (status == null || !status.ok() ||
        atomic_probe.function_count() != 2 ||
        !atomic_probe.has_host_router(replacement_router))
      `uvm_error("RESET_ATOMIC", "successful registration did not publish atomically")
    phase.drop_objection(this);
  endtask
endclass

// 设计说明：该 focused test 构造同一 Host、同一完整 BDF、不同 root_id 的 malformed
//       topology，验证 PF reset 的 coordinator scope 不会把两个 PCIe root 串联；它只
//       使用 coordinator-owned identity ledger，不接入真实 Host-memory/PCIe 组件。
class rdma_reset_coordinator_pf_root_scope_test extends rdma_reset_coordinator_test;
  `uvm_component_utils(rdma_reset_coordinator_pf_root_scope_test)

  // 功能：构造 PF root scope focused test 组件，复用基类 identity fixture helper。
  // 输入/输出及副作用：name、parent（输入）；调用基类构造，不创建 coordinator、identity
  //   或外部 router 资源；返回新建 UVM component。
  // 失败/边界：构造阶段不执行 reset；所有 malformed topology 注入和断言都在 run_phase() 中完成。
  function new(string name = "rdma_reset_coordinator_pf_root_scope_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：验证同 Host/同 BDF 但不同 root_id 的 PF/VF 集合彼此隔离，root0 PF reset
  //       只递增 root0 的 PF/VF epoch，随后 root1 reset 才递增 root1 集合。
  // 输入/输出及副作用：phase（输入）；task 构造并登记四份 identity、调用 PF scope
  //   count/reset API 并通过 UVM report 暴露结果，不修改外部依赖所有权。
  // 失败/边界：identity 配置、scope count、reset status 或任一 Function epoch 不符合
  //   Host+root+BDF 契约时报告 UVM_ERROR；root1 BDF segment 被显式改成 root0 以模拟 malformed
  //   topology，route validator 仍必须接受该独立 root 值。
  task run_phase(uvm_phase phase);
    rdma_reset_coordinator coordinator;
    rdma_function_identity pf_root0;
    rdma_function_identity vf_root0;
    rdma_function_identity pf_root1;
    rdma_function_identity vf_root1;
    rdma_status status;

    phase.raise_objection(this);
    coordinator = rdma_reset_coordinator::type_id::create(
      "pf_root_scope_coordinator");
    pf_root0 = make_identity(
      32'h42, 0, RDMA_FUNCTION_PF, 0, 16'h1200, 0,
      64'h0000_0000_0000_1200);
    vf_root0 = make_identity(
      32'h42, 0, RDMA_FUNCTION_VF, 1, 16'h1201, 16'h1200,
      64'h0000_0000_0000_1201);
    pf_root1 = make_identity(
      32'h42, 1, RDMA_FUNCTION_PF, 0, 16'h1200, 0,
      64'h0000_0000_0000_2200);
    vf_root1 = make_identity(
      32'h42, 1, RDMA_FUNCTION_VF, 1, 16'h1201, 16'h1200,
      64'h0000_0000_0000_2201);

    // make_identity 默认把 BDF segment 投影为 root_id；把 root1 的 segment 和
    // parent segment 改回 root0，形成“完整 BDF 相同、root_id 不同”的恶意拓扑。
    pf_root1.key.bdf.segment = pf_root0.key.bdf.segment;
    vf_root1.key.bdf.segment = vf_root0.key.bdf.segment;
    vf_root1.key.parent_pf_bdf.segment = vf_root0.key.parent_pf_bdf.segment;
    if (pf_root1.validate() == null || !pf_root1.validate().ok() ||
        vf_root1.validate() == null || !vf_root1.validate().ok()) begin
      `uvm_error("RESET_ROOT_SCOPE", "malformed root fixture failed route validation")
      phase.drop_objection(this);
      return;
    end

    coordinator.register_function(pf_root0);
    coordinator.register_function(vf_root0);
    coordinator.register_function(pf_root1);
    coordinator.register_function(vf_root1);
    if (coordinator.function_count() != 4 ||
        coordinator.pf_reset_function_count(pf_root0) != 2 ||
        coordinator.pf_reset_function_count(pf_root1) != 2)
      `uvm_error("RESET_ROOT_SCOPE",
                 "PF scope count merged same-BDF Functions across roots")

    status = coordinator.request_pf_reset(pf_root0);
    if (status == null || !status.ok() ||
        coordinator.function_epoch_uid(pf_root0.function_uid) != 1 ||
        coordinator.function_epoch_uid(vf_root0.function_uid) != 1 ||
        coordinator.function_epoch_uid(pf_root1.function_uid) != 0 ||
        coordinator.function_epoch_uid(vf_root1.function_uid) != 0)
      `uvm_error("RESET_ROOT_SCOPE",
                 "root0 PF reset crossed into root1 same-BDF Functions")

    status = coordinator.request_pf_reset(pf_root1);
    if (status == null || !status.ok() ||
        coordinator.function_epoch_uid(pf_root0.function_uid) != 1 ||
        coordinator.function_epoch_uid(vf_root0.function_uid) != 1 ||
        coordinator.function_epoch_uid(pf_root1.function_uid) != 1 ||
        coordinator.function_epoch_uid(vf_root1.function_uid) != 1)
      `uvm_error("RESET_ROOT_SCOPE",
                 "root1 PF reset did not isolate its same-BDF scope")
    phase.drop_objection(this);
  endtask
endclass
