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
`ifdef RDMA_HOST_MEM_TEST
  // 每个 Host 使用独立的真实 host_mem_manager；adapter 只保存该 manager
  // 的非拥有引用，router 负责按 route.host_topology_key 选择它。
  rdma_host_mem_external_pkg::host_mem_manager host_manager[2];
  rdma_host_mem_adapter host_adapter[2];
  rdma_host_mem_route_entry host_routes[$];
  rdma_dma_mapping vf_mapping[4];
  bit vf_release_complete[4];
`endif
  rdma_queue_data_engine_fixture cqe_fixture;
  `ifdef RDMA_NET_PACKET
  rdma_net_packet_adapter net_adapter[4];
  rdma_net_packet_queue_sink net_sink[4];
`endif
  rdma_mock_cmq_port cmq_port[4];
  rdma_status vf_status[4];
  // 只有所有 identity、真实 mapping、CQE、网络和 CMQ 依赖均完成后才置位；
  // 清理失败时保留 env/mapping 引用用于重试，但该位保持 0，禁止进入业务矩阵。
  bit fixture_ready;

  // 功能：构造多 VF recovery 测试组件，不创建外部依赖对象。
  // 输入/输出及副作用：name、parent（输入）；调用 super.new，初始化由 run_phase 完成。
  // 失败/边界：未完成 build_fixture 时所有 helper 都返回 INVALID_STATE，禁止伪造成功。
  function new(string name = "rdma_multivf_recovery_test",
               uvm_component parent = null);
    super.new(name, parent);
    fixture_ready = 1'b0;
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

  // 功能：复制 Function handle 作为 DMA request 的 owner authority 快照。
  // 输入/输出及副作用：source/label（输入）；返回 detached handle，不修改 source。
  // 失败/边界：source 为空或 clone/cast 失败返回 null，调用方必须拒绝后续 mapping。
  function automatic rdma_handle clone_function_handle(
    rdma_handle source,
    string label
  );
    rdma_handle result;
    uvm_object cloned_object;
    if (source == null)
      return null;
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(result, cloned_object)) begin
      `uvm_error("MULTIVF_HANDLE", {label, ": handle clone failed"})
      return null;
    end
    return result;
  endfunction

`ifdef RDMA_HOST_MEM_TEST
  // 功能：根据当前 VF identity/binding 构造完整 DMA request context，并从
  //       host-mem router 分配真实 backing mapping。
  // 输入/输出及副作用：vf_index（输入）、status（输出）；成功时更新
  //   vf_mapping[vf_index]，底层 host_mem_manager 的 allocation ledger 增加一项。
  // 失败/边界：identity/context/route/epoch 任一缺失时 fail-closed；失败路径
  //   不发布半成品 mapping，调用方必须处理非 OK 状态。
  task automatic allocate_vf_mapping(
    int unsigned vf_index,
    output rdma_status status
  );
    rdma_dma_request_context request_context;

    status = rdma_status::success();
    if (vf_index >= 4 || vf_identity[vf_index] == null ||
        vf_context[vf_index] == null || vf_context[vf_index].binding == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "VF DMA authority is unavailable");
      return;
    end
    request_context = rdma_dma_request_context::type_id::create(
      $sformatf("vf%0d_dma_request", vf_index));
    if (request_context == null || env == null || env.host_mem == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "VF DMA request/router is unavailable");
      return;
    end
    request_context.function_h = vf_context[vf_index].binding.make_handle();
    request_context.requester_bdf =
      vf_context[vf_index].binding.queue_dma.requester_bdf;
    request_context.pasid_valid = vf_context[vf_index].binding.queue_dma.pasid_valid;
    request_context.pasid = vf_context[vf_index].binding.queue_dma.pasid;
    request_context.dma_domain_valid =
      vf_context[vf_index].binding.queue_dma.dma_domain_valid;
    request_context.dma_domain_id =
      vf_context[vf_index].binding.queue_dma.dma_domain_id;
    request_context.route = vf_identity[vf_index].route_key();
    request_context.route_valid = 1'b1;
    request_context.reset_epoch = vf_identity[vf_index].reset_epoch;
    request_context.epoch_valid = 1'b1;
    request_context.owner_h = clone_function_handle(
      request_context.function_h, $sformatf("VF%0d DMA owner", vf_index));
    vf_mapping[vf_index] = null;
    status = env.host_mem.allocate(request_context, 4096, 4096,
                                   RDMA_DMA_BIDIRECTIONAL,
                                   vf_mapping[vf_index]);
    if (status == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "Host mapping allocation returned null status");
      return;
    end
    if (!status.ok())
      return;
    if (vf_mapping[vf_index] == null)
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "Host mapping allocation returned null mapping");
  endtask
