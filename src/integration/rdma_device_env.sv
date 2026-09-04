// 目录：src/integration/，位于 dpu_common 适配层的设备级组合入口。
// 职责：校验冻结的 dpu_common 设备/资源快照，枚举全部 PF/VF，并为每个
//       Function 建立 RDMA identity 与统一 reset coordinator 注册表。
// 依赖：rdma_dpu_identity_adapter、rdma_host_mem_router、rdma_pcie_router，
//       以及 dpu_common 的 dpu_device_snapshot/resource_snapshot。
// 所有权与生命周期：外部快照和 router 由调用方拥有；本对象保存非拥有快照引用，
//       identity ledger 由本对象创建并在环境生命周期内持有，get_identity() 返回副本。

// 复位范围只在 device env 内部使用，避免把 dpu_common 的 reset 枚举和 RDMA
// context 状态耦合；coordinator 仍是 epoch 数值的唯一发布者。
typedef enum bit [1:0] {
  RDMA_ENV_RESET_VF = 2'd0,
  RDMA_ENV_RESET_PF = 2'd1,
  RDMA_ENV_RESET_HOST = 2'd2,
  RDMA_ENV_RESET_DEVICE = 2'd3
} rdma_device_reset_scope_e;

class rdma_device_env extends uvm_object;
  `uvm_object_utils(rdma_device_env)
  dpu_device_snapshot device_snapshot;
  dpu_resource_snapshot resources;
  dpu_resource_manager resource_manager;
  rdma_host_mem_router host_mem;
  rdma_pcie_router pcie;
  rdma_reset_coordinator reset_coordinator;
  // 按 dpu_common 的完整 Function key 保存身份副本，供各 Function
  // context 和 reset coordinator 共享同一份 immutable authority。
  protected rdma_function_identity m_identities[string];
  // Context 索引与 identity ledger 使用同一完整 Function key；value 由 env
  // 创建并持有，外部只通过 find_*() 获取非拥有引用，避免调用方绕过 scope 校验。
  protected rdma_function_context m_contexts[string];
  // 功能：构造空的设备环境对象并初始化 UVM 对象名称；实际依赖绑定由 build() 完成。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：构造过程不分配 Host-memory、PCIe endpoint 或 manager 资源；空 name 也必须得到可配置对象。
  function new(string name="rdma_device_env");
    super.new(name);
  endfunction

  // 功能：以冻结 dpu_common 快照为权威，原子地组装 device env、identity ledger
  //       和 reset coordinator；失败时返回错误状态且不返回半初始化环境。
  // 输入/输出及副作用：冻结快照和 manager/router 以非拥有引用写入候选 env；每个 Function
  //   由 adapter 投影 identity/binding、由 context 克隆 identity 并登记共享 coordinator；
  //   result_env 仅在全部 Function 成功后发布，registry/build_timeout 仅为兼容参数。
  // 失败/边界：依赖为空、快照未冻结/不一致或任一 Function 投影/构造失败时返回错误且
  //   result_env 保持 null；候选对象不会对外发布。
  static function rdma_status build(
    dpu_device_snapshot source_device_snapshot,
    dpu_resource_snapshot source_resources,
    dpu_resource_manager source_resource_manager,
    rdma_host_mem_router source_host_mem,
    rdma_pcie_router source_pcie,
    uvm_object registry,
    time build_timeout,
    output rdma_device_env result_env,
    rdma_reset_coordinator coordinator = null
  );
    dpu_function_key_t keys[$];
    rdma_function_identity identity;
    rdma_function_binding binding;
    rdma_function_context context;
    rdma_reset_coordinator selected_coordinator;
    rdma_device_env candidate_env;
    string key_name;
    rdma_status status;

    result_env = null;
    if (source_device_snapshot == null || source_resources == null ||
        source_resource_manager == null || source_host_mem == null ||
        source_pcie == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "Device environment dependency is null");
    if (!source_device_snapshot.is_frozen() || !source_resources.is_frozen())
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "Device snapshots must be frozen");
    if (!source_resources.references_device_snapshot(source_device_snapshot))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "Device/resource snapshots are incoherent");

    selected_coordinator = coordinator;
    if (selected_coordinator == null)
      selected_coordinator = rdma_reset_coordinator::type_id::create(
        "device_env_reset_coordinator");
    selected_coordinator.attach_host_router(source_host_mem);
    candidate_env = rdma_device_env::type_id::create("device_env");
    candidate_env.device_snapshot = source_device_snapshot;
    candidate_env.resources = source_resources;
    candidate_env.resource_manager = source_resource_manager;
    candidate_env.host_mem = source_host_mem;
    candidate_env.pcie = source_pcie;
    candidate_env.reset_coordinator = selected_coordinator;
    candidate_env.m_identities.delete();
    candidate_env.m_contexts.delete();

    source_device_snapshot.list_functions(keys);
    foreach (keys[index]) begin
      identity = null;
      binding = null;
      status = rdma_dpu_identity_adapter::from_snapshot(
        source_device_snapshot, source_resources, keys[index], identity, binding);
      if (!status.ok() || identity == null || binding == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
          {"Function identity/binding projection failed: ", status.message});
      // dpu_common key 名称含 PF ID，而 RDMA identity 用 BDF 作为 PF 身份；
      // 两套字符串不能互相拼接，故分别维护 dpu identity ledger 和 RDMA context index。
      key_name = dpu_function_key_name(keys[index]);
      candidate_env.m_identities[key_name] = identity;
      key_name = identity_key_name(identity.key);
      context = null;
      status = rdma_function_context::build_shared(
        identity, source_resources, source_host_mem, source_pcie,
        selected_coordinator, binding, registry, build_timeout, context);
      if (!status.ok() || context == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
          {"Function context build failed: ", status.message});
      // Device env 是 reset coordinator 的共享所有者；返回后再次显式绑定并登记，
      // 使构建契约即使在不同模拟器的 class 参数传递实现下也保持一致。
      context.reset_coordinator = selected_coordinator;
      selected_coordinator.attach_host_router(source_host_mem);
      selected_coordinator.register_function(identity);
      candidate_env.m_contexts[key_name] = context;
    end
    // registry/timeout 保留在 API 中用于上层兼容；Device env 只保存已经
    // 校验过的 dpu_common snapshot 和唯一 reset coordinator。
    result_env = candidate_env;
    return rdma_status::success();
  endfunction

  // 功能：按 dpu_common 完整 Function key 查询身份，并返回与内部 ledger 解耦的克隆。
  // 输入/输出及副作用：key（输入）；按 dpu_function_key_name 查找 ledger，并返回 identity 的
  //   clone；读取不修改 ledger，也不转移快照所有权。
  // 失败/边界：key 未枚举或 clone/cast 失败时返回 null；调用方不得把 null 当作有效身份。
  function rdma_function_identity get_identity(dpu_function_key_t key);
    rdma_function_identity copy;
    uvm_object cloned_object;
    string key_name;
    key_name = dpu_function_key_name(key);
    if (!m_identities.exists(key_name))
      return null;
    cloned_object = m_identities[key_name].clone();
    if (cloned_object == null || !$cast(copy, cloned_object))
      return null;
    return copy;
  endfunction

  // 功能：将 RDMA identity 的完整 Host/root/VF/BDF 路由编码为内部索引键。
  // 输入/输出及副作用：identity_key（输入）；只读编码 Host/root/function-kind/VF/BDF 为稳定
  //   字符串键，不包含 generation 或对象句柄。
  // 失败/边界：identity_key 的字段始终是 packed 值；函数不分配资源，缺省字段按 0 编码。
  protected static function string identity_key_name(
    rdma_function_key_t identity_key
  );
    return $sformatf("%0d:%0d:%0d:%0d:%0d:%0d:%0d:%0d",
                     identity_key.host_topology_key,
                     identity_key.root_id,
                     identity_key.function_kind,
                     identity_key.vf_index,
                     identity_key.bdf.segment,
                     identity_key.bdf.bus,
                     identity_key.bdf.device,
                     identity_key.bdf.function_num);
  endfunction

  // 功能：按完整 identity 查找已枚举的 Function context，并校验调用方提供的
  //       identity 与 env 保存的 incarnation 一致。
  // 输入/输出及副作用：identity（输入）、result_context（输出）；按完整 identity key 查找并
  //   发布 env 持有的 context 非拥有引用，不克隆 context 或修改 ledger。
  // 失败/边界：identity 为空、key 不存在或 generation/epoch 不一致时返回明确错误状态。
  function rdma_status find_function(
    rdma_function_identity identity,
    output rdma_function_context result_context
  );
    string key_name;
    result_context = null;
    if (identity == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "Function identity is null");
    key_name = identity_key_name(identity.key);
    if (!m_contexts.exists(key_name) || m_contexts[key_name] == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "Function context is not enumerated");
    if (m_contexts[key_name].identity == null ||
        !m_contexts[key_name].identity.same_incarnation(identity))
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "Function identity incarnation is stale");
    result_context = m_contexts[key_name];
    return rdma_status::success();
  endfunction

  // 功能：按 Function handle 反查 context，保证 UID、global ID 和 generation 三元组
  //       与 env 的 immutable identity 完全匹配，避免同一 Host 上本地编号串线。
  // 输入/输出及副作用：function_handle（输入）、result_context（输出）；按 function_uid、global ID
  //   和 generation 三元组扫描 context，发布匹配的非拥有引用。
  // 失败/边界：句柄为空/类型错误返回 INVALID_ARGUMENT；UID 存在但 generation 过期返回 STALE。
  function rdma_status find_handle(
    rdma_handle function_handle,
    output rdma_function_context result_context
  );
    rdma_function_context candidate;
    string key_name;
    result_context = null;

    if (function_handle == null ||
        function_handle.kind != RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "Function handle is invalid");
    foreach (m_contexts[key_name]) begin
      candidate = m_contexts[key_name];
      if (candidate == null || candidate.identity == null)
        continue;
      if (candidate.identity.function_uid == function_handle.function_uid &&
          candidate.identity.global_function_id == function_handle.object_id) begin
        if (candidate.identity.generation != function_handle.generation)
          return rdma_status::make(RDMA_SC_STALE_GENERATION,
                                   "Function handle generation is stale");
        result_context = candidate;
        return rdma_status::success();
      end
    end
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             "Function handle is not enumerated");
  endfunction

  // 功能：返回当前 device env 已枚举的 Function context 数量，供上层完成拓扑覆盖检查。
  // 输入/输出及副作用：无参数；只读返回 m_contexts 中已枚举的 context 数量。
  // 失败/边界：尚未枚举任何 Function 时返回 0；函数不创建或删除 context。
  function int unsigned context_count();
    return m_contexts.num();
  endfunction

  // 功能：请求指定 VF 的 Function-level reset，并只重建该 VF context。
  // 输入/输出及副作用：identity（输入）；先 quiesce 目标 VF、推进 coordinator Function epoch，
  //   再重建该 context；其他 Function 不受影响。
  // 失败/边界：null、非 VF 或 reset coordinator 缺失时拒绝；若 identity 未枚举，coordinator 仍可能
  //   建立其 epoch ledger，但因无匹配 context 而不会重建任何 Function。
  function rdma_status request_vf_flr(rdma_function_identity identity);
    rdma_status status;

    if (identity == null || identity.key.function_kind != RDMA_FUNCTION_VF)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "VF FLR requires a VF identity");
    if (reset_coordinator == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "device env reset coordinator is missing");
    status = quiesce_scope(RDMA_ENV_RESET_VF, identity, 0);
    if (!status.ok())
      return status;
    status = reset_coordinator.request_vf_flr(identity);
    if (!status.ok())
      return status;
    return rebuild_scope(RDMA_ENV_RESET_VF, identity, 0);
  endfunction

  // 功能：请求指定 PF reset，并按同 Host、同 parent BDF 级联重建 PF 及其全部 VF。
  // 输入/输出及副作用：identity（输入）；先 quiesce 目标 PF 及其同 Host/parent BDF 的 VF，推进
  //   PF reset epoch，再逐个重建选中 context。
  // 失败/边界：null、非 PF 或 coordinator 缺失时拒绝；未枚举 PF 仍可推进 coordinator ledger，
  //   但不会产生 context 重建。
  function rdma_status request_pf_reset(rdma_function_identity identity);
    rdma_status status;

    if (identity == null || identity.key.function_kind != RDMA_FUNCTION_PF)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "PF reset requires a PF identity");
    if (reset_coordinator == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "device env reset coordinator is missing");
    status = quiesce_scope(RDMA_ENV_RESET_PF, identity, 0);
    if (!status.ok())
      return status;
    status = reset_coordinator.request_pf_reset(identity);
    if (!status.ok())
      return status;
    return rebuild_scope(RDMA_ENV_RESET_PF, identity, 0);
  endfunction

  // 功能：请求 Host reset，级联停止并重建该 Host topology 下的全部 Function context。
  // 输入/输出及副作用：host_topology_key（输入）；quiesce 该 Host 全部 context，推进 Host epoch，
  //   再重建选中 context；即使无 context，coordinator 仍会推进 epoch。
  // 失败/边界：coordinator 缺失时拒绝；没有已枚举 context 的 Host 仍会推进 Host epoch。
  function rdma_status request_host_reset(int unsigned host_topology_key);
    rdma_status status;

    if (reset_coordinator == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "device env reset coordinator is missing");
    status = quiesce_scope(RDMA_ENV_RESET_HOST, null, host_topology_key);
    if (!status.ok())
      return status;
    status = reset_coordinator.request_host_reset(host_topology_key);
    if (!status.ok())
      return status;
    return rebuild_scope(RDMA_ENV_RESET_HOST, null, host_topology_key);
  endfunction

  // 功能：请求 Device reset，级联停止并重建当前 env 的全部 Function context。
  // 输入/输出及副作用：无参数；quiesce 并推进全局 Device epoch，然后重建 env 中全部 context。
  // 失败/边界：coordinator 缺失时拒绝；单个 context 重建失败会被隔离并返回错误。
  function rdma_status request_device_reset();
    rdma_status status;

    if (reset_coordinator == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "device env reset coordinator is missing");
    status = quiesce_scope(RDMA_ENV_RESET_DEVICE, null, 0);
    if (!status.ok())
      return status;
    status = reset_coordinator.request_device_reset();
    if (!status.ok())
      return status;
    return rebuild_scope(RDMA_ENV_RESET_DEVICE, null, 0);
  endfunction

  // 功能：判断 context 是否属于给定复位范围，集中维护 VF/PF/Host/Device 选择规则。
  // 输入/输出及副作用：context/scope/identity/host_key（输入）；只读判断 context 是否落在 VF、PF、
  //   Host 或 Device 复位选择范围内，不修改任何状态。
  // 失败/边界：null context/identity 永不匹配；PF 只通过完整 Host+parent BDF 选择后代 VF。
  protected function bit scope_matches(
    rdma_function_context context,
    rdma_device_reset_scope_e scope,
    rdma_function_identity identity,
    int unsigned host_key
  );
    if (context == null || context.identity == null)
      return 1'b0;
    case (scope)
      RDMA_ENV_RESET_VF:
        return identity != null && context.identity.same_function(identity);
      RDMA_ENV_RESET_PF: begin
        if (identity == null ||
            context.identity.key.host_topology_key !=
              identity.key.host_topology_key)
          return 1'b0;
        if (context.identity.key.function_kind == RDMA_FUNCTION_PF)
          return context.identity.same_function(identity);
        return context.identity.key.function_kind == RDMA_FUNCTION_VF &&
               rdma_bdf_same(context.identity.key.parent_pf_bdf,
                             identity.key.bdf);
      end
      RDMA_ENV_RESET_HOST:
        return context.identity.key.host_topology_key == host_key;
      RDMA_ENV_RESET_DEVICE:
        return 1'b1;
      default:
        return 1'b0;
    endcase
  endfunction

  // 功能：在 epoch 发布前停止选中 context 接收新事务，建立 reset 的 quiesce 屏障。
  // 输入/输出及副作用：scope/identity/host_key（输入）；遍历匹配 context 并调用 quiesce，成功时
  //   仅改变 context 状态，不推进 coordinator epoch。
  // 失败/边界：QUARANTINED 或非法 context 使整个级联 fail-closed，不推进 coordinator epoch。
  protected function rdma_status quiesce_scope(
    rdma_device_reset_scope_e scope,
    rdma_function_identity identity,
    int unsigned host_key
  );
    rdma_status status;
    string key_name;

    foreach (m_contexts[key_name]) begin
      if (!scope_matches(m_contexts[key_name], scope, identity, host_key))
        continue;
      if (m_contexts[key_name].state == RDMA_CONTEXT_DISCOVERED ||
          m_contexts[key_name].state == RDMA_CONTEXT_QUIESCING)
        continue;
      status = m_contexts[key_name].quiesce();
      if (!status.ok())
        return status;
    end
    return rdma_status::success();
  endfunction

  // 功能：读取 coordinator 发布的 epoch，为选中 context 生成下一 incarnation 并提交重建。
  // 输入/输出及副作用：scope/identity/host_key（输入）；读取 coordinator epoch，为匹配 context
  //   生成下一 generation 并调用 reset；失败 context 被置为 QUARANTINED，后续 ledger 刷新停止。
  // 失败/边界：generation 溢出、context reset 失败或 ledger 克隆失败会隔离该 context 并停止级联。
  protected function rdma_status rebuild_scope(
    rdma_device_reset_scope_e scope,
    rdma_function_identity identity,
    int unsigned host_key
  );
    rdma_function_identity previous_identity;
    rdma_status status;
    string key_name;
    int unsigned next_generation;
    rdma_reset_epoch_t next_epoch;

    foreach (m_contexts[key_name]) begin
      if (!scope_matches(m_contexts[key_name], scope, identity, host_key))
        continue;
      if (m_contexts[key_name] == null || m_contexts[key_name].identity == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "selected Function context is incomplete");
      previous_identity = m_contexts[key_name].identity;
      if (previous_identity.generation == 32'hffff_ffff)
        return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "Function generation is exhausted");
      next_generation = previous_identity.generation + 1;
      next_epoch = reset_coordinator.function_epoch(previous_identity);
      status = m_contexts[key_name].reset(next_generation, next_epoch);
      if (!status.ok()) begin
        m_contexts[key_name].state = RDMA_CONTEXT_QUARANTINED;
        return status;
      end
      status = refresh_identity_ledger(previous_identity,
                                       m_contexts[key_name].identity);
      if (!status.ok()) begin
        m_contexts[key_name].state = RDMA_CONTEXT_QUARANTINED;
        return status;
      end
    end
    return rdma_status::success();
  endfunction

  // 功能：用 context 发布的新 identity 替换 device env 的 dpu_common identity ledger 副本。
  // 输入/输出及副作用：previous_identity/next_identity（输入）；定位同一 Function 的 ledger 条目，
  //   克隆 next_identity 后替换 env 持有的副本；不修改 context identity。
  // 失败/边界：身份不匹配、克隆失败或 ledger 缺失时返回错误。
  protected function rdma_status refresh_identity_ledger(
    rdma_function_identity previous_identity,
    rdma_function_identity next_identity
  );
    rdma_function_identity copy;
    uvm_object cloned_object;
    string key_name;
    bit found;

    if (previous_identity == null || next_identity == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "identity ledger refresh received null");
    found = 1'b0;
    foreach (m_identities[key_name]) begin
      if (m_identities[key_name] == null ||
          !m_identities[key_name].same_function(previous_identity))
        continue;
      cloned_object = next_identity.clone();
      if (cloned_object == null || !$cast(copy, cloned_object))
        return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "identity ledger clone failed");
      m_identities[key_name] = copy;
      found = 1'b1;
      break;
    end
    if (!found)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "identity ledger entry is missing");
    return rdma_status::success();
  endfunction
endclass
