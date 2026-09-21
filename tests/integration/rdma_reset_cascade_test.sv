// 目录/层次：tests/integration/ 集成测试层，验证 rdma_device_env 的 VF/PF/Host/Device 复位级联范围。
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

// 设计说明：该 context 子类只为 reset 原子性测试提供可控的 prepare 故障 seam；
// 生产 rdma_function_context 不携带计数器或故障状态。通过 UVM type override 让
// device env 仍走同一 build_shared()/rebuild_scope() 路径，只替换 prepare_reset()
// 的可观察失败点。
class rdma_reset_prepare_fault_context extends rdma_function_context;
  `uvm_object_utils(rdma_reset_prepare_fault_context)
  static int unsigned prepare_call_count;
  static int unsigned fail_on_call;
  static bit fault_enabled;

  // 功能：构造 reset 故障注入用的 Function context，沿用基类默认 DISCOVERED 状态。
  // 输入/输出及副作用：name（输入）；调用基类构造，不取得或替换外部 identity/router 所有权。
  // 失败/边界：构造本身不注入故障；故障窗口由 arm() 显式开启，避免影响正常级联场景。
  function new(string name = "rdma_reset_prepare_fault_context");
    super.new(name);
  endfunction

  // 功能：设置第 nth 次 prepare_reset() 返回 RESOURCE_EXHAUSTED，并清零本轮计数。
  // 输入/输出及副作用：nth（输入）必须大于零；写入静态测试控制字段，不修改任何 context。
  // 失败/边界：nth=0 表示不匹配任何调用但仍开启计数；调用方应传入 scope 实际包含的
  //   第二个 context，以验证首个 candidate 已构造但未提交。
  static function void arm(int unsigned nth);
    prepare_call_count = 0;
    fail_on_call = nth;
    fault_enabled = 1'b1;
  endfunction

  // 功能：关闭 prepare 故障并清理静态计数，恢复基类 prepare_reset() 行为。
  // 输入/输出及副作用：无输入；写入静态控制字段，不回滚已经完成的 context 状态。
  // 失败/边界：调用方必须在 reset 请求返回后调用；重复关闭幂等。
  static function void disarm();
    fault_enabled = 1'b0;
    fail_on_call = 0;
  endfunction

  // 功能：统计当前 reset scope 的 candidate prepare 次数，并在指定调用点注入失败；
  //       非故障调用委托基类完成真实 detached identity/binding 构造。
  // 输入/输出及副作用：new_generation/new_epoch 为 reset 输入，candidate 为输出；故障点
  //   返回 null candidate 且不修改 context，正常点只产生基类 prepare 的 detached 值图。
  // 失败/边界：故障开启且计数命中 fail_on_call 时返回 RESOURCE_EXHAUSTED；其他失败条件
  //   原样透传基类 status，调用方不得在 status 错误后推进 coordinator epoch。
  virtual function rdma_status prepare_reset(
    int unsigned new_generation,
    rdma_reset_epoch_t new_epoch,
    output rdma_function_reset_candidate candidate
  );
    prepare_call_count++;
    if (fault_enabled && prepare_call_count == fail_on_call) begin
      candidate = null;
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "injected second Function reset prepare failure"
      );
    end
    return super.prepare_reset(new_generation, new_epoch, candidate);
  endfunction
endclass

// 设计说明：该 context 子类模拟一个合法返回但不可信的 virtual callback；它在第二个
//       Function candidate 的 validate 期间改写第一个 candidate 的 detached identity、
//       binding 和 owner，使单候选自洽校验无法掩盖跨 context seal 漂移。
// 生产 context 不携带静态候选或故障计数；device env 必须依靠自身拥有的 fingerprint
//       在所有 virtual callback 返回后重新验证，而不是相信 candidate.validation_complete。
class rdma_reset_candidate_mutation_context extends rdma_function_context;
  `uvm_object_utils(rdma_reset_candidate_mutation_context)
  static rdma_function_reset_candidate first_candidate;
  static int unsigned prepare_call_count;
  static int unsigned validate_call_count;
  static bit mutation_enabled;
  static bit mutation_seen;
  static bit mutation_failed;

  // 功能：构造 candidate mutation 故障注入用的 Function context，沿用基类默认
  //       DISCOVERED 状态和所有 dependency 引用语义。
  // 输入/输出及副作用：name（输入）；调用基类构造，不取得或替换外部 identity/router 所有权。
  // 失败/边界：构造不注入故障；prepare/validate 计数和 mutation 窗口由 arm() 显式控制。
  function new(string name = "rdma_reset_candidate_mutation_context");
    super.new(name);
  endfunction

  // 功能：清理静态 candidate 句柄和计数，打开第二个 validate callback 的跨 context
  //       mutation 窗口。
  // 输入/输出及副作用：无输入；写入本测试 subclass 的静态控制字段，不修改任何 context
  //       或 coordinator；后续第一次成功 prepare 的 candidate 会被保存为攻击目标。
  // 失败/边界：重复 arm 幂等地丢弃旧 candidate；调用方须在目标 reset 返回后调用 disarm。
  static function void arm();
    first_candidate = null;
    prepare_call_count = 0;
    validate_call_count = 0;
    mutation_enabled = 1'b1;
    mutation_seen = 1'b0;
    mutation_failed = 1'b0;
  endfunction

  // 功能：关闭 hostile mutation callback，保留本轮 mutation_seen/mutation_failed 结果供
  //       测试断言，并清除不再使用的 candidate 引用。
  // 输入/输出及副作用：无输入；只写静态控制字段，不回滚已发生的 candidate 改写。
  // 失败/边界：重复关闭幂等；调用方必须先读取结果再 arm 下一轮，否则新 arm 会清零计数。
  static function void disarm();
    mutation_enabled = 1'b0;
    first_candidate = null;
  endfunction

  // 功能：委托基类构造 detached candidate，并记录 reset scope 中第一次成功 prepare 的
  //       candidate，供后续 context 的 virtual validate callback 定点改写。
  // 输入/输出及副作用：new_generation/new_epoch 为 reset 输入，candidate 为输出；成功时
  //       仅保存非拥有 candidate 引用并递增静态 prepare 计数，不修改当前 context。
  // 失败/边界：基类 prepare 失败或返回 null 时不记录攻击目标；调用方仍须按 status 处理，
  //       不得在失败后推进 coordinator epoch。
  virtual function rdma_status prepare_reset(
    int unsigned new_generation,
    rdma_reset_epoch_t new_epoch,
    output rdma_function_reset_candidate candidate
  );
    rdma_status status;

    status = super.prepare_reset(new_generation, new_epoch, candidate);
    if (mutation_enabled && status != null && status.ok() &&
        candidate != null) begin
      prepare_call_count++;
      if (first_candidate == null)
        first_candidate = candidate;
    end
    return status;
  endfunction

  // 功能：在第二次 candidate validation 期间对第一个已验证候选执行 coherent incarnation
  //       mutation，再委托当前 candidate 的正常校验，以证明单候选 self-consistency 不能
  //       代替 env-owned cross-context seal。
  // 输入/输出及副作用：candidate 为当前 context 的输入；首次 validate 只递增计数，第二次
  //       validate 会把 first_candidate.identity.generation 增大并同步 binding/owner 快照，
  //       返回当前 candidate 的基类验证 status。
  // 失败/边界：缺少 first_candidate、binding factory 失败或 owner/snapshot 生成失败时只置
  //       mutation_failed 并不伪造成功；mutation_enabled 关闭后完全复用基类行为。
  virtual function rdma_status validate_reset_candidate(
    rdma_function_reset_candidate candidate
  );
    rdma_status status;

    if (mutation_enabled)
      validate_call_count++;
    if (mutation_enabled && validate_call_count == 2 &&
        first_candidate != null) begin
      first_candidate.identity.generation += 16;
      status = first_candidate.binding.configure_identity(
        first_candidate.identity
      );
      if (status == null || !status.ok()) begin
        mutation_failed = 1'b1;
      end
      else begin
        first_candidate.binding.owner_h =
          first_candidate.binding.make_handle();
        first_candidate.binding_identity_snapshot =
          first_candidate.binding.identity_snapshot();
        if (first_candidate.binding.owner_h == null ||
            first_candidate.binding_identity_snapshot == null)
          mutation_failed = 1'b1;
        else
          mutation_seen = 1'b1;
      end
    end
    return super.validate_reset_candidate(candidate);
  endfunction