`endif

  // 功能：给故障路径返回的状态补齐 Function、generation 和执行引擎证据，
  //       使多 Host/PF/VF 结果可在日志中唯一归属。
  // 输入/输出及副作用：vf_index/status/engine（输入）；就地更新 status 的
  //   evidence 字段，不改变错误码或底层资源；无资源所有权转移。
  // 失败/边界：索引越界或 status 为空时保持静默；调用方仍须单独检查主路径
  //   返回状态，不能把缺失证据当作成功。
  function automatic void stamp_fault_status(
    int unsigned vf_index,
    rdma_status status,
    rdma_engine_kind_e engine
  );
    if (status == null || vf_index >= 4 || vf_identity[vf_index] == null)
      return;
    status.source_engine = engine;
    status.function_uid = vf_identity[vf_index].function_uid;
    status.generation = vf_identity[vf_index].generation;
    status.resource_id = vf_identity[vf_index].global_function_id;
  endfunction

`ifdef RDMA_HOST_MEM_TEST
  // 功能：通过 router 的真实 release 接口释放一个 VF mapping，并读取
  //       opaque completion seal，验证 exactly-once 生命周期。
  // 输入/输出及副作用：vf_index（输入）、status（输出）；成功时释放 backing、
  //   更新 mapping state、清除本地 mapping 引用并写入 vf_release_complete，不修改其他 VF。
  // 失败/边界：mapping 为空表示没有可释放资源；重复 release 或 completion
  //   查询失败均返回原始错误，不使用人工计数掩盖泄漏。
  task automatic release_vf_mapping(
    int unsigned vf_index,
    output rdma_status status
  );
    bit release_done;

    status = rdma_status::success();
    release_done = 1'b0;
    if (vf_index >= 4) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "VF index out of range");
      return;
    end
    if (env == null || env.host_mem == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "Host-memory router is unavailable");
      return;
    end
    if (vf_mapping[vf_index] == null)
      return;
    status = env.host_mem.\release (vf_mapping[vf_index]);
    if (status == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "mapping release returned null status");
      return;
    end
    if (!status.ok())
      return;
    status = vf_mapping[vf_index].release_completion_status(release_done);
    if (status == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "mapping release completion query returned null");
      return;
    end
    if (!status.ok())
      return;
    if (!release_done) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "mapping release completion was not sealed");
      return;
    end
    vf_release_complete[vf_index] = 1'b1;
    // release 成功后清除本地非拥有引用，避免重入构建把已从 router ledger
    // 删除的旧对象再次当作 active mapping 尝试释放。
    vf_mapping[vf_index] = null;
  endtask

  // 功能：在 fixture 构建或单 VF 初始化中途失败时，按已有 mapping ledger
  //       逐项释放已取得的真实 Host-memory backing，避免半成品环境泄漏。
  // 输入/输出及副作用：status（输出）；调用 release_vf_mapping 并汇总首个失败状态，
  //   更新各 VF 的 release seal，不接管 manager 的生命周期。
  // 失败/边界：没有已分配 mapping 时返回 OK；任一 release 或 completion seal 失败时
  //   返回该错误并继续尝试其余 VF，调用方不得把环境标记为可用。
  task automatic release_partial_mappings(output rdma_status status);
    rdma_status release_status;

    status = rdma_status::success();
    for (int index = 0; index < 4; index++) begin
      if (vf_mapping[index] == null)
        continue;
      release_vf_mapping(index, release_status);
      if (release_status == null || !release_status.ok()) begin
        if (status.ok()) begin
          status = release_status == null ?
            rdma_status::make(RDMA_SC_INVALID_STATE,
                              "partial mapping release returned null status") :
            release_status;
        end
        `uvm_error("MULTIVF_RELEASE", $sformatf(
          "VF%0d partial mapping release failed: %s", index,
          release_status == null ? "null status" :
          release_status.convert2string()))
      end
    end
  endtask
`endif

`ifndef RDMA_HOST_MEM_TEST
  // 功能：在未启用真实 Host-memory 测试时提供一致的部分构建清理接口。
  // 输入/输出及副作用：status（输出）；返回成功，不访问不存在的 mapping 账本。
  // 失败/边界：该配置没有真实 backing 可释放；若调用方需要真实清理，必须启用
  //   RDMA_HOST_MEM_TEST，不能把此 no-op 当作泄漏证明。
  task automatic release_partial_mappings(output rdma_status status);
    status = rdma_status::success();
  endtask
`endif

  // 功能：放弃未完成的多 VF fixture，并以真实 release 结果决定是否丢弃环境引用。
  // 输入/输出及副作用：label（输入）、cleanup_status（输出）；先清理已登记 mapping，
  //   清理成功才清除 env/辅助对象，失败则保留所有权出口供下一次重试。
  // 失败/边界：cleanup 返回 null/非 OK 时 fixture_ready 保持 0 且不伪造可用环境；
  //   没有 mapping 时清理幂等成功，调用方仍须停止当前构建流程。
  task automatic abandon_fixture(
    string label,
    output rdma_status cleanup_status
  );
    fixture_ready = 1'b0;
    release_partial_mappings(cleanup_status);
    if (cleanup_status == null || !cleanup_status.ok()) begin
      `uvm_error("MULTIVF_CLEANUP", $sformatf(
        "%s: fixture cleanup failed: %s", label,
        cleanup_status == null ? "null status" :
        cleanup_status.convert2string()))
      return;
    end
    env = null;
    coverage = null;
    cqe_fixture = null;
  endtask

  // 功能：将 Function 及其 device/mailbox/MSI-X BAR 写入冻结前快照，形成可投影 binding。
  // 输入/输出及副作用：snapshot/key/segment/bdf（输入）；更新 snapshot 的 Function/BAR 表。
  // 失败/边界：snapshot 为空、重复 Function、重叠 BAR 或非法地址会 fatal；夹具地址不代表真实硬件所有权。
  task automatic add_function(
    rdma_multivf_test_device_snapshot snapshot,
    dpu_function_key_t key, int unsigned segment, int unsigned bdf
  );
    dpu_pcie_function_id_t pcie_id;
    dpu_bar_pair_lease_t bar;
    string why;
    if (snapshot == null) begin
      `uvm_fatal("MULTIVF_ENV", "add Function requires a non-null snapshot")
      return;
    end
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
  // 失败/边界：snapshot/caps/resource factory 为空或任一 Function/BAR 添加失败时 fail-closed；VF parent 必须与自身 Host/segment 一致。
  task automatic build_snapshots(
    output rdma_multivf_test_device_snapshot device_snapshot,
    output rdma_multivf_test_resource_snapshot resource_snapshot
  );
    dpu_dut_caps caps;
    string why;
    device_snapshot = rdma_multivf_test_device_snapshot::type_id::create("multivf_device_snapshot");
    caps = dpu_dut_caps::type_id::create("multivf_caps");
    if (device_snapshot == null || caps == null) begin
      `uvm_error("MULTIVF_ENV", "snapshot/capability factory returned null")
      device_snapshot = null;
      resource_snapshot = null;
      return;
    end
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
    if (resource_snapshot == null) begin
      `uvm_error("MULTIVF_ENV", "resource snapshot factory returned null")
      device_snapshot = null;
      return;
    end
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
    rdma_status lookup_status;
    dpu_function_key_t key;
    uvm_object registry;
    rdma_dma_request_context dma_request;
    rdma_host_mem_route_entry route_entry;

    // build_fixture 可能被回归 harness 重入；先释放上一次仍登记的 backing。
    // 清理失败时必须立即返回并保留 env/mapping 引用，下一次调用才能重试。
    fixture_ready = 1'b0;
    release_partial_mappings(status);
    if (status == null || !status.ok()) begin
      `uvm_error("MULTIVF_CLEANUP", status == null ?
                 "previous fixture cleanup returned null" :
                 status.convert2string())
      return;
    end
    env = null;
    coverage = null;
    cqe_fixture = null;
    for (int index = 0; index < 4; index++) begin
      vf_identity[index] = null;
      vf_context[index] = null;
      // VCS 对外部 dpu_common 的 struct 类型不接受整体 unsized `'0` 赋值；
      // 逐字段清零同时保留明确的合法默认 Function kind，避免类型缩窄。
      vf_dpu_key[index].host_id = 0;
      vf_dpu_key[index].pf_id = 0;
      vf_dpu_key[index].kind = DPU_FUNCTION_PF;
      vf_dpu_key[index].vf_id = 0;
      vf_generation[index] = 0;
      baseline_generation[index] = 0;
      baseline_uid[index] = 0;
      baseline_bdf[index] = '0;
      vf_iova[index] = 0;
      baseline_iova[index] = 0;
      vf_domain_id[index] = 0;
      baseline_domain_id[index] = 0;
      vf_completion_count[index] = 0;
      vf_interrupt_count[index] = 0;
      vf_status[index] = null;
