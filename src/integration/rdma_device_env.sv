// 目录：src/integration/，位于 dpu_common 适配层的设备级组合入口。
// 职责：校验冻结的 dpu_common 设备/资源快照，枚举全部 PF/VF，并为每个
//       Function 建立 RDMA identity 与统一 reset coordinator 注册表。
// 依赖：rdma_dpu_identity_adapter、rdma_host_mem_router、rdma_pcie_router，
//       以及 dpu_common 的 dpu_device_snapshot/resource_snapshot。
// 所有权与生命周期：外部快照和 router 由调用方拥有；本对象保存非拥有快照引用，
//       identity ledger 由本对象创建并在环境生命周期内持有，get_identity() 返回副本。
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
  // 功能：构造空的设备环境对象并初始化 UVM 对象名称；实际依赖绑定由 build() 完成。
  function new(string name="rdma_device_env");
    super.new(name);
  endfunction

  // 功能：以冻结 dpu_common 快照为权威，原子地组装 device env、identity ledger
  //       和 reset coordinator；失败时返回错误状态且不返回半初始化环境。
  // 输入/输出：source_* 是外部依赖，registry/build_timeout 为兼容参数；result_env
  //       返回新环境。副作用是向 coordinator 注册每个 Function 并绑定 Host router。
  // 边界：任一依赖为空、快照未冻结/不一致或 Function 身份投影失败都会拒绝构建。
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

    source_device_snapshot.list_functions(keys);
    foreach (keys[index]) begin
      identity = null;
      status = rdma_dpu_identity_adapter::identity_from_snapshot(
        source_device_snapshot, keys[index], identity);
      if (!status.ok() || identity == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
          {"Function identity projection failed: ", status.message});
      key_name = dpu_function_key_name(keys[index]);
      candidate_env.m_identities[key_name] = identity;
      selected_coordinator.register_function(identity);
    end
    // registry/timeout 保留在 API 中用于上层兼容；Device env 只保存已经
    // 校验过的 dpu_common snapshot 和唯一 reset coordinator。
    result_env = candidate_env;
    return rdma_status::success();
  endfunction

  // 功能：按 dpu_common 完整 Function key 查询身份，并返回与内部 ledger 解耦的克隆。
  // 输入/输出：key 指定 Host/PF/VF；找不到 key 或克隆失败时返回 null，不修改环境状态。
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
endclass
