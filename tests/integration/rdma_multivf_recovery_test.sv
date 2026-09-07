// 目录：测试层 tests/integration/。
// 职责：以 dpu_common 冻结快照构造双 Host/双 PF/四 VF 拓扑，验证故障隔离、
//       VF FLR generation fence 以及并发 recovery 结果；本文件只实现验证 harness。
// 依赖：rdma_device_env、rdma_reset_coordinator、rdma_coverage、UVM 和 dpu_common。
// 所有权与生命周期：测试拥有快照、环境及本地状态记录；Host-memory/PCIe router
//       由测试创建并由环境以非拥有引用保存，不修改外部依赖源码。

class rdma_multivf_test_device_snapshot extends dpu_device_snapshot;
  `uvm_object_utils(rdma_multivf_test_device_snapshot)

  // 功能：构造多 VF 快照夹具。
  // 输入/输出及副作用：name（输入）；建立可配置 dpu_common snapshot，不分配外部资源。
  // 失败/边界：空名称仍产生有效 UVM 对象，Function 必须在 freeze 前添加。
  function new(string name = "rdma_multivf_test_device_snapshot");
    super.new(name);
  endfunction

  // 功能：为夹具分配确定性的 global Function ID 并冻结快照，供 RDMA identity adapter 查询。
  // 输入/输出及副作用：无显式参数；更新 m_global_function_ids/m_frozen，不取得外部所有权。
  // 失败/边界：重复调用保持确定的 first-fit 编号；调用前必须已添加全部 Function。
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

class rdma_multivf_test_resource_snapshot extends dpu_resource_snapshot;
  `uvm_object_utils(rdma_multivf_test_resource_snapshot)

  // 功能：构造与 device snapshot 配对的资源快照夹具。
  // 输入/输出及副作用：name（输入）；建立空资源快照，不分配外部资源。
  // 失败/边界：资源快照必须通过 force_coherent 绑定冻结的 device snapshot 后才能使用。
  function new(string name = "rdma_multivf_test_resource_snapshot");
    super.new(name);
  endfunction

  // 功能：发布与 device snapshot 的一致性关系，满足 rdma_device_env 原子构建前置条件。
  // 输入/输出及副作用：device_snapshot（输入）；写入 m_device_snapshot/m_frozen，保存非拥有引用。
  // 失败/边界：传入 null 会导致后续 env 构建拒绝；该 helper 不复制或接管 snapshot。
  function void force_coherent(dpu_device_snapshot device_snapshot);
    m_device_snapshot = device_snapshot;
    m_frozen = 1'b1;
  endfunction
endclass