`ifdef RDMA_HOST_MEM_TEST
      vf_mapping[index] = null;
      vf_release_complete[index] = 1'b0;
`endif
`ifdef RDMA_NET_PACKET
      net_adapter[index] = null;
      net_sink[index] = null;
`endif
      cmq_port[index] = null;
    end
    build_snapshots(device_snapshot, resource_snapshot);
    if (device_snapshot == null || resource_snapshot == null) begin
      `uvm_error("MULTIVF_ENV", "snapshot fixture construction failed")
      abandon_fixture("snapshot construction", status);
      return;
    end
    manager = dpu_resource_manager::type_id::create("multivf_manager");
    host_mem = rdma_host_mem_router::type_id::create("multivf_host_mem");
    pcie = rdma_pcie_router::type_id::create("multivf_pcie");
    coordinator = rdma_reset_coordinator::type_id::create("multivf_coordinator");
    if (manager == null || host_mem == null || pcie == null || coordinator == null) begin
      `uvm_error("MULTIVF_ENV", "device fixture dependency factory returned null")
      abandon_fixture("device dependency construction", status);
      return;
    end

`ifdef RDMA_HOST_MEM_TEST
    // 先发布 Host route，再交给 device_env 复用；两个 manager 使用不同
    // 的 backing 区间，但故意设置相同 IOVA 起点，以证明 route/domain 才
    // 是跨 Host 隔离的权威，而不是 IOVA 数值本身。
    host_routes.delete();
    for (int host_index = 0; host_index < 2; host_index++) begin
      host_manager[host_index] = rdma_host_mem_external_pkg::host_mem_manager::type_id::create(
        $sformatf("multivf_host_manager_%0d", host_index));
      if (host_manager[host_index] == null) begin
        `uvm_error("MULTIVF_HOST_MEM", $sformatf(
          "Host%0d manager factory returned null", host_index))
        abandon_fixture($sformatf("Host%0d manager construction", host_index), status);
        return;
      end
      host_manager[host_index].set_host_id(host_index);
      host_manager[host_index].init_region(
        host_index == 0 ? 64'h0000_0008_0000_0000 :
                          64'h0000_0009_0000_0000,
        host_index == 0 ? 64'h0000_0008_00ff_ffff :
                          64'h0000_0009_00ff_ffff);
      host_adapter[host_index] = rdma_host_mem_adapter::type_id::create(
        $sformatf("multivf_host_adapter_%0d", host_index));
      if (host_adapter[host_index] == null) begin
        `uvm_error("MULTIVF_HOST_MEM", $sformatf(
          "Host%0d adapter factory returned null", host_index))
        abandon_fixture($sformatf("Host%0d adapter construction", host_index), status);
        return;
      end
      host_adapter[host_index].mem = host_manager[host_index];
      host_adapter[host_index].iova_base = 64'h0000_0010_0000_0000;
      route_entry = rdma_host_mem_route_entry::type_id::create(
        $sformatf("multivf_host_route_%0d", host_index));
      if (route_entry == null) begin
        `uvm_error("MULTIVF_HOST_MEM", $sformatf(
          "Host%0d route factory returned null", host_index))
        abandon_fixture($sformatf("Host%0d route construction", host_index), status);
        return;
      end
      route_entry.host_topology_key = host_index;
      route_entry.manager = host_adapter[host_index];
      host_routes.push_back(route_entry);
    end
    status = host_mem.configure(host_routes);
    if (status == null || !status.ok()) begin
      `uvm_error("MULTIVF_HOST_MEM", status == null ?
                 "Host route configure returned null" : status.convert2string())
      abandon_fixture("Host route configure", status);
      return;
    end
`else
    // integration suite 不加载外部 host_mem；保留明确的错误边界，避免把
    // mock 或默认状态误报成真实 e2e。e2e 入口会通过上面的分支运行。
    `uvm_error("MULTIVF_HOST_MEM", "RDMA_HOST_MEM_TEST is required for real mappings")
    return;
`endif
    status = rdma_device_env::build(device_snapshot, resource_snapshot, manager,
                                    host_mem, pcie, registry, 1ns, env, coordinator);
    if (status == null || !status.ok() || env == null) begin
      `uvm_error("MULTIVF_ENV", status == null ?
                 "device env build returned null status" :
                 {"device env build failed: ", status.convert2string()})
      abandon_fixture("device env build", status);
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
    // 先完整验证四个 identity/context，再开始任何 Host-memory allocation；
    // 这样缺失 Function 不会留下前几个 VF 的半成品 backing。
    for (int index = 0; index < 4; index++) begin
      if (vf_identity[index] == null) begin
        `uvm_error("MULTIVF_ENV", $sformatf(
          "VF%0d identity lookup returned null", index))
        abandon_fixture($sformatf("VF%0d identity lookup", index), status);
        return;
      end
      lookup_status = env.find_function(vf_identity[index], vf_context[index]);
      if (lookup_status == null || !lookup_status.ok() ||
          vf_context[index] == null || vf_context[index].binding == null) begin
        `uvm_error("MULTIVF_ENV", $sformatf(
          "VF%0d context lookup/binding failed: %s", index,
          lookup_status == null ? "null status" :
          lookup_status.convert2string()))
        abandon_fixture($sformatf("VF%0d context lookup", index), status);
        return;
      end
    end

    for (int index = 0; index < 4; index++) begin
      if (vf_context[index] != null && vf_context[index].binding != null) begin
        status = vf_context[index].activate();
        if (status == null || !status.ok()) begin
          `uvm_error("MULTIVF_ENV", $sformatf(
            "VF%0d activation failed: %s", index,
            status == null ? "null status" : status.convert2string()))
          abandon_fixture($sformatf("VF%0d activation", index), status);
          return;
        end
        vf_domain_id[index] = vf_context[index].binding.queue_dma.dma_domain_id;
      end
      else begin
        `uvm_error("MULTIVF_ENV", $sformatf(
          "VF%0d context lacks binding or queue DMA authority", index))
        abandon_fixture($sformatf("VF%0d binding", index), status);
        return;
      end
      vf_generation[index] = vf_identity[index] == null ? 0 : vf_identity[index].generation;
      // 记录真实 adapter 返回的 IOVA；两个 Host adapter 具有相同起点，
      // 因而 VF0/VF1 的数值可能相同，隔离必须由完整 route/domain 保证。
      vf_iova[index] = 0;
      baseline_generation[index] = vf_generation[index];
      baseline_uid[index] = vf_identity[index] == null ? 0 : vf_identity[index].function_uid;
      baseline_bdf[index] = vf_identity[index] == null ? '0 : vf_identity[index].key.bdf;
      baseline_iova[index] = 0;
      baseline_domain_id[index] = vf_domain_id[index];
      vf_completion_count[index] = 0;
      vf_interrupt_count[index] = 0;
`ifdef RDMA_HOST_MEM_TEST
      vf_mapping[index] = null;
      vf_release_complete[index] = 1'b0;
`endif
`ifdef RDMA_HOST_MEM_TEST
      if (env.host_mem == null) begin
        `uvm_error("MULTIVF_HOST_MEM", "Host-memory router disappeared during allocation")
        abandon_fixture("Host-memory router lookup", status);
        return;
      end
      dma_request = rdma_dma_request_context::type_id::create(
        $sformatf("multivf_dma_request_%0d", index));
      if (dma_request == null) begin
        `uvm_error("MULTIVF_HOST_MEM", $sformatf(
          "VF%0d DMA request allocation returned null", index))
        abandon_fixture($sformatf("VF%0d DMA request construction", index), status);
        return;
      end
      dma_request.function_h = vf_context[index].binding.make_handle();
      dma_request.requester_bdf =
        vf_context[index].binding.queue_dma.requester_bdf;
      dma_request.pasid_valid = vf_context[index].binding.queue_dma.pasid_valid;
      dma_request.pasid = vf_context[index].binding.queue_dma.pasid;
      dma_request.dma_domain_valid =
        vf_context[index].binding.queue_dma.dma_domain_valid;
      dma_request.dma_domain_id =
        vf_context[index].binding.queue_dma.dma_domain_id;
      dma_request.route = vf_identity[index].route_key();
      dma_request.route_valid = 1'b1;
      dma_request.reset_epoch = vf_identity[index].reset_epoch;
      dma_request.epoch_valid = 1'b1;
      dma_request.owner_h = clone_function_handle(
        dma_request.function_h, $sformatf("VF%0d DMA owner", index));
      if (dma_request.function_h == null || dma_request.owner_h == null) begin
        `uvm_error("MULTIVF_HOST_MEM", $sformatf(
          "VF%0d DMA authority handle is incomplete", index))
        abandon_fixture($sformatf("VF%0d DMA authority", index), status);
        return;
      end
      status = host_mem.allocate(dma_request, 4096, 4096,
                                 RDMA_DMA_BIDIRECTIONAL, vf_mapping[index]);
      if (status == null || !status.ok() || vf_mapping[index] == null) begin
        `uvm_error("MULTIVF_HOST_MEM", $sformatf(
          "VF%0d host mapping allocation failed: %s", index,
          status == null ? "null status" : status.convert2string()))
        abandon_fixture($sformatf("VF%0d host mapping", index), status);
        return;
      end
      vf_iova[index] = vf_mapping[index].iova.value;
      baseline_iova[index] = vf_iova[index];
`else
      // 未启用真实 host-mem 时仅保留明确的 synthetic IOVA，不能冒充真实映射。
      vf_iova[index] = 64'h0000_0000_0010_0000;
      baseline_iova[index] = vf_iova[index];
`endif
    end
    if (vf_iova[0] != vf_iova[1] || vf_domain_id[0] == vf_domain_id[1]) begin
      `uvm_error("MULTIVF_DOMAIN",
                 "VF0/VF1 require equal IOVA with distinct domains")
      abandon_fixture("VF domain/IOVA isolation", status);
      return;
    end
    coverage = rdma_coverage::type_id::create("multivf_coverage");
    if (coverage == null) begin
      `uvm_error("MULTIVF_COVER", "coverage factory returned null")
      abandon_fixture("coverage construction", status);
      return;
    end

    // CQE 故障使用完整 queue-data engine 的读/解码/CI/release 路径；其
    // fixture 自带 mock memory，只用于产生硬件 CQE，不替代上述真实 VF
    // host-memory mappings。
    cqe_fixture = rdma_queue_data_engine_fixture::type_id::create(
      "multivf_cqe_fixture");
    if (cqe_fixture == null) begin
      `uvm_error("MULTIVF_CQE", "CQE fixture factory returned null")
      abandon_fixture("CQE fixture construction", status);
      return;
    end
    cqe_fixture.setup(status);
    if (status == null || !status.ok()) begin
      `uvm_error("MULTIVF_CQE", status == null ?
                 "CQE fixture setup returned null" : status.convert2string())
      abandon_fixture("CQE fixture setup", status);
      return;
    end

`ifdef RDMA_NET_PACKET
    for (int index = 0; index < 4; index++) begin
      net_sink[index] = rdma_net_packet_queue_sink::type_id::create(
        $sformatf("multivf_net_sink_%0d", index));
      net_adapter[index] = rdma_net_packet_adapter::type_id::create(
        $sformatf("multivf_net_adapter_%0d", index));
      if (net_sink[index] == null || net_adapter[index] == null) begin
        `uvm_error("MULTIVF_NET", $sformatf(
          "VF%0d net_packet factory returned null", index))
        abandon_fixture($sformatf("VF%0d net factory", index), status);
        return;
      end
      status = net_adapter[index].configure_sink(net_sink[index]);
      if (status == null || !status.ok()) begin
        `uvm_error("MULTIVF_NET", $sformatf(
          "VF%0d sink configure failed: %s", index,
          status == null ? "null status" : status.convert2string()))
        abandon_fixture($sformatf("VF%0d net sink", index), status);
        return;
      end
      status = net_adapter[index].configure_function(vf_identity[index]);
      if (status == null || !status.ok())
        `uvm_error("MULTIVF_NET", $sformatf(
          "VF%0d Function configure failed: %s", index,
          status == null ? "null status" : status.convert2string()))
      if (status == null || !status.ok()) begin
        abandon_fixture($sformatf("VF%0d net Function", index), status);
        return;
      end
    end
`endif
    for (int index = 0; index < 4; index++) begin
      cmq_port[index] = rdma_mock_cmq_port::type_id::create(
        $sformatf("multivf_cmq_%0d", index));
      if (cmq_port[index] == null) begin
        `uvm_error("MULTIVF_CMQ", $sformatf(
          "VF%0d CMQ port factory returned null", index))
        abandon_fixture($sformatf("VF%0d CMQ construction", index), status);
        return;
      end
    end
    fixture_ready = 1'b1;
  endtask

  // 功能：执行一个 VF 故障场景并映射为统一 rdma_status，同时采样 coverage fault 证据。
  // 输入/输出及副作用：vf_index/fault（输入）、status（输出）；VF_FLR 会推进目标 generation，
  //   并 drain/reallocate 目标 mapping；正常返回时更新 vf_status 并发布 coverage 样本。
  // 失败/边界：索引越界、fixture/authority 缺失或外部接口返回 null status 时返回
  //   INVALID_ARGUMENT/INVALID_STATE；FLR 旧完成固定返回 STALE_GENERATION，失败路径不解引用空状态。
  task automatic run_vf_case(int unsigned vf_index, rdma_fault_kind_e fault,
                             output rdma_status status);
    rdma_status reset_status;
    rdma_function_identity old_identity;
    rdma_function_identity new_identity;
    rdma_function_context current_context;
    rdma_status lookup_status;
    rdma_handle old_handle;
    rdma_handle new_handle;
    rdma_bdf_t saved_requester_bdf;
    rdma_bdf_t wrong_requester_bdf;
    byte read_data[];
    rdma_dma_permission_t requested_permissions;
    rdma_cmq_command_desc command;
    rdma_cmq_opcode_key opcode_key;
    rdma_cmq_sqe_model command_body;
    rdma_handle command_target;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completion;
    rdma_queue_completion_result queue_completion;
    rdma_status poll_status;
    rdma_hw_cqe_model cqe;
    rdma_queue_post_result posted;
    rdma_post_send_req send_request;
    rdma_host_mem_router host_mem;
    rdma_dma_mapping mapping;
    rdma_mock_cmq_port cmq;
    rdma_queue_data_engine engine;
`ifdef RDMA_NET_PACKET
    rdma_packet packet;
    rdma_net_fault packet_fault;
    int unsigned dropped_before;
`endif
    if (vf_index >= 4) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "VF index out of range");
      return;
    end
    if (env == null || vf_identity[vf_index] == null ||
        vf_context[vf_index] == null || vf_context[vf_index].binding == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "VF fixture or Function authority is unavailable");
      return;
    end
    old_identity = vf_identity[vf_index];
    case (fault)
      RDMA_FAULT_WRONG_REQUESTER: begin