endclass

// 设计说明：该 probe 只暴露 device env 的 rollback-status 合并 seam，验证错误诊断
//       的所有权边界；生产 env 不需要公开 protected helper，也不携带测试状态。
class rdma_reset_status_probe extends rdma_device_env;
  `uvm_object_utils(rdma_reset_status_probe)

  // 功能：构造只用于调用 protected rollback 合并 helper 的 device-env probe。
  // 输入/输出及副作用：name（输入）；调用基类构造，不绑定 snapshot、router 或 reset ledger。
  // 失败/边界：probe 不应执行 build/reset；它只作为静态 helper 的受控访问边界存在。
  function new(string name = "rdma_reset_status_probe");
    super.new(name);
  endfunction

  // 功能：转发 reset_status_after_rollback()，供测试验证原始失败和恢复失败的合并契约。
  // 输入/输出及副作用：original_status/rollback_status/phase（输入）；返回 detached 合并
  //   status，不修改两个输入对象或任何 env 状态。
  // 失败/边界：null 输入必须被转换为非空 INVALID_STATE；rollback 非 OK 时返回 rollback
  //   code 并携带 original/rollback 诊断，调用方应检查输入 status 未被就地改写。
  static function rdma_status merge(
    rdma_status original_status,
    rdma_status rollback_status,
    string phase
  );
    return reset_status_after_rollback(
      original_status, rollback_status, phase
    );
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
    rdma_function_identity stale_identity;
    rdma_function_identity unknown_identity;
    rdma_function_context vf_context;
    rdma_function_identity after_ledger;
    uvm_object cloned_object;
    rdma_function_context_state_e before_state;
    int unsigned before_generation;
    rdma_reset_epoch_t before_identity_epoch;
    rdma_reset_epoch_t before_function_epoch;
    rdma_reset_epoch_t before_device_epoch;
    rdma_reset_epoch_t before_router_epoch;
    rdma_reset_epoch_t before_unknown_host_epoch;
    rdma_reset_epoch_t before_pf_epoch;
    rdma_reset_epoch_t before_vf_epoch;
    rdma_reset_epoch_t before_host0_epoch;
    rdma_reset_epoch_t before_device_reset_epoch;
    rdma_reset_epoch_t before_router0_epoch;
    rdma_function_identity before_ledger[string];
    rdma_function_context_state_e before_states[string];
    dpu_function_key_t key;
    uvm_object registry;
    uvm_factory factory;
    uvm_object_wrapper saved_context_override;
    rdma_status original_reset_status;
    rdma_status rollback_reset_status;
    rdma_status merged_reset_status;
    string expected_rollback_message;

    phase.raise_objection(this);
    // Batch101 rollback seam：恢复失败必须向调用方暴露 rollback code 和双侧诊断，
    // 同时不能就地改写外部传入的 rollback status；null 输入也必须 fail-closed。
    original_reset_status = rdma_status::make_direct(
      RDMA_SC_RESOURCE_EXHAUSTED, "candidate prepare failed"
    );
    rollback_reset_status = rdma_status::make_direct(
      RDMA_SC_INVALID_STATE, "restore failed"
    );
    expected_rollback_message = {
      "reset prepare rollback failed after original reset failure: ",
      "candidate prepare failed; rollback: restore failed"
    };
    merged_reset_status = rdma_reset_status_probe::merge(
      original_reset_status, rollback_reset_status, "reset prepare"
    );
    if (merged_reset_status == null ||
        merged_reset_status.code != RDMA_SC_INVALID_STATE ||
        merged_reset_status.message != expected_rollback_message ||
        rollback_reset_status.message != "restore failed")
      `uvm_error("RESET_ROLLBACK", "rollback failure was not detached or propagated")
    merged_reset_status = rdma_reset_status_probe::merge(
      null, rollback_reset_status, "null original"
    );
    if (merged_reset_status == null || merged_reset_status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("RESET_ROLLBACK", "null original reset status was not normalized")
    merged_reset_status = rdma_reset_status_probe::merge(
      original_reset_status, null, "null rollback"
    );
    if (merged_reset_status == null || merged_reset_status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("RESET_ROLLBACK", "null rollback status was not normalized")

    build_snapshots(device_snapshot, resource_snapshot);
    dpu_manager = dpu_resource_manager::type_id::create("reset_dpu_manager");
    host_mem = rdma_host_mem_router::type_id::create("reset_host_mem");
    pcie = rdma_pcie_router::type_id::create("reset_pcie");
    coordinator = rdma_reset_coordinator::type_id::create("reset_coordinator");
    // 只对本 env 的 context 构造启用 prepare fault subclass；恢复既有 override
    // 后，已创建的四个对象仍保留 virtual seam，后续 reset 可注入第二次 prepare 失败。
    factory = uvm_factory::get();
    saved_context_override = factory.find_override_by_type(
      rdma_function_context::get_type(), "");
    factory.set_type_override_by_type(
      rdma_function_context::get_type(),
      rdma_reset_prepare_fault_context::get_type(), 1'b1);
    rdma_reset_prepare_fault_context::disarm();
    status = rdma_device_env::build(
      device_snapshot, resource_snapshot, dpu_manager, host_mem, pcie,
      registry, 1ns, env, coordinator);
    if (saved_context_override != null &&
        saved_context_override != rdma_function_context::get_type())
      factory.set_type_override_by_type(
        rdma_function_context::get_type(), saved_context_override, 1'b1);
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

    // Batch101 focused RED/GREEN：PF scope 选中 h0_pf0+h0_vf2。第二个 prepare
    // 故障时，第一个 candidate 已经 detached 构造但不得提交；两个 context、ledger、
    // Function/Host/Device/router epoch 都必须保持 quiesce 前快照。
    before_states.delete();
    foreach (contexts[name]) begin
      before_states[name] = contexts[name].state;
      before_ledger[name] = null;
    end
    key = make_key(0, 0, DPU_FUNCTION_PF);
    before_ledger["h0_pf0"] = env.get_identity(key);
    key = make_key(0, 0, DPU_FUNCTION_VF, 2);
    before_ledger["h0_vf2"] = env.get_identity(key);
    key = make_key(0, 1, DPU_FUNCTION_PF);
    before_ledger["h0_pf1"] = env.get_identity(key);
    key = make_key(1, 0, DPU_FUNCTION_PF);
    before_ledger["h1_pf0"] = env.get_identity(key);
    before_pf_epoch = env.reset_coordinator.function_epoch_uid(
      contexts["h0_pf0"].identity.function_uid);
    before_vf_epoch = env.reset_coordinator.function_epoch_uid(
      contexts["h0_vf2"].identity.function_uid);
    before_host0_epoch = env.reset_coordinator.host_epoch(0);
    before_device_reset_epoch = env.reset_coordinator.device_epoch();
    before_router0_epoch = host_mem.host_epoch(0);
    rdma_reset_prepare_fault_context::arm(2);
    status = env.request_pf_reset(identities["h0_pf0"]);
    rdma_reset_prepare_fault_context::disarm();
    if (status == null || status.ok() ||
        rdma_reset_prepare_fault_context::prepare_call_count != 2)
      `uvm_error("RESET_ATOMICITY",
                 "second Function prepare failure was not injected")
    foreach (contexts[name]) begin
      if (contexts[name] == null || contexts[name].identity == null)
        continue;
      if (contexts[name].state != before_states[name] ||
          contexts[name].identity.generation != before_gen[name] ||
          contexts[name].identity.reset_epoch != before_epoch[name])
        `uvm_error("RESET_ATOMICITY",
                   {"prepare failure changed context ", name})
      if (before_ledger[name] == null)
        `uvm_error("RESET_ATOMICITY", {"missing pre-reset ledger ", name})
      else begin
        key = (name == "h0_pf0") ? make_key(0, 0, DPU_FUNCTION_PF) :
              (name == "h0_vf2") ? make_key(0, 0, DPU_FUNCTION_VF, 2) :
              (name == "h0_pf1") ? make_key(0, 1, DPU_FUNCTION_PF) :
                                    make_key(1, 0, DPU_FUNCTION_PF);
        after_ledger = env.get_identity(key);
        if (after_ledger == null ||
            !after_ledger.same_incarnation(before_ledger[name]))
          `uvm_error("RESET_ATOMICITY",
                     {"prepare failure changed identity ledger ", name})
      end
    end
    if (env.reset_coordinator.function_epoch_uid(
          contexts["h0_pf0"].identity.function_uid) != before_pf_epoch ||
        env.reset_coordinator.function_epoch_uid(
          contexts["h0_vf2"].identity.function_uid) != before_vf_epoch ||
        env.reset_coordinator.host_epoch(0) != before_host0_epoch ||
        env.reset_coordinator.device_epoch() != before_device_reset_epoch ||
        host_mem.host_epoch(0) != before_router0_epoch)
      `uvm_error("RESET_ATOMICITY",
                 "prepare failure changed coordinator/router epoch")

    // stale identity 必须在 quiesce 前被拒绝；目标 context、Function epoch、
    // Device epoch 和 Host-router 可见 epoch 均保持原值，便于调用方安全重试。
    vf_context = contexts["h0_vf2"];
    before_state = vf_context.state;
    before_generation = vf_context.identity.generation;
    before_identity_epoch = vf_context.identity.reset_epoch;
    before_function_epoch = env.reset_coordinator.function_epoch_uid(
      vf_context.identity.function_uid);
    before_device_epoch = env.reset_coordinator.device_epoch();
    before_router_epoch = host_mem.host_epoch(0);
    cloned_object = identities["h0_vf2"].clone();
    if (cloned_object == null || !$cast(stale_identity, cloned_object))
      `uvm_fatal("RESET_ENV", "stale identity clone failed")
    stale_identity.generation = stale_identity.generation + 1;
    status = env.request_vf_flr(stale_identity);
    if (status == null || status.code != RDMA_SC_STALE_GENERATION ||
        vf_context.state != before_state ||
        vf_context.identity.generation != before_generation ||
        vf_context.identity.reset_epoch != before_identity_epoch ||
        env.reset_coordinator.function_epoch_uid(
          vf_context.identity.function_uid) != before_function_epoch ||
        env.reset_coordinator.device_epoch() != before_device_epoch ||
        host_mem.host_epoch(0) != before_router_epoch)
      `uvm_error("RESET_PREFLIGHT",
                 "stale VF request changed context or reset state")

    // unknown full route key 也必须在 quiesce 前失败，且不能制造 coordinator
    // phantom Function epoch。
    cloned_object = identities["h0_vf2"].clone();
    if (cloned_object == null || !$cast(unknown_identity, cloned_object))
      `uvm_fatal("RESET_ENV", "unknown identity clone failed")
    unknown_identity.key.host_topology_key = 99;
    status = env.request_vf_flr(unknown_identity);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        vf_context.state != before_state ||
        vf_context.identity.generation != before_generation ||
        env.reset_coordinator.function_epoch_uid(
          vf_context.identity.function_uid) != before_function_epoch)
      `uvm_error("RESET_PREFLIGHT",
                 "unknown VF request changed context or reset state")

    // 未登记 Host 的 request 不能先 quiesce 其它 Host，也不能建立 Host phantom
    // epoch；使用独立 key 观察 coordinator ledger 保持为零。
    before_unknown_host_epoch = env.reset_coordinator.host_epoch(99);
    status = env.request_host_reset(99);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        env.reset_coordinator.host_epoch(99) != before_unknown_host_epoch ||
        vf_context.state != before_state ||
        env.reset_coordinator.device_epoch() != before_device_epoch)
      `uvm_error("RESET_PREFLIGHT",
                 "unknown Host request changed reset state")

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

// 设计说明：该 focused integration test 只运行两 Function 的 PF scope，专门验证
//       前一 candidate 在后一 context 的 virtual validate 期间被 coherent 改写时，
//       device env 是否在 epoch publish 前使用 env-owned fingerprint 拒绝并回滚。
// 测试拥有本地 snapshot/router/coordinator/env；hostile context 只保存 detached candidate
//       引用，不取得 dpu_common、Host-memory 或 PCIe 外部资源所有权。
class rdma_reset_candidate_integrity_test extends rdma_reset_cascade_test;
  `uvm_component_utils(rdma_reset_candidate_integrity_test)

  // 功能：构造 candidate integrity focused test 组件，复用 reset cascade 的拓扑夹具
  //       helper，但不执行父类四级 reset cascade。
  // 输入/输出及副作用：name、parent（输入）；new 只建立 UVM component 名称，不创建
  //       snapshot、router、context 或 coordinator 资源。
  // 失败/边界：构造不执行故障注入；所有依赖和 factory override 均在 run_phase 管理。
  function new(string name = "rdma_reset_candidate_integrity_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：构造多 Function fixture，激活 PF/VF reset scope，注入第二个 virtual validate
  //       对第一个 candidate 的 coherent mutation，并断言所有可观察 reset 状态保持旧值。
  // 输入/输出及副作用：phase（输入）；task 通过 objection、factory override、reset 请求
  //       和 UVM assertion 产生报告，只操作本测试拥有的 fixture。
  // 失败/边界：构造/激活失败、mutation 未发生、reset 未拒绝、context/ledger/epoch 漂移均
  //       报告 UVM_ERROR；失败后不继续执行另一个 reset 操作。
  task run_phase(uvm_phase phase);
    rdma_reset_test_device_snapshot device_snapshot;
    rdma_reset_test_resource_snapshot resource_snapshot;
    dpu_resource_manager dpu_manager;
    rdma_host_mem_router host_mem;
    rdma_pcie_router pcie;
    rdma_reset_coordinator coordinator;
    rdma_device_env env;
    rdma_function_context pf_context;
    rdma_function_context vf_context;
    rdma_function_identity pf_identity;
    rdma_function_identity vf_identity;
    rdma_function_identity pf_before;
    rdma_function_identity vf_before;
    rdma_function_identity pf_ledger_before;
    rdma_function_identity vf_ledger_before;
    rdma_function_identity pf_ledger_after;
    rdma_function_identity vf_ledger_after;
    rdma_status status;
    uvm_factory factory;
    uvm_object_wrapper saved_override;
    uvm_object cloned_object;
    uvm_object registry;
    dpu_function_key_t key;
    rdma_function_context_state_e pf_state_before;
    rdma_function_context_state_e vf_state_before;
    rdma_reset_epoch_t pf_epoch_before;
    rdma_reset_epoch_t vf_epoch_before;
    rdma_reset_epoch_t host_epoch_before;
    rdma_reset_epoch_t device_epoch_before;
    rdma_reset_epoch_t router_epoch_before;

    phase.raise_objection(this);
    build_snapshots(device_snapshot, resource_snapshot);
    dpu_manager = dpu_resource_manager::type_id::create(
      "candidate_integrity_dpu_manager");
    host_mem = rdma_host_mem_router::type_id::create(
      "candidate_integrity_host_mem");
    pcie = rdma_pcie_router::type_id::create("candidate_integrity_pcie");
    coordinator = rdma_reset_coordinator::type_id::create(
      "candidate_integrity_coordinator");
    factory = uvm_factory::get();
    saved_override = factory.find_override_by_type(
      rdma_function_context::get_type(), "");
    factory.set_type_override_by_type(
      rdma_function_context::get_type(),
      rdma_reset_candidate_mutation_context::get_type(), 1'b1);
    rdma_reset_candidate_mutation_context::disarm();
    status = rdma_device_env::build(
      device_snapshot, resource_snapshot, dpu_manager, host_mem, pcie,
      registry, 1ns, env, coordinator);
    if (saved_override != null &&
        saved_override != rdma_function_context::get_type())
      factory.set_type_override_by_type(
        rdma_function_context::get_type(), saved_override, 1'b1);
    if (status == null || !status.ok() || env == null) begin
      `uvm_error("RESET_CANDIDATE", "candidate integrity env build failed")
      phase.drop_objection(this);
      return;
    end
    // build() 允许调用方省略 coordinator；此测试始终以 env 最终绑定的
    // coordinator 作为 epoch authority，避免在 factory/兼容路径下继续解引用
    // 尚未选中的本地句柄。
    coordinator = env.reset_coordinator;
    if (coordinator == null) begin
      `uvm_error("RESET_CANDIDATE", "candidate integrity coordinator lookup failed")
      phase.drop_objection(this);
      return;
    end

    pf_context = find_context(env, make_key(0, 0, DPU_FUNCTION_PF), pf_identity);
    vf_context = find_context(
      env, make_key(0, 0, DPU_FUNCTION_VF, 2), vf_identity);
    if (pf_context == null || vf_context == null ||
        pf_identity == null || vf_identity == null) begin
      `uvm_error("RESET_CANDIDATE", "candidate integrity context lookup failed")
      phase.drop_objection(this);
      return;
    end
    status = pf_context.activate();
    if (status == null || !status.ok())
      `uvm_error("RESET_CANDIDATE", "PF context activation failed")
    status = vf_context.activate();
    if (status == null || !status.ok())
      `uvm_error("RESET_CANDIDATE", "VF context activation failed")

    cloned_object = pf_context.identity.clone();
    if (cloned_object == null || !$cast(pf_before, cloned_object))
      `uvm_fatal("RESET_CANDIDATE", "PF identity snapshot failed")
    cloned_object = vf_context.identity.clone();
    if (cloned_object == null || !$cast(vf_before, cloned_object))
      `uvm_fatal("RESET_CANDIDATE", "VF identity snapshot failed")
    pf_state_before = pf_context.state;
    vf_state_before = vf_context.state;
    pf_ledger_before = env.get_identity(make_key(0, 0, DPU_FUNCTION_PF));
    vf_ledger_before = env.get_identity(
      make_key(0, 0, DPU_FUNCTION_VF, 2));
    pf_epoch_before = coordinator.function_epoch_uid(
      pf_context.identity.function_uid);
    vf_epoch_before = coordinator.function_epoch_uid(
      vf_context.identity.function_uid);
    host_epoch_before = coordinator.host_epoch(0);
    device_epoch_before = coordinator.device_epoch();
    router_epoch_before = host_mem.host_epoch(0);

    rdma_reset_candidate_mutation_context::arm();
    status = env.request_pf_reset(pf_identity);
    rdma_reset_candidate_mutation_context::disarm();
    if (!rdma_reset_candidate_mutation_context::mutation_seen ||
        rdma_reset_candidate_mutation_context::mutation_failed)
      `uvm_error("RESET_CANDIDATE", "hostile candidate mutation was not injected")
    if (status == null || status.ok() || status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("RESET_CANDIDATE", $sformatf(
        "candidate drift was not rejected: %s",
        status == null ? "null" : status.message))
    if (pf_context.state != pf_state_before ||
        vf_context.state != vf_state_before ||
        !pf_context.identity.same_incarnation(pf_before) ||
        !vf_context.identity.same_incarnation(vf_before))
      `uvm_error("RESET_CANDIDATE", "candidate drift changed context state/value")

    pf_ledger_after = env.get_identity(make_key(0, 0, DPU_FUNCTION_PF));
    vf_ledger_after = env.get_identity(
      make_key(0, 0, DPU_FUNCTION_VF, 2));
    if (pf_ledger_before == null || pf_ledger_after == null ||
        !pf_ledger_after.same_incarnation(pf_ledger_before) ||
        vf_ledger_before == null || vf_ledger_after == null ||
        !vf_ledger_after.same_incarnation(vf_ledger_before))
      `uvm_error("RESET_CANDIDATE", "candidate drift changed identity ledger")
    if (coordinator.function_epoch_uid(
          pf_context.identity.function_uid) != pf_epoch_before ||
        coordinator.function_epoch_uid(
          vf_context.identity.function_uid) != vf_epoch_before ||
        coordinator.host_epoch(0) != host_epoch_before ||
        coordinator.device_epoch() != device_epoch_before ||
        host_mem.host_epoch(0) != router_epoch_before)
      `uvm_error("RESET_CANDIDATE", "candidate drift changed reset epoch")
    phase.drop_objection(this);
  endtask
endclass
