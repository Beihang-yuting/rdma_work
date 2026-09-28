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

  // 功能：向测试专用 coordinator ledger 注入一个与已有条目重复的 Function UID，构造
  //       function_epoch_uid() 的损坏账本边界，不改变生产注册入口的唯一性校验。
  // 输入/输出及副作用：source（输入）被 clone 到 injected_key（输入）对应的受保护 map，并同步
  //   初始化 registration/epoch baseline；函数无返回值，不修改 source、router 或外部资源。
  // 失败/边界：source 为空或 clone/cast 失败时忽略注入；injected_key 只应使用测试私有键，调用方必须
  //   在断言后调用 remove_injected_function() 清理三张 map，避免污染后续测试场景。
  function void inject_duplicate_uid(
    rdma_function_identity source,
    string injected_key
  );
    uvm_object cloned_object;
    rdma_function_identity copy;

    if (source == null)
      return;
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(copy, cloned_object))
      return;
    m_functions[injected_key] = copy;
    m_function_registration_epochs[injected_key] = 0;
    m_function_epochs[injected_key] = 0;
  endfunction

  // 功能：删除 inject_duplicate_uid() 写入的测试 injected_key，恢复 coordinator 三张 Function
  //       ledger map 的原始值图，供同一 focused test 后续继续使用。
  // 输入/输出及副作用：injected_key（输入）从 m_functions、registration baseline 和 absolute epoch
  //   map 中删除；函数无返回值，不触碰其它 Function 或 Host-router 绑定。
  // 失败/边界：injected_key 不存在时 delete 保持幂等；调用方不得把该 helper 当作生产 unregister API。
  function void remove_injected_function(string injected_key);
    m_functions.delete(injected_key);
    m_function_registration_epochs.delete(injected_key);
    m_function_epochs.delete(injected_key);
  endfunction

  // 功能：为 epoch 溢出 focused test 注入一个已登记 Function 的 absolute counter，
  //       只暴露受保护 ledger 的测试 seam，不改变生产 reset API。
  // 输入/输出及副作用：identity（输入）用于解析 stable key；epoch（输入）写入
  //   m_function_epochs；函数无返回值，不克隆或修改 identity/Host router。
  // 失败/边界：identity 为 null 或未登记时忽略写入；调用方必须先完成 registration，
  //   该 seam 仅用于构造最大值/不一致 ledger 故障，不能作为业务路径的 epoch 更新入口。
  function void force_function_absolute_epoch(
    rdma_function_identity identity,
    rdma_reset_epoch_t epoch
  );
    string key;

    if (identity == null)
      return;
    key = identity_name(identity);
    if (m_functions.exists(key))
      m_function_epochs[key] = epoch;
  endfunction

  // 功能：为 Host epoch 溢出 focused test 预置 coordinator 的 Host counter，验证
  //       request_host_reset() 在 router 通知前 fail-closed。
  // 输入/输出及副作用：host_key/epoch（输入）写入 m_host_epochs；不修改 Function ledger
  //   或外部 router，函数无返回值。
  // 失败/边界：所有数值均可注入；调用方须确保 Host 已登记，否则 request_host_reset()
  //   会先因 scope 缺失拒绝，无法观察 epoch exhaustion 分支。
  function void force_host_absolute_epoch(
    int unsigned host_key,
    rdma_reset_epoch_t epoch
  );
    m_host_epochs[host_key] = epoch;
  endfunction

  // 功能：为 Device epoch 溢出 focused test 预置全局 counter，验证 device reset 不会
  //       在最大值处回绕或递增 Function ledger。
  // 输入/输出及副作用：epoch（输入）写入 m_device_epoch；不修改 Function 或 Host ledger。
  // 失败/边界：该 seam 只应在测试对象完成 registration 后调用，生产代码没有对应写入口。
  function void force_device_absolute_epoch(rdma_reset_epoch_t epoch);
    m_device_epoch = epoch;
  endfunction

  // 功能：在测试专用 probe 中模拟 identity/router callback 已经进入 coordinator reset
  //       publication wrapper，构造同一调用栈的嵌套 request_* 入口。
  // 输入/输出及副作用：active（输入）只写受保护 m_reset_operation_active；不修改 Function、
  //   Host、Device epoch 或 router 引用，调用方负责在断言后恢复为 0。
  // 失败/边界：该 seam 仅用于验证同步 guard；生产代码不得依赖它伪造 reset 事务或绕过 lease。
  function void force_reset_operation_active(bit active);
    m_reset_operation_active = active;
  endfunction
endclass