`ifdef RDMA_HOST_MEM_TEST
        // 通过篡改 public requester BDF 驱动 router 的 authority 校验；真实
        // 访问必须在到达 host_mem_manager 前被拒绝，随后恢复原字段以便
        // 释放仍能使用原始 opaque allocation identity。
        host_mem = env.host_mem;
        mapping = vf_mapping[vf_index];
        if (host_mem == null || mapping == null) begin
          status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                     "VF requester fault lacks DMA mapping");
        end
        else if (vf_identity[(vf_index + 1) % 4] == null) begin
          status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                     "VF requester fault lacks peer identity");
        end
        else begin
          saved_requester_bdf = mapping.requester_bdf;
          wrong_requester_bdf = vf_identity[(vf_index + 1) % 4].key.bdf;
          mapping.requester_bdf = wrong_requester_bdf;
          status = host_mem.read(mapping, 0, 1, read_data);
          mapping.requester_bdf = saved_requester_bdf;
        end
`else
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "real host-memory adapter is unavailable");
`endif
        stamp_fault_status(vf_index, status, RDMA_ENGINE_DMA);
      end
      RDMA_FAULT_IOVA_PERMISSION: begin
`ifdef RDMA_HOST_MEM_TEST
        // check_access 复用 mapping 的 Function/PASID/domain/范围 authority，
        // 只收紧本次请求的 device-write 权限，因而错误来自真实权限判定。
        mapping = vf_mapping[vf_index];
        if (mapping == null || vf_context[vf_index].binding == null) begin
          status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                     "VF permission fault lacks DMA authority");
        end
        else begin
          requested_permissions = mapping.permissions;
          requested_permissions.device_write = 1'b0;
          status = mapping.check_access(
            vf_context[vf_index].binding.make_handle(),
            mapping.requester_bdf,
            mapping.pasid_valid, mapping.pasid,
            mapping.dma_domain_valid,
            mapping.dma_domain_id, mapping.iova, 1,
            RDMA_DMA_DEVICE_WRITE, requested_permissions);
        end