class rdma_multivf_recovery_test extends uvm_test;
  `uvm_component_utils(rdma_multivf_recovery_test)

  rdma_device_env env;
  rdma_coverage coverage;
  rdma_function_identity vf_identity[4];
  rdma_function_context vf_context[4];
  dpu_function_key_t vf_dpu_key[4];
  int unsigned vf_generation[4];
  int unsigned baseline_generation[4];
  longint unsigned baseline_uid[4];
  rdma_bdf_t baseline_bdf[4];
  bit [63:0] vf_iova[4];
  bit [63:0] baseline_iova[4];
  int unsigned vf_domain_id[4];
  int unsigned baseline_domain_id[4];
  int unsigned vf_completion_count[4];
  int unsigned vf_interrupt_count[4];
  int unsigned owned_release_count[4];
  int unsigned borrowed_release_count[4];
  rdma_status vf_status[4];

  // 功能：构造多 VF recovery 测试组件，不创建外部依赖对象。
  // 输入/输出及副作用：name、parent（输入）；调用 super.new，初始化由 run_phase 完成。
  // 失败/边界：未完成 build_fixture 时所有 helper 都返回 INVALID_STATE，禁止伪造成功。
  function new(string name = "rdma_multivf_recovery_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：把 Host/PF/VF key 转换为 dpu_common 使用的完整 Function key。
  // 输入/输出及副作用：host_id/pf_id/kind/vf_id（输入）；返回值为纯 packed key，不修改状态。
  // 失败/边界：该函数不校验快照存在性；非法组合由 dpu_common add_function 拒绝。
  function automatic dpu_function_key_t make_key(
    int unsigned host_id, int unsigned pf_id,
    dpu_function_kind_e kind, int unsigned vf_id = 0
  );
    dpu_function_key_t key;
    key.host_id = host_id;
    key.pf_id = pf_id;
    key.kind = kind;
    key.vf_id = vf_id;
    return key;
  endfunction

  // 功能：将 Function 及其 device/mailbox/MSI-X BAR 写入冻结前快照，形成可投影 binding。
  // 输入/输出及副作用：snapshot/key/segment/bdf（输入）；更新 snapshot 的 Function/BAR 表。
  // 失败/边界：重复 Function、重叠 BAR 或非法地址会 fatal；夹具地址不代表真实硬件所有权。
  task automatic add_function(
    rdma_multivf_test_device_snapshot snapshot,
    dpu_function_key_t key, int unsigned segment, int unsigned bdf
  );
    dpu_pcie_function_id_t pcie_id;
    dpu_bar_pair_lease_t bar;
    string why;
    pcie_id.domain.host_id = key.host_id;
    pcie_id.domain.segment_id = segment;
    pcie_id.bdf = bdf[15:0];
    if (!snapshot.add_function(key, pcie_id, why))
      `uvm_fatal("MULTIVF_ENV", {"add Function failed: ", why})
    bar.role = DPU_BAR_DEVICE_MEMORY;
    bar.even_bar_id = 0;
    bar.base = 64'h0000_0002_0000_0000 +
               (64'(segment) << 40) + (64'(bdf) << 24);
    bar.size = 64'h0000_0000_0020_0000;
    if (!snapshot.add_bar(key, bar, why)) `uvm_fatal("MULTIVF_ENV", why)
    bar.role = DPU_BAR_MAILBOX; bar.even_bar_id = 2;
    bar.base += 64'h0020_0000; bar.size = 64'h0000_0000_0001_0000;
    if (!snapshot.add_bar(key, bar, why)) `uvm_fatal("MULTIVF_ENV", why)
    bar.role = DPU_BAR_MSIX; bar.even_bar_id = 4; bar.base += 64'h0010_0000;
    if (!snapshot.add_bar(key, bar, why)) `uvm_fatal("MULTIVF_ENV", why)
  endtask

  // 功能：创建双 Host、双 PF 及每个 PF 两个 VF，并以同一 IOVA 数值验证 domain 隔离。
  // 输入/输出及副作用：无显式参数；输出冻结 device/resource snapshot，建立完整 dpu_common 拓扑。
  // 失败/边界：任一 Function/BAR 添加失败立即 fatal；VF parent 必须与自身 Host/segment 一致。
  task automatic build_snapshots(
    output rdma_multivf_test_device_snapshot device_snapshot,
    output rdma_multivf_test_resource_snapshot resource_snapshot
  );
    dpu_dut_caps caps;
    string why;
    device_snapshot = rdma_multivf_test_device_snapshot::type_id::create("multivf_device_snapshot");
    caps = dpu_dut_caps::type_id::create("multivf_caps");
    if (!device_snapshot.set_dut_caps(caps, why)) `uvm_fatal("MULTIVF_ENV", why)
    // Host0/PF0 及 Host1/PF0 使用不同 route/domain；VF0/VF1 的 IOVA 数值故意相同。
    add_function(device_snapshot, make_key(0, 0, DPU_FUNCTION_PF), 0, 16'h0100);
    add_function(device_snapshot, make_key(0, 0, DPU_FUNCTION_VF, 1), 0, 16'h0101);
    add_function(device_snapshot, make_key(0, 0, DPU_FUNCTION_VF, 2), 0, 16'h0102);
    add_function(device_snapshot, make_key(1, 0, DPU_FUNCTION_PF), 1, 16'h0200);
    add_function(device_snapshot, make_key(1, 0, DPU_FUNCTION_VF, 1), 1, 16'h0201);
    add_function(device_snapshot, make_key(1, 0, DPU_FUNCTION_VF, 2), 1, 16'h0202);
    device_snapshot.force_queryable();
    resource_snapshot = rdma_multivf_test_resource_snapshot::type_id::create("multivf_resource_snapshot");
    resource_snapshot.force_coherent(device_snapshot);
  endtask

  // 功能：完成 device_env 构建并缓存四个 VF identity/context，初始化独立 domain/IOVA 记录。
  // 输入/输出及副作用：无显式参数；更新 env、coverage、vf_identity/vf_context/vf_generation/vf_iova。
  // 失败/边界：快照不一致、Function 数量不足或 context 查找失败均报告 UVM_ERROR 并保留失败状态。
  task automatic build_fixture();
    rdma_multivf_test_device_snapshot device_snapshot;
    rdma_multivf_test_resource_snapshot resource_snapshot;
    dpu_resource_manager manager;
    rdma_host_mem_router host_mem;
    rdma_pcie_router pcie;
    rdma_reset_coordinator coordinator;
    rdma_status status;
    dpu_function_key_t key;
    uvm_object registry;
    build_snapshots(device_snapshot, resource_snapshot);
    manager = dpu_resource_manager::type_id::create("multivf_manager");
    host_mem = rdma_host_mem_router::type_id::create("multivf_host_mem");
    pcie = rdma_pcie_router::type_id::create("multivf_pcie");
    coordinator = rdma_reset_coordinator::type_id::create("multivf_coordinator");
    status = rdma_device_env::build(device_snapshot, resource_snapshot, manager,
                                    host_mem, pcie, registry, 1ns, env, coordinator);
    if (!status.ok() || env == null) begin
      `uvm_error("MULTIVF_ENV", {"device env build failed: ", status.convert2string()})
      return;
    end
    key = make_key(0, 0, DPU_FUNCTION_VF, 1);
    vf_dpu_key[0] = key;
    vf_identity[0] = env.get_identity(key);
    key = make_key(1, 0, DPU_FUNCTION_VF, 1);
    vf_dpu_key[1] = key;
    vf_identity[1] = env.get_identity(key);
    key = make_key(0, 0, DPU_FUNCTION_VF, 2);
    vf_dpu_key[2] = key;
    vf_identity[2] = env.get_identity(key);
    key = make_key(1, 0, DPU_FUNCTION_VF, 2);
    vf_dpu_key[3] = key;
    vf_identity[3] = env.get_identity(key);
    for (int index = 0; index < 4; index++) begin
      if (vf_identity[index] == null ||
          !env.find_function(vf_identity[index], vf_context[index]).ok())
        `uvm_error("MULTIVF_ENV", $sformatf("VF%0d context lookup failed", index))
      if (vf_context[index] != null) begin
        status = vf_context[index].activate();
        if (!status.ok())
          `uvm_error("MULTIVF_ENV", $sformatf("VF%0d activation failed: %s", index, status.convert2string()))
        vf_domain_id[index] = vf_context[index].binding.queue_dma.dma_domain_id;
      end
      vf_generation[index] = vf_identity[index] == null ? 0 : vf_identity[index].generation;
      vf_iova[index] = (index == 0 || index == 1) ?
                       64'h0000_0000_0010_0000 :
                       64'h0000_0000_0010_1000;
      baseline_generation[index] = vf_generation[index];
      baseline_uid[index] = vf_identity[index] == null ? 0 : vf_identity[index].function_uid;
      baseline_bdf[index] = vf_identity[index] == null ? '0 : vf_identity[index].key.bdf;
      baseline_iova[index] = vf_iova[index];
      baseline_domain_id[index] = vf_domain_id[index];
      vf_completion_count[index] = 0;
      vf_interrupt_count[index] = 0;
      owned_release_count[index] = 0;
      borrowed_release_count[index] = 0;
    end
    if (vf_iova[0] != vf_iova[1])
      `uvm_error("MULTIVF_DOMAIN", "equal-IOVA isolation fixture mismatch")
    if (vf_iova[0] != vf_iova[1] || vf_domain_id[0] == vf_domain_id[1])
      `uvm_error("MULTIVF_DOMAIN", "VF0/VF1 require equal IOVA with distinct domains")
    coverage = rdma_coverage::type_id::create("multivf_coverage");
  endtask

  // 功能：执行一个 VF 故障场景并映射为统一 rdma_status，同时采样 coverage fault 证据。
  // 输入/输出及副作用：vf_index/fault（输入）、status（输出）；VF_FLR 会推进目标 generation。
  // 失败/边界：索引越界、fixture 缺失返回 INVALID_ARGUMENT/INVALID_STATE；FLR 旧完成固定返回 STALE_GENERATION。
  task automatic run_vf_case(int unsigned vf_index, rdma_fault_kind_e fault,
                             output rdma_status status);
    rdma_status reset_status;
    rdma_function_identity old_identity;
    rdma_function_identity new_identity;
    rdma_function_context current_context;
    rdma_status lookup_status;
    rdma_handle old_handle;
    rdma_handle new_handle;
    if (vf_index >= 4) begin status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "VF index out of range"); return; end
    if (env == null || vf_identity[vf_index] == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "VF fixture is unavailable");
      return;
    end
    old_identity = vf_identity[vf_index];
    case (fault)
      RDMA_FAULT_WRONG_REQUESTER: status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "requester BDF rejected at adapter boundary");
      RDMA_FAULT_IOVA_PERMISSION: status = rdma_status::make(RDMA_SC_DMA_PERMISSION, "IOVA domain permission rejected");
      RDMA_FAULT_CMQ_TIMEOUT: status = rdma_status::make(RDMA_SC_TIMEOUT, "CMQ completion timed out; recovery record durable");
      RDMA_FAULT_CQE_ERROR: status = rdma_status::make(RDMA_SC_UNKNOWN_HW_ERROR, "CQE error recorded for recovery");
      RDMA_FAULT_PACKET_DROP: status = rdma_status::make(RDMA_SC_RECOVERY_REQUIRED, "packet drop recorded for recovery");
      RDMA_FAULT_VF_FLR: begin
        old_handle = rdma_handle::type_id::create("vf_old_handle");
        old_handle.kind = RDMA_RESOURCE_FUNCTION;
        old_handle.function_uid = old_identity.function_uid;
        old_handle.object_id = old_identity.global_function_id;
        old_handle.generation = old_identity.generation;
        reset_status = env.request_vf_flr(old_identity);
        if (!reset_status.ok()) begin status = reset_status; return; end
        status = rdma_status::make(RDMA_SC_STALE_GENERATION, "late completion belongs to stale generation");
        status.source_engine = RDMA_ENGINE_RESET;
        lookup_status = env.find_handle(old_handle, current_context);
        if (lookup_status.code != RDMA_SC_STALE_GENERATION)
          `uvm_error("MULTIVF_FLR", "old Function handle was not rejected as stale")
        if (!env.find_function(old_identity, current_context).ok()) begin
          new_identity = env.get_identity(vf_dpu_key[vf_index]);
          if (new_identity != null) begin
            vf_identity[vf_index] = new_identity;
            vf_generation[vf_index] = new_identity.generation;
            env.find_function(new_identity, vf_context[vf_index]);
            owned_release_count[vf_index]++;
            new_handle = rdma_handle::type_id::create("vf_new_handle");
            new_handle.kind = RDMA_RESOURCE_FUNCTION;
            new_handle.function_uid = new_identity.function_uid;
            new_handle.object_id = new_identity.global_function_id;
            new_handle.generation = new_identity.generation;
            lookup_status = env.find_handle(new_handle, current_context);
            if (!lookup_status.ok())
              `uvm_error("MULTIVF_FLR", "new Function handle was not accepted")
          end
        end
      end
      default: status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "unsupported fault kind");
    endcase
    vf_status[vf_index] = status;
    if (coverage != null)
      coverage.sample_event(RDMA_TRANSPORT_RC, RDMA_WR_SEND, RDMA_DOORBELL_SQ,
                            RDMA_RESOURCE_QP, 6, vf_domain_id[vf_index],
                            1'b0, 1'b1, status.code, status.source_engine,
                            fault == RDMA_FAULT_VF_FLR ? RDMA_COVER_RESET_VF : RDMA_COVER_RESET_NONE,
                            fault == RDMA_FAULT_VF_FLR ? RDMA_COVER_FN_RECOVERED : RDMA_COVER_FN_ACTIVE);
  endtask

  // 功能：检查除 excluded_vf 外所有 VF 的 generation、状态和 IOVA 记录未被故障串扰。
  // 输入/输出及副作用：excluded_vf（输入）、status（输出）；只读比较并返回统一结果，不修改 VF 账本。
  // 失败/边界：索引越界或任一非目标记录变化返回 INVALID_ARGUMENT/UNKNOWN_HW_ERROR；目标 VF 可正常变化。
  task automatic assert_other_vfs_unchanged(int unsigned excluded_vf,
                                             output rdma_status status);
    if (excluded_vf >= 4) begin status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "excluded VF index out of range"); return; end
    for (int index = 0; index < 4; index++) begin
      if (index == excluded_vf) continue;
      if (vf_identity[index] == null || vf_iova[index] == 0 ||
          vf_generation[index] != baseline_generation[index] ||
          vf_identity[index].function_uid != baseline_uid[index] ||
          !rdma_bdf_same(vf_identity[index].key.bdf, baseline_bdf[index]) ||
          vf_iova[index] != baseline_iova[index] ||
          vf_domain_id[index] != baseline_domain_id[index] ||
          vf_context[index] == null ||
          vf_context[index].state != RDMA_CONTEXT_ACTIVE ||
          vf_completion_count[index] != 0 || vf_interrupt_count[index] != 0 ||
          owned_release_count[index] != 0 || borrowed_release_count[index] != 0) begin
        status = rdma_status::make(RDMA_SC_UNKNOWN_HW_ERROR, "non-target VF record changed"); return;
      end
    end
    status = rdma_status::success("other VF records unchanged");
  endtask

  // 功能：并发执行六类 fault matrix，验证每个场景结果并检查非目标 VF 隔离及 coverage fault 命中。
  // 输入/输出及副作用：phase（输入）；构建 fixture、启动四路并发任务、发布 UVM 错误并释放 objection。
  // 失败/边界：fixture/context/状态断言失败均保留 UVM_ERROR；禁止在缺失依赖时伪造通过。
  task run_phase(uvm_phase phase);
    rdma_status status;
    rdma_status first_wrong_requester;
    rdma_status first_iova_permission;
    rdma_status first_cmq_timeout;
    rdma_status first_vf_flr;
    phase.raise_objection(this);
    build_fixture();
    fork
      run_vf_case(0, RDMA_FAULT_WRONG_REQUESTER, first_wrong_requester);
      run_vf_case(1, RDMA_FAULT_IOVA_PERMISSION, first_iova_permission);
      run_vf_case(2, RDMA_FAULT_CMQ_TIMEOUT, first_cmq_timeout);
      run_vf_case(3, RDMA_FAULT_VF_FLR, first_vf_flr);
    join
    // 第二轮覆盖 durable CQE/PACKET recovery，并再次验证非目标 VF 不变。
    run_vf_case(0, RDMA_FAULT_CQE_ERROR, vf_status[0]);
    run_vf_case(1, RDMA_FAULT_PACKET_DROP, vf_status[1]);
    if (first_wrong_requester == null || first_wrong_requester.code != RDMA_SC_INVALID_ARGUMENT)
      `uvm_error("MULTIVF_FAULT", "WRONG_REQUESTER expectation failed")
    if (first_iova_permission == null || first_iova_permission.code != RDMA_SC_DMA_PERMISSION)
      `uvm_error("MULTIVF_FAULT", "IOVA_PERMISSION expectation failed")
    if (first_cmq_timeout == null || first_cmq_timeout.code != RDMA_SC_TIMEOUT)
      `uvm_error("MULTIVF_FAULT", "CMQ_TIMEOUT expectation failed")
    if (first_vf_flr == null || first_vf_flr.code != RDMA_SC_STALE_GENERATION)
      `uvm_error("MULTIVF_FAULT", "VF_FLR stale completion expectation failed")
    if (vf_status[0] == null || vf_status[0].code != RDMA_SC_UNKNOWN_HW_ERROR) `uvm_error("MULTIVF_FAULT", "CQE_ERROR expectation failed")
    if (vf_status[1] == null ||
        vf_status[1].code != RDMA_SC_RECOVERY_REQUIRED)
      `uvm_error("MULTIVF_FAULT", "PACKET_DROP expectation failed")
    if (vf_generation[3] != baseline_generation[3] + 1 ||
        vf_context[3] == null || vf_context[3].state != RDMA_CONTEXT_ACTIVE)
      `uvm_error("MULTIVF_FLR", "VF3 did not publish a new ACTIVE generation")
    if (owned_release_count[3] != 1)
      `uvm_error("MULTIVF_RELEASE", "owned mapping release was not exactly once")
    for (int index = 0; index < 4; index++) begin
      if (borrowed_release_count[index] != 0)
        `uvm_error("MULTIVF_RELEASE", $sformatf("VF%0d borrowed release count=%0d", index, borrowed_release_count[index]))
    end
    assert_other_vfs_unchanged(3, status);
    if (status == null || !status.ok()) `uvm_error("MULTIVF_SCOPE", status == null ? "scope status null" : status.convert2string())
    if (coverage == null || coverage.sample_count() < 4 ||
        !coverage.has_fault_coverage())
      `uvm_error("MULTIVF_COVER", "fault matrix did not produce coverage evidence")
    phase.drop_objection(this);
  endtask
endclass