// 设计说明：该 router probe 只暴露一个已配置 Host route 的 local epoch 值图，构造
//       router-local overflow fixture；它不拥有 Host manager，也不改变生产路由接口。
class rdma_reset_host_router_probe extends rdma_host_mem_router;
  `uvm_object_utils(rdma_reset_host_router_probe)

  // 功能：构造空 Host router probe，沿用生产 router 的 local epoch ledger 和 null coordinator。
  // 输入/输出及副作用：name（输入）；调用基类构造，不创建 manager、mapping 或外部 Host 资源。
  // 失败/边界：probe 只用于向 reset coordinator 注入 local epoch 边界，未 seed_host_epoch() 前
  //   不代表存在可用于业务 DMA 的完整 route。
  function new(string name = "rdma_reset_host_router_probe");
    super.new(name);
  endfunction

  // 功能：为 focused reset 测试建立一个指定 Host 的 local epoch fixture，模拟 router 已发布
  //       route 后的内部计数，而不伪造 manager allocation 或 mapping ownership。
  // 输入/输出及副作用：host_key/epoch（输入）写入 router-owned m_epochs；函数无返回值，不修改
  //   coordinator、manager 或 mapping ledger。
  // 失败/边界：该 seam 仅用于构造最大值/回绕故障；生产路径必须通过 configure() 创建 m_epochs。
  function void seed_host_epoch(
    int unsigned host_key,
    rdma_reset_epoch_t epoch
  );
    m_epochs[host_key] = epoch;
  endfunction

  // 功能：读取 probe 注入的 router-local Host epoch，验证拒绝路径没有发生隐式回绕或推进。
  // 输入/输出及副作用：host_key（输入）；只读返回 m_epochs 值，未 seed 的 Host 返回零，不修改
  //   route、mapping 或 coordinator。
  // 失败/边界：返回零既可能是合法初始值也可能表示未 seed；调用方应先确保 fixture 已建立。
  function rdma_reset_epoch_t local_host_epoch(int unsigned host_key);
    return m_epochs.exists(host_key) ? m_epochs[host_key] : 0;
  endfunction

  // 功能：比较 router 当前保存的 coordinator 非拥有引用，验证错误 owner/token 或
  //       active mapping 下的 attach/rebind 失败不会替换旧 authority。
  // 输入/输出及副作用：expected（输入）用于对象身份比较；函数只读 m_reset，返回 bit，
  //       不修改 route、mapping 或 epoch ledger。
  // 失败/边界：expected 为 null 时仅在 router 当前未绑定 coordinator 时返回真；该 probe
  //       不检查 coordinator 内部 lease 是否仍有效，生命周期断言由调用方单独完成。
  function bit has_reset_coordinator(rdma_reset_coordinator expected);
    return m_reset === expected;
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
    rdma_reset_coordinator foreign_coordinator;
    rdma_reset_coordinator_probe foreign_owner;
    rdma_reset_host_router_probe blocked_router;
    rdma_reset_clone_fault_identity clone_fault_identity;
    rdma_function_identity invalid_identity;
    rdma_function_identity unknown_vf;
    rdma_function_identity stale_pf;
    rdma_function_identity current_pf;
    rdma_function_identity stale_vf;
    rdma_function_identity staged_identities[$];
    rdma_function_identity invalid_staged_identities[$];
    rdma_function_handle authority_handle;
    rdma_route_key_t authority_route;
    rdma_reset_epoch_t authority_epoch;
    rdma_reset_epoch_t source_epochs[string];
    rdma_reset_epoch_candidate epoch_candidate;
    rdma_status foreign_status;
    longint unsigned foreign_token;

    phase.raise_objection(this);
    source_epochs.delete();
    source_epochs["pf0"] = 64'd3;
    source_epochs["vf0"] = 64'd7;
    epoch_candidate = rdma_reset_epoch_candidate::type_id::create(
      "epoch_candidate_fixture"
    );
    status = epoch_candidate.capture_function_epochs(source_epochs);
    if (status == null || !status.ok() ||
        epoch_candidate.function_epochs["pf0"] != 64'd3 ||
        epoch_candidate.function_epochs["vf0"] != 64'd7)
      `uvm_error("RESET_CANDIDATE", "epoch candidate capture failed")
    source_epochs["pf0"] = 64'd99;
    if (epoch_candidate.function_epochs["pf0"] != 64'd3)
      `uvm_error("RESET_CANDIDATE", "epoch candidate aliases source map")
    status = epoch_candidate.validate();
    if (status == null || !status.ok())
      `uvm_error("RESET_CANDIDATE", "valid reset snapshot was rejected")
    epoch_candidate.clear();
    if (epoch_candidate.function_epochs.size() != 0 || epoch_candidate.valid)
      `uvm_error("RESET_CANDIDATE", "epoch candidate clear left staged state")
    status = epoch_candidate.validate();
    if (status == null || status.ok() || status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("RESET_CANDIDATE", "cleared reset candidate was accepted")

    coordinator = rdma_reset_coordinator::type_id::create("coordinator");

    // Batch185 detached admission policy matrix：先验证 tokenless 数据面在 publication、
    // transaction 和 cleanup 组合下的纯值结果，再由 coordinator/router 场景证明 wrapper
    // 仍沿用同一判定。policy 不持有 coordinator 状态，不会把同步 guard 误报成全局锁。
    status = rdma_reset_tokenless_admission_policy::evaluate(
      1'b0, 1'b0, 1'b0, "idle read"
    );
    if (status == null || !status.ok())
      `uvm_error("RESET_ADMISSION_POLICY", "idle dataplane was rejected")
    status = rdma_reset_tokenless_admission_policy::evaluate(
      1'b1, 1'b0, 1'b0, "publication write"
    );
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY)
      `uvm_error("RESET_ADMISSION_POLICY",
                 "publication-active dataplane was not rejected")
    status = rdma_reset_tokenless_admission_policy::evaluate(
      1'b0, 1'b1, 1'b0, "transaction allocate"
    );
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY)
      `uvm_error("RESET_ADMISSION_POLICY",
                 "transaction-active dataplane was not rejected")
    status = rdma_reset_tokenless_admission_policy::evaluate(
      1'b1, 1'b1, 1'b0, "nested reset read"
    );
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY)
      `uvm_error("RESET_ADMISSION_POLICY",
                 "combined reset-active dataplane was not rejected")
    status = rdma_reset_tokenless_admission_policy::evaluate(
      1'b1, 1'b1, 1'b1, "rollback release"
    );
    if (status == null || !status.ok())
      `uvm_error("RESET_ADMISSION_POLICY",
                 "cleanup dataplane was blocked during reset")

    pf0 = make_identity(0, 0, RDMA_FUNCTION_PF, 0, 16'h0100, 0, 10);
    vf0 = make_identity(0, 0, RDMA_FUNCTION_VF, 1, 16'h0101, 16'h0100, 11);
    pf1 = make_identity(1, 1, RDMA_FUNCTION_PF, 0, 16'h0100, 0, 20);
    coordinator.register_function(pf0);
    coordinator.register_function(vf0);
    coordinator.register_function(pf1);
    // Handle validation must distinguish a registered initial epoch=0 from an
    // unknown UID, before any router or manager can observe the request.
    authority_handle = rdma_function_handle::type_id::create(
      "registered_authority_handle"
    );
    authority_handle.function_uid = pf0.function_uid;
    authority_handle.object_id = pf0.global_function_id;
    authority_handle.generation = pf0.generation;
    authority_route = pf0.route_key();
    status = coordinator.validate_registered_function_handle(
      authority_handle, authority_route, authority_epoch
    );
    if (status == null || !status.ok() || authority_epoch != 0)
      `uvm_error("RESET_AUTHORITY", "registered epoch-zero handle was rejected")
    authority_handle.function_uid = 64'hffff_0000_0000_0001;
    status = coordinator.validate_registered_function_handle(
      authority_handle, authority_route, authority_epoch
    );
    if (status == null || status.ok() ||
        status.code != RDMA_SC_INVALID_STATE || authority_epoch != 0)
      `uvm_error("RESET_AUTHORITY", "unknown Function UID was accepted")
    authority_handle.function_uid = pf0.function_uid;
    authority_handle.generation++;
    status = coordinator.validate_registered_function_handle(
      authority_handle, authority_route, authority_epoch
    );
    if (status == null || status.code != RDMA_SC_STALE_GENERATION)
      `uvm_error("RESET_AUTHORITY", "stale Function generation was accepted")
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

    // legacy attach/registration 必须观察 router 的拒绝结果：foreign coordinator 已被
    // lease claim 时，void wrapper 不能把 coordinator 的 m_host_router 偷换成仍绑定于
    // foreign ledger 的 router；失败也不能发布任何 Function snapshot。
    foreign_coordinator = rdma_reset_coordinator::type_id::create(
      "atomic_registration_foreign_coordinator");
    foreign_owner = rdma_reset_coordinator_probe::type_id::create(
      "atomic_registration_foreign_owner");
    blocked_router = rdma_reset_host_router_probe::type_id::create(
      "atomic_registration_blocked_router");
    foreign_token = 0;
    foreign_status = foreign_coordinator.acquire_lease(
      foreign_owner, foreign_token
    );
    if (foreign_status == null || !foreign_status.ok() || foreign_token == 0)
      `uvm_fatal("RESET_ATOMIC", "foreign coordinator lease fixture failed")
    // Batch110：即使 owner/token 正确，直接驱动 router owned seam 也缺少 coordinator
    // 暂存的一次性 capability，必须拒绝且不能形成 router 单侧绑定；合法路径改由
    // coordinator facade 发起 bilateral attach。
    foreign_status = blocked_router.attach_reset_coordinator_owned(
      foreign_coordinator, foreign_owner, foreign_token
    );
    if (foreign_status == null || foreign_status.code != RDMA_SC_RESOURCE_BUSY)
      `uvm_error("RESET_ATOMIC",
                 "direct router owned attach bypassed coordinator capability")
    if (foreign_coordinator.host_router_bound() ||
        blocked_router.has_reset_coordinator(foreign_coordinator))
      `uvm_error("RESET_ATOMIC",
                 "rejected direct router attach left unilateral binding")
    foreign_status = foreign_coordinator.attach_host_router_owned(
      blocked_router, foreign_owner, foreign_token
    );
    if (foreign_status == null || !foreign_status.ok())
      `uvm_fatal("RESET_ATOMIC", "foreign router attach fixture failed")
    atomic_probe.attach_host_router(blocked_router);
    if (!atomic_probe.has_host_router(old_router))
      `uvm_error("RESET_ATOMIC", "void attach replaced router after rejection")
    staged_identities.delete();
    staged_identities.push_back(pf0);
    status = atomic_probe.commit_registration_atomic(
      blocked_router, staged_identities
    );
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY ||
        atomic_probe.function_count() != 0 ||
        !atomic_probe.has_host_router(old_router))
      `uvm_error("RESET_ATOMIC", "foreign router rejection published partial state")
    foreign_status = foreign_coordinator.detach_host_router_owned(
      blocked_router, foreign_owner, foreign_token
    );
    if (foreign_status == null || !foreign_status.ok())
      `uvm_fatal("RESET_ATOMIC", "foreign router detach fixture failed")
    foreign_status = foreign_coordinator.release_lease(
      foreign_owner, foreign_token
    );
    if (foreign_status == null || !foreign_status.ok())
      `uvm_fatal("RESET_ATOMIC", "foreign coordinator lease release failed")

    staged_identities.delete();
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

    // 清除故障后先验证跨 router replacement 仍被严格一对一契约拒绝；旧 router
    // 的反向绑定尚未通过 bilateral detach 清除，不能让 registration transaction
    // 单侧替换它，即使本批次的 identity clone 已经全部成功。
    clone_fault_identity.fail_clone = 1'b0;
    status = atomic_probe.commit_registration_atomic(
      replacement_router, staged_identities);
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY ||
        atomic_probe.function_count() != 0 ||
        !atomic_probe.has_host_router(old_router))
      `uvm_error("RESET_ATOMIC", "cross-router replacement bypassed bilateral detach")

    // 保持旧 router 绑定不变时重试同一批次，才允许一次性发布两个 snapshot；
    // 该正路径同时证明前面的 clone/validate 失败没有污染 staged ledger。
    status = atomic_probe.commit_registration_atomic(
      old_router, staged_identities);
    if (status == null || !status.ok() ||
        atomic_probe.function_count() != 2 ||
        !atomic_probe.has_host_router(old_router))
      `uvm_error("RESET_ATOMIC", "successful registration did not publish atomically")

    // function_epoch_uid() 不能在损坏 ledger 中静默选择第一个同 UID 条目；重复 UID
    // 是 dpu_common authority 破坏，应返回零并让调用方进入诊断/隔离路径。
    atomic_probe.inject_duplicate_uid(pf0, "test_duplicate_uid_alias");
    if (atomic_probe.function_epoch_uid(pf0.function_uid) != 0)
      `uvm_error("RESET_AUTHORITY", "duplicate Function UID was not fail-closed")
    atomic_probe.remove_injected_function("test_duplicate_uid_alias");
    if (atomic_probe.function_epoch_uid(pf0.function_uid) != 0)
      `uvm_error("RESET_AUTHORITY", "duplicate UID cleanup changed valid epoch lookup")
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

// 设计说明：该 probe 只暴露 device env 的 reset-in-progress seam，验证同步重入请求在
//       public request_* 入口返回 RESOURCE_BUSY；它不构造 Function context，也不拥有
//       coordinator/router 生命周期。
class rdma_device_env_busy_probe extends rdma_device_env;
  `uvm_object_utils(rdma_device_env_busy_probe)

  // 功能：构造空 device-env probe，沿用生产 env 的零值依赖和 reset guard。
  // 输入/输出及副作用：name（输入）；调用基类构造，不分配 snapshot、router 或 ledger。
  // 失败/边界：probe 只用于测试 guard 分支，未调用 arm_busy() 前不代表可执行 reset。
  function new(string name = "rdma_device_env_busy_probe");
    super.new(name);
  endfunction

  // 功能：注入一个有效 coordinator 并置位 reset-in-progress，模拟 virtual callback 内的同步重入。
  // 输入/输出及副作用：coordinator（输入）保存为非拥有引用；只写测试 probe 的 guard，不修改
  //   coordinator ledger 或外部 router 所有权。
  // 失败/边界：coordinator 为 null 时 public request_device_reset() 会先返回 INVALID_STATE，
  //   调用方须传入新建 coordinator 才能观察 RESOURCE_BUSY 分支。
  function void arm_busy(rdma_reset_coordinator coordinator);
    reset_coordinator = coordinator;
    m_reset_in_progress = 1'b1;
  endfunction

  // 功能：清除 probe 的 reset-in-progress 标志，模拟外层 reset 返回后的 guard release。
  // 输入/输出及副作用：无输入；只写 m_reset_in_progress，不改变 coordinator、context 或 router。
  // 失败/边界：重复清除幂等；清除后空 scope 仍会因正常 preflight 返回 INVALID_STATE，而非伪造成功。
  function void clear_busy();
    m_reset_in_progress = 1'b0;
  endfunction

endclass

// 设计说明：该 focused test 覆盖 coordinator registration baseline、重登记单调性、全局
// Function ID/UID 唯一性以及各类 epoch 溢出边界。测试只通过 probe 注入 counter 故障，
// 不接管 Host router 或 dpu_common identity 的生命周期。
class rdma_reset_coordinator_lifecycle_test extends rdma_reset_coordinator_test;
  `uvm_component_utils(rdma_reset_coordinator_lifecycle_test)

  // 功能：构造 coordinator lifecycle focused test 组件，复用基类 identity fixture helper。
  // 输入/输出及副作用：name、parent（输入）；调用基类构造，不创建 coordinator、router 或
  // identity 资源；返回新建 UVM component。
  // 失败/边界：构造阶段不执行 registration/reset；所有 counter 注入和断言均在 run_phase() 完成。
  function new(string name = "rdma_reset_coordinator_lifecycle_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：验证 registration baseline 被纳入 preview/validate，当前 incarnation 可安全刷新
  //   baseline，旧代际、重复 key、UID/global-ID 冲突以及 Function/Host/Device overflow 均在
  //   任何 epoch side effect 前拒绝。
  // 输入/输出及副作用：phase（输入）；task 创建 probe/identity 值图、注入受保护 counter、
  //   调用 coordinator API 并通过 UVM_ERROR 暴露契约违例；只修改本测试对象的 ledger。
  // 失败/边界：clone/configure/registration 返回 null 或错误时报告 UVM_ERROR；所有拒绝路径
  //   还必须断言 function_count、相关 epoch 和另一 scope 的 Function 不发生变化。
  task run_phase(uvm_phase phase);
    localparam rdma_reset_epoch_t EPOCH_MAX = 64'hffff_ffff_ffff_ffff;
    localparam int unsigned GENERATION_MAX = 32'hffff_ffff;
    rdma_reset_coordinator_probe probe;
    rdma_reset_coordinator_probe overflow_probe;
    rdma_reset_coordinator_probe scope_probe;
    rdma_device_env_busy_probe busy_env;
    rdma_reset_coordinator_probe busy_coordinator;
    rdma_reset_host_router_probe host_router_probe;
    rdma_reset_coordinator lease_probe;
    rdma_device_env_busy_probe lease_owner_a;
    rdma_device_env_busy_probe lease_owner_b;
    rdma_reset_host_router_probe lease_router;
    rdma_reset_coordinator legacy_attach_probe;
    rdma_reset_coordinator_probe legacy_attach_owner;
    rdma_host_mem_router legacy_attach_router;
    rdma_function_context leased_context;
    rdma_function_identity leased_context_identity;
    rdma_function_binding leased_context_binding;
    rdma_function_identity context_identity_before_reset;
    rdma_function_identity baseline;
    rdma_function_identity current;
    rdma_function_identity stale;
    rdma_function_identity jumped;
    rdma_function_identity duplicate_a;
    rdma_function_identity duplicate_b;
    rdma_function_identity reused_uid;
    rdma_function_identity reused_global_id;
    rdma_function_identity max_identity;
    rdma_function_identity scope_pf;
    rdma_function_identity scope_vf;
    rdma_function_identity clone_identity;
    rdma_reset_coordinator_probe mutation_probe;
    rdma_reset_coordinator_probe mutation_owner;
    rdma_reset_host_router_probe mutation_router;
    rdma_host_mem_router mutation_replacement_router;
    rdma_function_identity mutation_identity;
    rdma_function_identity mutation_identity_extra;
    rdma_function_identity mutation_staged[$];
    rdma_host_mem_route_entry mutation_entries[$];
    rdma_reset_coordinator_probe transaction_probe;
    rdma_device_env_busy_probe transaction_owner;
    rdma_reset_host_router_probe transaction_router;
    rdma_function_identity staged[$];
    rdma_status status;
    longint unsigned lease_token;
    longint unsigned competing_token;
    longint unsigned legacy_attach_token;
    longint unsigned transaction_token;
    rdma_reset_epoch_t next_epoch;
    rdma_reset_epoch_t before_pf_epoch;
    rdma_reset_epoch_t before_vf_epoch;
    uvm_object cloned_object;

    phase.raise_objection(this);

    // 非零 registration baseline：preview 必须返回 baseline+1，而不是 raw absolute+1。
    probe = rdma_reset_coordinator_probe::type_id::create(
      "lifecycle_registration_probe");
    baseline = make_identity(
      32'h10, 0, RDMA_FUNCTION_PF, 0, 16'h2100, 0, 64'h2100);
    baseline.generation = 7;
    baseline.reset_epoch = 9;
    staged.push_back(baseline);
    status = probe.commit_registration_atomic(null, staged);
    if (status == null || !status.ok() || probe.function_count() != 1)
      `uvm_error("RESET_LIFECYCLE", "nonzero baseline registration failed")
    status = probe.preview_next_function_epoch(baseline, next_epoch);
    if (status == null || !status.ok() || next_epoch != 10)
      `uvm_error("RESET_LIFECYCLE", "preview ignored registration reset baseline")

    status = probe.request_pf_reset(baseline);
    if (status == null || !status.ok() ||
        probe.function_epoch_uid(baseline.function_uid) != 10)
      `uvm_error("RESET_LIFECYCLE", "baseline PF reset did not publish effective epoch")

    // reset 后旧 registration snapshot 仍可能与 coordinator-owned snapshot 完全相同，
    // 但它已经落后于由 absolute counter 推导出的 current incarnation；该输入不得再走
    // 幂等快路径，否则会把 stale context 重新发布成旧 baseline。
    staged.delete();
    staged.push_back(baseline);
    status = probe.commit_registration_atomic(null, staged);
    if (status == null || status.code != RDMA_SC_STALE_GENERATION ||
        probe.function_epoch_uid(baseline.function_uid) != 10)
      `uvm_error("RESET_LIFECYCLE",
                 "post-reset old registration snapshot was accepted")

    cloned_object = baseline.clone();
    if (cloned_object == null || !$cast(current, cloned_object)) begin
      `uvm_error("RESET_LIFECYCLE", "current incarnation clone failed")
    end
    else begin
      current.generation = 8;
      current.reset_epoch = 10;
      status = probe.validate_registered_identity(current);
      if (status == null || !status.ok())
        `uvm_error("RESET_LIFECYCLE", "derived current incarnation was rejected")

      // 允许把已发布的 current incarnation 重新登记并刷新 baseline，避免旧 snapshot
      // 永久残留；严格小于 current 的回退仍必须拒绝。
      staged.delete();
      staged.push_back(current);
      status = probe.commit_registration_atomic(null, staged);
      if (status == null || !status.ok() ||
          probe.function_epoch_uid(current.function_uid) != 10)
        `uvm_error("RESET_LIFECYCLE", "current incarnation baseline refresh failed")

      // registration 不能把尚未由 coordinator 发布的未来代际直接跳过；只有
      // 当前 derived incarnation 可刷新 baseline，向前跳跃也必须保持旧 ledger。
      cloned_object = current.clone();
      if (cloned_object == null || !$cast(jumped, cloned_object)) begin
        `uvm_error("RESET_LIFECYCLE", "future incarnation clone failed")
      end
      else begin
        jumped.generation = current.generation + 1;
        jumped.reset_epoch = current.reset_epoch + 1;
        staged.delete();
        staged.push_back(jumped);
        status = probe.commit_registration_atomic(null, staged);
        if (status == null || status.code != RDMA_SC_STALE_GENERATION ||
            probe.function_epoch_uid(current.function_uid) != 10)
          `uvm_error("RESET_LIFECYCLE", "future incarnation jump was accepted")
      end

      cloned_object = current.clone();
      if (cloned_object == null || !$cast(stale, cloned_object)) begin
        `uvm_error("RESET_LIFECYCLE", "stale incarnation clone failed")
      end
      else begin
        stale.generation = 7;
        stale.reset_epoch = 9;
        staged.delete();
        staged.push_back(stale);
        status = probe.commit_registration_atomic(null, staged);
        if (status == null || status.code != RDMA_SC_STALE_GENERATION ||
            probe.function_epoch_uid(current.function_uid) != 10)
          `uvm_error("RESET_LIFECYCLE", "registration rollback was accepted")
      end
    end

    // 同一批次重复 stable key、跨 route 重用 UID 或 global ID 均必须在 commit 前拒绝。
    duplicate_a = make_identity(
      32'h11, 0, RDMA_FUNCTION_PF, 0, 16'h2200, 0, 64'h2200);
    cloned_object = duplicate_a.clone();
    if (cloned_object == null || !$cast(duplicate_b, cloned_object)) begin
      `uvm_error("RESET_LIFECYCLE", "duplicate key clone failed")
    end
    else begin
      staged.delete();
      staged.push_back(duplicate_a);
      staged.push_back(duplicate_b);
      status = probe.commit_registration_atomic(null, staged);
      if (status == null || status.code != RDMA_SC_INVALID_ARGUMENT ||
          probe.function_count() != 1)
        `uvm_error("RESET_LIFECYCLE", "duplicate stable key changed ledger")
    end

    reused_uid = make_identity(
      32'h12, 0, RDMA_FUNCTION_PF, 0, 16'h2300, 0, baseline.function_uid);
    staged.delete();
    staged.push_back(reused_uid);
    status = probe.commit_registration_atomic(null, staged);
    if (status == null || status.code != RDMA_SC_INVALID_ARGUMENT ||
        probe.function_count() != 1)
      `uvm_error("RESET_LIFECYCLE", "cross-route UID reuse was accepted")

    reused_global_id = make_identity(
      32'h13, 0, RDMA_FUNCTION_PF, 0, 16'h2400, 0, 64'h2400);
    reused_global_id.global_function_id = baseline.global_function_id;
    staged.delete();
    staged.push_back(reused_global_id);
    status = probe.commit_registration_atomic(null, staged);
    if (status == null || status.code != RDMA_SC_INVALID_ARGUMENT ||
        probe.function_count() != 1)
      `uvm_error("RESET_LIFECYCLE", "cross-route global ID reuse was accepted")

    // 单 Function 在 generation/reset epoch 最大值时，preview 和实际 reset 都必须
    // fail-closed，且不能建立新的 absolute counter。
    overflow_probe = rdma_reset_coordinator_probe::type_id::create(
      "lifecycle_overflow_probe");
    max_identity = make_identity(
      32'h20, 0, RDMA_FUNCTION_PF, 0, 16'h2500, 0, 64'h2500);
    max_identity.generation = GENERATION_MAX;
    max_identity.reset_epoch = EPOCH_MAX;
    staged.delete();
    staged.push_back(max_identity);
    status = overflow_probe.commit_registration_atomic(null, staged);
    if (status == null || !status.ok())
      `uvm_error("RESET_LIFECYCLE", "max incarnation registration failed")
    status = overflow_probe.preview_next_function_epoch(max_identity, next_epoch);
    if (status == null || status.code != RDMA_SC_RESOURCE_EXHAUSTED ||
        next_epoch != 0)
      `uvm_error("RESET_LIFECYCLE", "max epoch preview wrapped")
    status = overflow_probe.request_pf_reset(max_identity);
    if (status == null || status.code != RDMA_SC_RESOURCE_EXHAUSTED ||
        overflow_probe.function_epoch_uid(max_identity.function_uid) != EPOCH_MAX)
      `uvm_error("RESET_LIFECYCLE", "max Function reset wrapped")

    // PF scope capacity 预检必须先看到 VF overflow，再拒绝 PF bump，不能留下单侧 epoch。
    scope_probe = rdma_reset_coordinator_probe::type_id::create(
      "lifecycle_scope_overflow_probe");
    scope_pf = make_identity(
      32'h30, 0, RDMA_FUNCTION_PF, 0, 16'h2600, 0, 64'h2600);
    scope_vf = make_identity(
      32'h30, 0, RDMA_FUNCTION_VF, 1, 16'h2601, 16'h2600, 64'h2601);
    staged.delete();
    staged.push_back(scope_pf);
    staged.push_back(scope_vf);
    status = scope_probe.commit_registration_atomic(null, staged);
    if (status == null || !status.ok())
      `uvm_error("RESET_LIFECYCLE", "scope overflow registration failed")
    scope_probe.force_function_absolute_epoch(scope_vf, EPOCH_MAX);
    before_pf_epoch = scope_probe.function_epoch_uid(scope_pf.function_uid);
    before_vf_epoch = scope_probe.function_epoch_uid(scope_vf.function_uid);
    status = scope_probe.request_pf_reset(scope_pf);
    if (status == null || status.code != RDMA_SC_RESOURCE_EXHAUSTED ||
        scope_probe.function_epoch_uid(scope_pf.function_uid) != before_pf_epoch ||
        scope_probe.function_epoch_uid(scope_vf.function_uid) != before_vf_epoch)
      `uvm_error("RESET_LIFECYCLE", "PF scope overflow partially bumped ledger")

    // router-local Host counter 在最大值时也必须先于 coordinator/Function mutation 拒绝，
    // 否则 Host mapping 会回绕而其它 ledger 已经前进。
    host_router_probe = rdma_reset_host_router_probe::type_id::create(
      "lifecycle_host_router_probe");
    overflow_probe.attach_host_router(host_router_probe);
    // attach_host_router() 会在首次绑定时重置 router-local epoch；因此必须在
    // attach 完成后再注入最大值，才能真正覆盖 advance_host_epoch() 的溢出分支。
    host_router_probe.seed_host_epoch(32'h20, EPOCH_MAX);
    status = overflow_probe.request_host_reset(32'h20);
    if (status == null || status.code != RDMA_SC_RESOURCE_EXHAUSTED ||
        overflow_probe.host_epoch(32'h20) != 0 ||
        host_router_probe.local_host_epoch(32'h20) != EPOCH_MAX)
      `uvm_error("RESET_LIFECYCLE", "router-local Host epoch overflow was not atomic")

    // Host/Device 自身的 absolute counter 溢出也必须在 router/Function mutation 前拒绝。
    overflow_probe.force_host_absolute_epoch(32'h20, EPOCH_MAX);
    status = overflow_probe.request_host_reset(32'h20);
    if (status == null || status.code != RDMA_SC_RESOURCE_EXHAUSTED ||
        overflow_probe.host_epoch(32'h20) != EPOCH_MAX)
      `uvm_error("RESET_LIFECYCLE", "Host epoch overflow was not fail-closed")
    overflow_probe.force_device_absolute_epoch(EPOCH_MAX);
    status = overflow_probe.request_device_reset();
    if (status == null || status.code != RDMA_SC_RESOURCE_EXHAUSTED ||
        overflow_probe.device_epoch() != EPOCH_MAX)
      `uvm_error("RESET_LIFECYCLE", "Device epoch overflow was not fail-closed")

    // env guard 的同步重入入口必须先返回 RESOURCE_BUSY；清除 guard 后，空 scope
    // 应回到正常 INVALID_STATE preflight，而不是保持 busy 或伪造 reset 成功。
    busy_env = rdma_device_env_busy_probe::type_id::create(
      "lifecycle_busy_env");
    busy_coordinator = rdma_reset_coordinator_probe::type_id::create(
      "lifecycle_busy_coordinator");
    busy_env.arm_busy(busy_coordinator);
    status = busy_env.request_device_reset();
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY)
      `uvm_error("RESET_LIFECYCLE", "reset reentrancy guard did not reject nested request")
    busy_env.clear_busy();
    status = busy_env.request_device_reset();
    if (status == null || status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("RESET_LIFECYCLE", "reset reentrancy guard was not released")

    // coordinator 自身的同步 publication guard 还要覆盖同一 owner/无 owner 的 callback
    // 嵌套；仅依赖 device-env 的 m_reset_in_progress 会让直接 coordinator callback 绕过
    // outer scope。probe 只置位内部 guard，不伪造 lease 或 epoch，预期 request_* 在 scope
    // 校验前立即返回 RESOURCE_BUSY；清除后空 Function scope 仍允许 legacy Device reset，
    // 因为 Device epoch 本身是独立的全局 publication。
    busy_coordinator = rdma_reset_coordinator_probe::type_id::create(
      "publication_reentry_coordinator"
    );
    busy_coordinator.force_reset_operation_active(1'b1);
    status = busy_coordinator.request_device_reset();
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY)
      `uvm_error("RESET_LIFECYCLE",
                 "coordinator publication guard accepted nested reset")
    busy_coordinator.force_reset_operation_active(1'b0);
    status = busy_coordinator.request_device_reset();
    if (status == null || !status.ok() ||
        busy_coordinator.device_epoch() != 1)
      `uvm_error("RESET_LIFECYCLE",
                 "coordinator publication guard did not release after callback seam")

    // Batch111 hostile synchronous callback contract：publication guard active 时，legacy
    // callback 不能 claim lease、替换 router、提交 Function registration、开启/结束
    // transaction 或通过 router.configure() 改写路由表；每条拒绝都必须保留原来的
    // owner、双侧 router 引用、Function 数量和 epoch。这里先建立合法 legacy fixture，
    // 再在同一调用栈中置位 guard 并连续调用 status seam，模拟 validator/router callback
    // 尚未返回时的 direct mutation，而不是把失败归因于输入本身无效。
    mutation_probe = rdma_reset_coordinator_probe::type_id::create(
      "publication_mutation_probe");
    mutation_owner = rdma_reset_coordinator_probe::type_id::create(
      "publication_mutation_owner");
    mutation_router = rdma_reset_host_router_probe::type_id::create(
      "publication_mutation_router");
    mutation_replacement_router = rdma_host_mem_router::type_id::create(
      "publication_mutation_replacement_router");
    mutation_identity = make_identity(
      32'h50, 0, RDMA_FUNCTION_PF, 0, 16'h2800, 0, 64'h2800);
    mutation_staged.delete();
    mutation_staged.push_back(mutation_identity);
    status = mutation_probe.commit_registration_atomic(
      mutation_router, mutation_staged
    );
    if (status == null || !status.ok() ||
        !mutation_probe.host_router_bound() ||
        mutation_probe.function_count() != 1)
      `uvm_error("RESET_PUBLICATION_GUARD",
                 "hostile callback fixture setup failed")
    mutation_router.seed_host_epoch(32'h50, 0);
    mutation_identity_extra = make_identity(
      32'h51, 0, RDMA_FUNCTION_PF, 0, 16'h2801, 0, 64'h2801);
    mutation_staged.delete();
    mutation_staged.push_back(mutation_identity_extra);
    mutation_probe.force_reset_operation_active(1'b1);

    lease_token = 0;
    status = mutation_probe.acquire_lease(mutation_owner, lease_token);
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY ||
        lease_token != 0 || mutation_probe.lease_held())
      `uvm_error("RESET_PUBLICATION_GUARD",
                 "hostile callback acquired a coordinator lease")

    status = mutation_probe.attach_host_router_status(
      mutation_replacement_router
    );
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY ||
        !mutation_probe.host_router_bound())
      `uvm_error("RESET_PUBLICATION_GUARD",
                 "hostile callback replaced the legacy Host router")

    status = mutation_probe.commit_registration_atomic(
      null, mutation_staged
    );
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY ||
        mutation_probe.function_count() != 1 ||
        mutation_probe.function_epoch_uid(mutation_identity.function_uid) != 0)
      `uvm_error("RESET_PUBLICATION_GUARD",
                 "hostile callback changed the Function registration ledger")

    mutation_entries.delete();
    status = mutation_router.configure(mutation_entries);
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY ||
        !mutation_probe.host_router_bound())
      `uvm_error("RESET_PUBLICATION_GUARD",
                 "legacy router configure bypassed publication guard")

    status = mutation_router.validate_host_epoch_capacity(32'h50);
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY ||
        mutation_router.local_host_epoch(32'h50) != 0)
      `uvm_error("RESET_PUBLICATION_GUARD",
                 "legacy router epoch capacity callback bypassed guard")
    status = mutation_router.advance_host_epoch(32'h50);
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY ||
        mutation_router.local_host_epoch(32'h50) != 0)
      `uvm_error("RESET_PUBLICATION_GUARD",
                 "legacy router epoch advance callback bypassed guard")

    status = mutation_probe.begin_reset(mutation_owner, 0);
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY ||
        mutation_probe.reset_transaction_active())
      `uvm_error("RESET_PUBLICATION_GUARD",
                 "hostile callback began a reset transaction")

    status = mutation_probe.end_reset(mutation_owner, 0);
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY ||
        mutation_probe.reset_transaction_active())
      `uvm_error("RESET_PUBLICATION_GUARD",
                 "hostile callback ended a legacy reset transaction")

    status = mutation_probe.release_lease(null, 0);
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY ||
        mutation_probe.lease_held())
      `uvm_error("RESET_PUBLICATION_GUARD",
                 "hostile callback released coordinator ownership")
    mutation_probe.force_reset_operation_active(1'b0);

    // leased transaction 的 end seam 也必须保持 active，直到 outer wrapper 已经释放
    // publication guard；guard 清除后相同 owner/token 才能正常 end/release。
    transaction_probe = rdma_reset_coordinator_probe::type_id::create(
      "publication_transaction_probe");
    transaction_owner = rdma_device_env_busy_probe::type_id::create(
      "publication_transaction_owner");
    transaction_router = rdma_reset_host_router_probe::type_id::create(
      "publication_transaction_router");
    transaction_token = 0;
    status = transaction_probe.acquire_lease(
      transaction_owner, transaction_token
    );
    if (status == null || !status.ok() || transaction_token == 0)
      `uvm_error("RESET_PUBLICATION_GUARD",
                 "transaction fixture lease acquisition failed")
    status = transaction_probe.attach_host_router_owned(
      transaction_router, transaction_owner, transaction_token
    );
    if (status == null || !status.ok() ||
        !transaction_probe.host_router_bound() ||
        !transaction_router.has_reset_coordinator(transaction_probe))
      `uvm_error("RESET_PUBLICATION_GUARD",
                 "transaction fixture router attach failed")
    status = transaction_probe.begin_reset(
      transaction_owner, transaction_token
    );
    if (status == null || !status.ok() ||
        !transaction_probe.reset_transaction_active())
      `uvm_error("RESET_PUBLICATION_GUARD",
                 "transaction fixture begin failed")
    transaction_probe.force_reset_operation_active(1'b1);
    status = transaction_probe.detach_host_router_owned(
      transaction_router, transaction_owner, transaction_token
    );
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY ||
        !transaction_probe.host_router_bound() ||
        !transaction_router.has_reset_coordinator(transaction_probe))
      `uvm_error("RESET_PUBLICATION_GUARD",
                 "hostile callback detached the leased Host router")
    status = transaction_probe.attach_host_router_owned(
      transaction_router, transaction_owner, transaction_token
    );
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY ||
        !transaction_probe.host_router_bound())
      `uvm_error("RESET_PUBLICATION_GUARD",
                 "hostile callback rebound the leased Host router")
    status = transaction_probe.commit_registration_atomic(
      null, mutation_staged, transaction_owner, transaction_token
    );
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY ||
        transaction_probe.function_count() != 0)
      `uvm_error("RESET_PUBLICATION_GUARD",
                 "hostile callback committed a leased Function registration")
    status = transaction_probe.end_reset(
      transaction_owner, transaction_token
    );
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY ||
        !transaction_probe.reset_transaction_active())
      `uvm_error("RESET_PUBLICATION_GUARD",
                 "hostile callback cleared leased reset transaction")
    status = transaction_probe.release_lease(
      transaction_owner, transaction_token
    );
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY ||
        !transaction_probe.lease_held())
      `uvm_error("RESET_PUBLICATION_GUARD",
                 "hostile callback released active leased transaction")
    transaction_probe.force_reset_operation_active(1'b0);
    status = transaction_probe.end_reset(
      transaction_owner, transaction_token
    );
    if (status == null || !status.ok() ||
        transaction_probe.reset_transaction_active())
      `uvm_error("RESET_PUBLICATION_GUARD",
                 "leased transaction could not end after guard release")
    status = transaction_probe.detach_host_router_owned(
      transaction_router, transaction_owner, transaction_token
    );
    if (status == null || !status.ok() ||
        transaction_probe.host_router_bound() ||
        transaction_router.has_reset_coordinator(transaction_probe))
      `uvm_error("RESET_PUBLICATION_GUARD",
                 "leased transaction router did not detach cleanly")
    status = transaction_probe.release_lease(
      transaction_owner, transaction_token
    );
    if (status == null || !status.ok() || transaction_probe.lease_held())
      `uvm_error("RESET_PUBLICATION_GUARD",
                 "leased transaction fixture did not release cleanly")

    // Batch109 lease contract：一对一 owner claim 后，旧 token、另一个 env 和无 token
    // 的 direct registration/reset 都必须在任何 ledger side effect 前返回 RESOURCE_BUSY；
    // 正确 owner 只有在 begin/end 成对使用期间才能发布 reset。
    // legacy attach 没有 owner handoff capability；新 owner 不能在旧 bilateral binding
    // 仍存活时静默接管 coordinator，否则 close/detach 的责任无法判定。
    legacy_attach_probe = rdma_reset_coordinator::type_id::create(
      "lifecycle_legacy_attach_probe"
    );
    legacy_attach_owner = rdma_reset_coordinator_probe::type_id::create(
      "lifecycle_legacy_attach_owner"
    );
    legacy_attach_router = rdma_host_mem_router::type_id::create(
      "lifecycle_legacy_attach_router"
    );
    legacy_attach_token = 0;
    legacy_attach_probe.attach_host_router(legacy_attach_router);
    status = legacy_attach_probe.acquire_lease(
      legacy_attach_owner, legacy_attach_token
    );
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY ||
        legacy_attach_token != 0 || !legacy_attach_probe.host_router_bound())
      `uvm_error("RESET_LEASE",
                 "legacy router binding was silently adopted by a new lease")

    lease_probe = rdma_reset_coordinator::type_id::create(
      "lifecycle_lease_probe");
    lease_owner_a = rdma_device_env_busy_probe::type_id::create(
      "lifecycle_lease_owner_a");
    lease_owner_b = rdma_device_env_busy_probe::type_id::create(
      "lifecycle_lease_owner_b");
    lease_token = 0;
    competing_token = 0;
    status = lease_probe.acquire_lease(lease_owner_a, lease_token);
    if (status == null || !status.ok() || lease_token == 0)
      `uvm_error("RESET_LEASE", "coordinator lease acquire failed")

    // Router 的 legacy void detach/rebind 与 tokenless configure 都不能绕过已 claim
    // 的 coordinator；即使 owner/token 正确，router owned seam 仍须由 coordinator
    // 生成的一次性 capability 驱动，拒绝路径不能形成单侧绑定。
    lease_router = rdma_reset_host_router_probe::type_id::create(
      "lifecycle_lease_router");
    status = lease_router.attach_reset_coordinator_owned(
      lease_probe, lease_owner_a, lease_token);
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY ||
        lease_router.has_reset_coordinator(lease_probe) ||
        lease_probe.host_router_bound())
      `uvm_error("RESET_LEASE",
                 "direct router owned attach bypassed bilateral capability")
    status = lease_probe.attach_host_router_owned(
      lease_router, lease_owner_a, lease_token
    );
    if (status == null || !status.ok() ||
        !lease_router.has_reset_coordinator(lease_probe) ||
        !lease_probe.host_router_bound())
      `uvm_error("RESET_LEASE", "lease owner could not attach router")
    status = lease_router.detach_reset_coordinator_owned(
      lease_probe, lease_owner_a, lease_token
    );
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY ||
        !lease_router.has_reset_coordinator(lease_probe) ||
        !lease_probe.host_router_bound())
      `uvm_error("RESET_LEASE",
                 "direct router owned detach bypassed bilateral capability")
    status = lease_router.attach_reset_coordinator_owned(
      lease_probe, lease_owner_b, lease_token);
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY ||
        !lease_router.has_reset_coordinator(lease_probe))
      `uvm_error("RESET_LEASE", "wrong owner replaced router coordinator")
    lease_router.attach_reset_coordinator(null);
    if (!lease_router.has_reset_coordinator(lease_probe))
      `uvm_error("RESET_LEASE", "tokenless router detach bypassed lease")

    // leased context 的兼容 reset wrapper 必须在 identity/binding 交换前拒绝；该 fixture
    // 只配置本地 identity/binding 值图，不创建 Host-memory、PCIe 或 queue 资源。
    leased_context = rdma_function_context::type_id::create(
      "lifecycle_leased_context");
    leased_context_identity = make_identity(
      32'h40, 0, RDMA_FUNCTION_PF, 0, 16'h2700, 0, 64'h2700);
    leased_context_binding = rdma_function_binding::type_id::create(
      "lifecycle_leased_binding");
    status = leased_context_binding.configure_identity(leased_context_identity);
    if (status == null || !status.ok()) begin
      `uvm_error("RESET_LEASE", "leased context binding fixture failed")
    end
    else begin
      leased_context_binding.owner_h = leased_context_binding.make_handle();
      leased_context_binding.state = RDMA_BIND_ACTIVE;
      leased_context.identity = leased_context_identity;
      leased_context.binding = leased_context_binding;
      leased_context.state = RDMA_CONTEXT_ACTIVE;
      leased_context.reset_coordinator = lease_probe;
      context_identity_before_reset = leased_context.identity;
      status = leased_context.reset(2, 1);
      if (status == null || status.code != RDMA_SC_RESOURCE_BUSY ||
          leased_context.identity !== context_identity_before_reset ||
          leased_context.state != RDMA_CONTEXT_ACTIVE)
        `uvm_error("RESET_LEASE", "leased context direct reset bypassed ownership")
    end

    status = lease_probe.acquire_lease(lease_owner_b, competing_token);
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY ||
        competing_token != 0)
      `uvm_error("RESET_LEASE", "second owner was not rejected")
    status = lease_probe.request_device_reset();
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY)
      `uvm_error("RESET_LEASE", "direct device reset bypassed owner lease")
    status = lease_probe.begin_reset(lease_owner_b, lease_token);
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY)
      `uvm_error("RESET_LEASE", "wrong lease owner began reset")
    status = lease_probe.begin_reset(lease_owner_a, lease_token);
    if (status == null || !status.ok())
      `uvm_error("RESET_LEASE", "lease owner could not begin reset")
    status = lease_probe.request_device_reset();
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY)
      `uvm_error("RESET_LEASE", "active transaction accepted tokenless reset")
    status = lease_probe.end_reset(lease_owner_a, lease_token);
    if (status == null || !status.ok())
      `uvm_error("RESET_LEASE", "lease owner could not end reset")
    status = lease_probe.release_lease(lease_owner_b, lease_token);
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY)
      `uvm_error("RESET_LEASE", "wrong lease owner released coordinator")
    status = lease_probe.attach_host_router_owned(
      lease_router, lease_owner_a, lease_token
    );
    if (status == null || !status.ok())
      `uvm_error("RESET_LEASE", "lease owner could not attach coordinator router")
    status = lease_probe.release_lease(lease_owner_a, lease_token);
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY)
      `uvm_error("RESET_LEASE", "lease released while router remained attached")
    status = lease_probe.detach_host_router_owned(
      lease_router, lease_owner_a, lease_token
    );
    if (status == null || !status.ok() ||
        lease_router.has_reset_coordinator(lease_probe))
      `uvm_error("RESET_LEASE", "coordinator/router bilateral detach failed")
    status = lease_probe.release_lease(lease_owner_a, lease_token);
    if (status == null || !status.ok() || lease_probe.lease_held())
      `uvm_error("RESET_LEASE", "lease release did not clear ownership")

    phase.drop_objection(this);
  endtask
endclass