`else
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "real host-memory adapter is unavailable");
`endif
        stamp_fault_status(vf_index, status, RDMA_ENGINE_DMA);
      end
      RDMA_FAULT_CMQ_TIMEOUT: begin
        // CMQ mock 只替代外部硬件完成返回；command/ticket/completion 仍经
        // 完整 execute() 生命周期，timeout 结果不能由测试直接合成。
        command = rdma_cmq_command_desc::type_id::create(
          $sformatf("vf%0d_timeout_command", vf_index));
        opcode_key = rdma_cmq_opcode_key::type_id::create(
          $sformatf("vf%0d_timeout_opcode", vf_index));
        command_body = rdma_cmq_sqe_model::type_id::create(
          $sformatf("vf%0d_timeout_body", vf_index));
        command_target = rdma_handle::type_id::create(
          $sformatf("vf%0d_timeout_target", vf_index));
        cmq = cmq_port[vf_index];
        if (command == null || opcode_key == null || command_body == null ||
            command_target == null || cmq == null) begin
          status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                     "VF CMQ fault lacks command objects/port");
        end
        else begin
          command.function_h = vf_context[vf_index].binding.make_handle();
          opcode_key.profile_name = "multivf_cmq";
          opcode_key.opcode = RDMA_OP_KEY_ALLOC;
          opcode_key.variant = "timeout";
          command.opcode_key = opcode_key;
          command_body.opcode = RDMA_CMQ_QUERY;
          command_body.command_id = 64'h100 + vf_index;
          command_body.function_h = vf_context[vf_index].binding.make_handle();
          command_target.kind = RDMA_RESOURCE_CMQ;
          command_target.function_uid = vf_identity[vf_index].function_uid;
          command_target.object_id = 32'hffff_0001;
          command_target.generation = vf_identity[vf_index].generation;
          command_body.target_h = command_target;
          command_body.flags = vf_index;
          command.body = command_body;
          command.timeout = 1us;
          cmq.timeout_opcode(RDMA_OP_KEY_ALLOC);
          cmq.execute(command, ticket, completion, status);
          if (status == null || status.code != RDMA_SC_TIMEOUT ||
              ticket == null || completion == null || completion.status == null ||
              completion.status.code != RDMA_SC_TIMEOUT)
            `uvm_error("MULTIVF_CMQ", $sformatf(
              "VF%0d timeout lacked ticket/completion evidence", vf_index))
        end
        stamp_fault_status(vf_index, status, RDMA_ENGINE_CMQ);
      end
      RDMA_FAULT_CQE_ERROR: begin
        // 设备先把错误 ecode 编码写入 CQ backing，engine 再执行 read →
        // decode → completion_status_from_ecode；测试不直接覆盖最终状态。
        engine = cqe_fixture == null ? null : cqe_fixture.engine;
        if (engine == null || cqe_fixture.qp == null ||
            cqe_fixture.qp.handle == null || cqe_fixture.cq == null ||
            cqe_fixture.cq.handle == null) begin
          status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                     "CQE fixture engine/queue handles are unavailable");
        end
        else begin
          send_request = cqe_fixture.make_send(
            64'hc0e0_0000_0000_0000 + vf_index);
          if (send_request == null) begin
            status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                       "CQE send request factory returned null");
          end
          else
            engine.post_send(send_request, posted, status);
          if (status != null && status.ok() && posted != null) begin
            cqe = rdma_hw_cqe_model::type_id::create(
              $sformatf("vf%0d_error_cqe", vf_index));
            if (cqe == null) begin
              status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                         "CQE model factory returned null");
            end
            else begin
              cqe.qp_h = clone_function_handle(cqe_fixture.qp.handle,
                                               "multivf CQE QP");
              cqe.qpn = cqe_fixture.qp.local_qp_id;
              cqe.wqe_index = posted.index;
              cqe.wqe_wrap = posted.wrap;
              cqe.rq_cqe = 1'b0;
              cqe.polarity = 1'b1;
              cqe.packet_opcode = 8'h01;
              cqe.ecode = RDMA_ECODE_EC_RCE_CQ_FULL;
              cqe.payload_len = 0;
              cqe.status = rdma_status::success();
              status = cqe_fixture.write_cq_entry(0, cqe);
            end
            if (status != null && status.ok()) begin
              queue_completion = null;
              poll_status = null;
              engine.poll_cqe(cqe_fixture.cq.handle, 0, queue_completion,
                              poll_status);
              if (poll_status == null) begin
                status = rdma_status::make(
                  RDMA_SC_INVALID_STATE,
                  "CQE poll returned null transaction status");
                `uvm_error("MULTIVF_CQE", $sformatf(
                  "VF%0d CQE poll status is null", vf_index))
              end
              else if (!poll_status.ok()) begin
                status = poll_status;
                `uvm_error("MULTIVF_CQE", $sformatf(
                  "VF%0d CQE poll transaction failed: %s", vf_index,
                  poll_status.convert2string()))
              end
              else if (queue_completion == null ||
                       queue_completion.completion_status == null) begin
                status = rdma_status::make(
                  RDMA_SC_INVALID_STATE,
                  "CQE poll omitted hardware completion status");
                `uvm_error("MULTIVF_CQE", $sformatf(
                  "VF%0d CQE completion evidence is missing", vf_index))
              end
              else begin
                // poll_cqe 的顶层 status 只表示 read/decode/CI/WQE-release
                // 事务完成；硬件 ecode 的业务结果位于 completion_status。
                status = rdma_clone_status_value(
                  queue_completion.completion_status);
                if (status == null) begin
                  status = rdma_status::make(
                    RDMA_SC_INVALID_STATE,
                    "CQE completion status clone returned null");
                  `uvm_error("MULTIVF_CQE", $sformatf(
                    "VF%0d CQE completion clone failed", vf_index))
                end
                else if (status.code != RDMA_SC_QUEUE_FULL)
                  `uvm_error("MULTIVF_CQE", $sformatf(
                    "VF%0d unexpected CQE completion code: %s", vf_index,
                    status.convert2string()))
              end
            end
          end
        end
        stamp_fault_status(vf_index, status, RDMA_ENGINE_CQ);
      end
      RDMA_FAULT_PACKET_DROP: begin
