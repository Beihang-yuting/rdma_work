// 目录：src/integration/，位于设备级环境与单 Function 数据面的连接层。
// 职责：绑定一个 dpu_common 投影 identity、资源快照、Host-memory/PCIe router，
//       并把该 Function 纳入统一 reset coordinator 的 epoch 账本。
// 依赖：rdma_types/adapter 契约、dpu_resource_snapshot 以及两个外部 router。
// 所有权与生命周期：传入快照、router 和可选 registry 由上层拥有；context 保存
//       非拥有引用，identity 保存注册时克隆，context 生命周期由调用方管理。
class rdma_function_context extends uvm_object;
  `uvm_object_utils(rdma_function_context)
  rdma_function_identity identity;
  dpu_resource_snapshot resources;
  rdma_resource_manager resource_manager;
  rdma_host_mem_router host_mem;
  rdma_pcie_router pcie;
  rdma_reset_coordinator reset_coordinator;
  // 功能：构造尚未绑定依赖的 Function context；所有校验和引用绑定集中在 build()。
  function new(string name="rdma_function_context");
    super.new(name);
  endfunction

  // 功能：校验 identity/资源快照并构造单 Function context，同时创建或复用 reset
  //       coordinator、连接 Host router、登记 identity。返回错误时 result_context 为 null。
  // 输入/输出：source_* 是依赖，registry/build_timeout 保留兼容接口，result_context 返回结果。
  // 边界：依赖为空、identity 无效、资源未冻结或 identity 克隆失败时拒绝构建；不会复制
  //       registry 的可变内部状态，也不会取得外部 router 的所有权。
  static function rdma_status build(
    rdma_function_identity source_identity,
    dpu_resource_snapshot source_resources,
    rdma_host_mem_router source_host_mem,
    rdma_pcie_router source_pcie,
    uvm_object registry,
    time build_timeout,
    output rdma_function_context result_context,
    rdma_reset_coordinator coordinator = null
  );
    rdma_function_identity identity_copy;
    rdma_resource_manager manager;
    uvm_object cloned_object;

    result_context = null;
    if (source_identity == null || source_resources == null ||
        source_host_mem == null || source_pcie == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "Function context dependency is null");
    if (!source_identity.validate().ok() || !source_resources.is_frozen())
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "Function context snapshot invalid");
    cloned_object = source_identity.clone();
    if (cloned_object == null || !$cast(identity_copy, cloned_object))
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "Function identity clone failed");

    result_context = rdma_function_context::type_id::create(
      "function_context");
    result_context.identity = identity_copy;
    result_context.resources = source_resources;
    result_context.host_mem = source_host_mem;
    result_context.pcie = source_pcie;
    if ($cast(manager, registry))
      result_context.resource_manager = manager;
    if (coordinator == null)
      coordinator = rdma_reset_coordinator::type_id::create(
        "function_context_reset_coordinator");
    coordinator.attach_host_router(source_host_mem);
    coordinator.register_function(identity_copy);
    result_context.reset_coordinator = coordinator;
    // registry/timeout 由上层 resource manager 使用；context 本身不持有
    // registry 的可变内部状态，只保留可选的 manager 观察句柄。
    return rdma_status::success();
  endfunction
endclass