`ifdef RDMA_NET_PACKET
        // net_packet adapter 自身消费一次性 fault 并返回 drop 统计；只有
        // 观察到真实 dropped_count 增长后，测试层才将其归类为 recovery。
        packet = rdma_packet::type_id::create(
          $sformatf("vf%0d_drop_packet", vf_index));
        packet_fault = rdma_net_fault::type_id::create(
          $sformatf("vf%0d_drop_fault", vf_index));
        if (packet == null || packet_fault == null || net_adapter[vf_index] == null) begin
          status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                     "packet fault objects/adapter are unavailable");
        end
        else begin
          packet.transport = RDMA_TRANSPORT_RC;
          packet.opcode = RDMA_NET_SEND;
          packet.destination_qpn = 24'h100 + vf_index;
          packet.source_qpn = 24'h200 + vf_index;
          packet.psn = vf_index;
          packet.payload.push_back(8'h5a);
          packet.payload.push_back(byte'(vf_index));
          packet_fault.kind = RDMA_FAULT_PACKET_DROP;
          packet_fault.drop_packet = 1'b1;
          dropped_before = net_adapter[vf_index].dropped_count;
          status = net_adapter[vf_index].inject_fault(packet_fault);
          if (status != null && status.ok())
            net_adapter[vf_index].send_packet(packet, status);
          if (status != null && status.ok() &&
              net_adapter[vf_index].dropped_count == dropped_before + 1)
            status = rdma_status::make(
              RDMA_SC_RECOVERY_REQUIRED,
              "packet drop observed by net_packet adapter");
        end
`else
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "net_packet adapter is unavailable");
`endif
        stamp_fault_status(vf_index, status, RDMA_ENGINE_NETWORK);
      end
      RDMA_FAULT_VF_FLR: begin
        old_handle = rdma_handle::type_id::create("vf_old_handle");
        if (old_handle == null) begin
          status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                     "VF FLR old handle factory returned null");
          return;
        end
        old_handle.kind = RDMA_RESOURCE_FUNCTION;
        old_handle.function_uid = old_identity.function_uid;
        old_handle.object_id = old_identity.global_function_id;
        old_handle.generation = old_identity.generation;
        reset_status = env.request_vf_flr(old_identity);
        if (reset_status == null || !reset_status.ok()) begin
          status = reset_status == null ?
            rdma_status::make(RDMA_SC_INVALID_STATE,
                              "VF FLR request returned null status") :
            reset_status;
          return;
        end
`ifdef RDMA_HOST_MEM_TEST
        // FLR 先 drain 旧 generation 的真实 backing；release 允许旧 epoch
        // 通过，但仍要求完整旧 route/owner authority，随后查询 opaque seal。
        release_vf_mapping(vf_index, reset_status);
        if (reset_status == null || !reset_status.ok()) begin
          status = reset_status == null ?
            rdma_status::make(RDMA_SC_INVALID_STATE,
                              "VF FLR mapping drain returned null status") :
            reset_status;
          return;
        end
`endif
        status = rdma_status::make(RDMA_SC_STALE_GENERATION, "late completion belongs to stale generation");
        status.source_engine = RDMA_ENGINE_RESET;
        lookup_status = env.find_handle(old_handle, current_context);
        if (lookup_status == null ||
            lookup_status.code != RDMA_SC_STALE_GENERATION)
          `uvm_error("MULTIVF_FLR", "old Function handle was not rejected as stale")
        lookup_status = env.find_function(old_identity, current_context);
        if (lookup_status == null || !lookup_status.ok()) begin
          new_identity = env.get_identity(vf_dpu_key[vf_index]);
          if (new_identity != null) begin
            vf_identity[vf_index] = new_identity;
            vf_generation[vf_index] = new_identity.generation;
            lookup_status = env.find_function(new_identity, vf_context[vf_index]);
            if (lookup_status == null || !lookup_status.ok()) begin
              status = lookup_status == null ?
                rdma_status::make(RDMA_SC_INVALID_STATE,
                                  "new VF context lookup returned null status") :
                lookup_status;
              return;
            end
`ifdef RDMA_HOST_MEM_TEST
            allocate_vf_mapping(vf_index, reset_status);
            if (reset_status == null || !reset_status.ok() ||
                vf_mapping[vf_index] == null) begin
              status = reset_status == null ?
                rdma_status::make(RDMA_SC_INVALID_STATE,
                                  "VF FLR mapping re-allocation returned null status") :
                (!reset_status.ok() ? reset_status :
                 rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "VF FLR mapping re-allocation returned null mapping"));
              return;
            end
            vf_iova[vf_index] = vf_mapping[vf_index].iova.value;
`endif
            new_handle = rdma_handle::type_id::create("vf_new_handle");
            if (new_handle == null) begin
              status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                         "VF FLR new handle factory returned null");
              return;
            end
            new_handle.kind = RDMA_RESOURCE_FUNCTION;
            new_handle.function_uid = new_identity.function_uid;
            new_handle.object_id = new_identity.global_function_id;
            new_handle.generation = new_identity.generation;
            lookup_status = env.find_handle(new_handle, current_context);
            if (lookup_status == null || !lookup_status.ok())
              `uvm_error("MULTIVF_FLR", "new Function handle was not accepted")
          end
        end
        stamp_fault_status(vf_index, status, RDMA_ENGINE_RESET);
      end
      default: status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "unsupported fault kind");
    endcase
    if (status == null)
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "VF fault case returned null status");
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
  // 失败/边界：索引越界、identity/context/mapping 为空或任一非目标记录变化返回
  //   INVALID_ARGUMENT/UNKNOWN_HW_ERROR；该检查必须在统一 release 前调用，目标 VF 可正常变化。
  task automatic assert_other_vfs_unchanged(int unsigned excluded_vf,
                                             output rdma_status status);
    status = rdma_status::success();
    if (excluded_vf >= 4) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "excluded VF index out of range");
      return;
    end
    for (int index = 0; index < 4; index++) begin
      if (index == excluded_vf) continue;
      if (vf_identity[index] == null || vf_context[index] == null) begin
        status = rdma_status::make(RDMA_SC_UNKNOWN_HW_ERROR,
                                   "non-target VF identity/context is null");
        return;
      end
      if (vf_iova[index] == 0 ||
          vf_generation[index] != baseline_generation[index] ||
          vf_identity[index].function_uid != baseline_uid[index] ||
          !rdma_bdf_same(vf_identity[index].key.bdf, baseline_bdf[index]) ||
          vf_iova[index] != baseline_iova[index] ||
          vf_domain_id[index] != baseline_domain_id[index] ||
          vf_context[index].state != RDMA_CONTEXT_ACTIVE ||
          vf_completion_count[index] != 0 || vf_interrupt_count[index] != 0
          ) begin
        status = rdma_status::make(RDMA_SC_UNKNOWN_HW_ERROR,
                                   "non-target VF record changed");
        return;
      end
`ifdef RDMA_HOST_MEM_TEST
      if (vf_mapping[index] == null) begin
        status = rdma_status::make(RDMA_SC_UNKNOWN_HW_ERROR,
                                   "non-target VF mapping is null");
        return;
      end
      if (vf_mapping[index].state != RDMA_MAPPING_ACTIVE ||
          vf_release_complete[index]) begin
        status = rdma_status::make(RDMA_SC_UNKNOWN_HW_ERROR,
                                   "non-target VF mapping lifecycle changed");
        return;
      end
`endif
    end
    status = rdma_status::success("other VF records unchanged");
  endtask

  // 功能：并发执行六类 fault matrix，验证每个场景结果，并在 mapping release 前检查非目标 VF 隔离及 coverage fault 命中。
  // 输入/输出及副作用：phase（输入）；构建 fixture、启动四路并发任务、更新隔离/释放账本、发布 UVM 错误并释放 objection。
  // 失败/边界：外部依赖缺失时 fail-closed 并先释放 objection；fixture/context/状态断言失败均保留 UVM_ERROR，禁止把清理后的 RELEASED 状态误判为串扰。
  task run_phase(uvm_phase phase);
    rdma_status status;
    rdma_status isolation_status;
    rdma_status first_wrong_requester;
    rdma_status first_iova_permission;
    rdma_status first_cmq_timeout;
    rdma_status first_vf_flr;
    int unsigned leak_count;
    phase.raise_objection(this);
    build_fixture();
    // build_fixture 在缺少真实外部依赖时 fail-closed；此时不能继续访问
    // 未初始化的 Host adapter/coverage，否则会把根因掩盖成空句柄错误。
    if (!fixture_ready || env == null) begin
      // cleanup 失败时 env 仍被保留为下一次重试的 authority 出口；本轮
      // 无论清理是否成功都必须停止，不得把半初始化 fixture 当成可运行环境。
      if (env != null) begin
        release_partial_mappings(status);
        if (status == null || !status.ok())
          `uvm_error("MULTIVF_CLEANUP", status == null ?
                     "failed fixture cleanup returned null" :
                     status.convert2string())
        else
          env = null;
      end
      `uvm_error("MULTIVF_ENV", "multi-VF fixture is unavailable")
      phase.drop_objection(this);
      return;
    end
    fork
      run_vf_case(0, RDMA_FAULT_WRONG_REQUESTER, first_wrong_requester);
      run_vf_case(1, RDMA_FAULT_IOVA_PERMISSION, first_iova_permission);
      run_vf_case(2, RDMA_FAULT_CMQ_TIMEOUT, first_cmq_timeout);
      run_vf_case(3, RDMA_FAULT_VF_FLR, first_vf_flr);
    join
    // 第二轮覆盖 durable CQE/PACKET recovery，并再次验证非目标 VF 不变。
    run_vf_case(0, RDMA_FAULT_CQE_ERROR, vf_status[0]);
    run_vf_case(1, RDMA_FAULT_PACKET_DROP, vf_status[1]);
    // 隔离快照必须在统一 mapping release 之前采集；release 会把每个
    // 非目标 mapping 置为 RELEASED，不能把生命周期收尾误判为串扰。
    assert_other_vfs_unchanged(3, isolation_status);
    if (isolation_status == null || !isolation_status.ok())
      `uvm_error("MULTIVF_SCOPE", isolation_status == null ?
                 "scope status null" : isolation_status.convert2string())
    if (first_wrong_requester == null || first_wrong_requester.code != RDMA_SC_DMA_TRANSLATION)
      `uvm_error("MULTIVF_FAULT", "WRONG_REQUESTER expectation failed")
    if (first_iova_permission == null || first_iova_permission.code != RDMA_SC_DMA_PERMISSION)
      `uvm_error("MULTIVF_FAULT", "IOVA_PERMISSION expectation failed")
    if (first_cmq_timeout == null || first_cmq_timeout.code != RDMA_SC_TIMEOUT)
      `uvm_error("MULTIVF_FAULT", "CMQ_TIMEOUT expectation failed")
    if (first_vf_flr == null || first_vf_flr.code != RDMA_SC_STALE_GENERATION)
      `uvm_error("MULTIVF_FAULT", "VF_FLR stale completion expectation failed")
    if (vf_status[0] == null || vf_status[0].code != RDMA_SC_QUEUE_FULL)
      `uvm_error("MULTIVF_FAULT", "CQE_ERROR expectation failed")
    if (vf_status[1] == null ||
        vf_status[1].code != RDMA_SC_RECOVERY_REQUIRED)
      `uvm_error("MULTIVF_FAULT", "PACKET_DROP expectation failed")
    if (vf_generation[3] != baseline_generation[3] + 1 ||
        vf_context[3] == null || vf_context[3].state != RDMA_CONTEXT_ACTIVE)
      `uvm_error("MULTIVF_FLR", "VF3 did not publish a new ACTIVE generation")
`ifdef RDMA_HOST_MEM_TEST
    if (!vf_release_complete[3] || vf_mapping[3] == null ||
        vf_mapping[3].state != RDMA_MAPPING_ACTIVE)
      `uvm_error("MULTIVF_RELEASE", "VF3 mapping release/reallocation evidence is incomplete")
    for (int index = 0; index < 4; index++) begin
      release_vf_mapping(index, status);
      if (status == null || !status.ok())
        `uvm_error("MULTIVF_RELEASE", $sformatf(
          "VF%0d mapping release failed: %s", index,
          status == null ? "null status" : status.convert2string()))
      if (!vf_release_complete[index])
        `uvm_error("MULTIVF_RELEASE", $sformatf(
          "VF%0d release completion seal is missing", index))
    end
    for (int host_index = 0; host_index < 2; host_index++) begin
      if (host_adapter[host_index] == null) begin
        `uvm_error("MULTIVF_RELEASE", $sformatf(
          "Host%0d adapter is null during leak check", host_index))
        continue;
      end
      host_adapter[host_index].check_leaks(leak_count);
      if (leak_count != 0)
        `uvm_error("MULTIVF_RELEASE", $sformatf(
          "Host%0d leaked %0d allocations", host_index, leak_count))
    end
`endif
    if (coverage == null || coverage.sample_count() < 4 ||
        !coverage.has_fault_coverage())
      `uvm_error("MULTIVF_COVER", "fault matrix did not produce coverage evidence")
    fixture_ready = 1'b0;
    phase.drop_objection(this);
  endtask
endclass
