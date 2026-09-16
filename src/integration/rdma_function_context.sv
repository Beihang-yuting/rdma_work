// 目录：src/integration/，位于设备级环境与单 Function 数据面的连接层。
// 职责：绑定一个 dpu_common 投影 identity、资源快照、Host-memory/PCIe router，
//       并把该 Function 纳入统一 reset coordinator 的 epoch 账本。
// 依赖：rdma_types/adapter 契约、dpu_resource_snapshot 以及两个外部 router。
// 所有权与生命周期：传入快照、router 和可选 registry 由上层拥有；context 保存
//       非拥有引用，identity 保存注册时克隆，context 生命周期由调用方管理。

// Context 状态只描述 Function 级入口是否允许接收新事务；队列 runtime 的细粒度
// 状态仍由 rdma_queue_runtime 独占，避免在集成层复制 PI/CI 或 credit。
typedef enum bit [2:0] {
  RDMA_CONTEXT_DISCOVERED = 3'd0,
  RDMA_CONTEXT_ACTIVE = 3'd1,
  RDMA_CONTEXT_QUIESCING = 3'd2,
  RDMA_CONTEXT_QUARANTINED = 3'd3
} rdma_function_context_state_e;

class rdma_function_context extends uvm_object;
  `uvm_object_utils(rdma_function_context)
  rdma_function_identity identity;
  rdma_function_binding binding;
  dpu_resource_snapshot resources;
  rdma_resource_manager resource_manager;
  rdma_host_mem_router host_mem;
  rdma_pcie_router pcie;
  rdma_reset_coordinator reset_coordinator;
  rdma_function_context_state_e state;
  // 功能：构造尚未绑定依赖的 Function context；所有校验和引用绑定集中在 build()。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：构造过程不分配 Host-memory、PCIe endpoint 或 manager 资源；空 name 也必须得到可配置对象。
  function new(string name="rdma_function_context");
    super.new(name);
    state = RDMA_CONTEXT_DISCOVERED;
  endfunction

  // 功能：校验 identity/资源快照并构造单 Function context，同时创建或复用 reset
  //       coordinator、连接 Host router、登记 identity。返回错误时 result_context 为 null。
  // 输入/输出及副作用：source_identity/source_binding 被克隆到 result_context；resources、
  //   host_mem、pcie 和 registry 仅保存非拥有引用；coordinator 为空时创建新的 coordinator，
  //   并将 Host router/identity 登记其中。build_timeout 仅为兼容参数，不产生延迟。
  // 失败/边界：依赖为空、identity 无效（包括 validator 返回 null）、资源未冻结或克隆失败时返回错误且 result_context 为 null；
  //   不复制 registry 可变状态，也不取得外部 router/快照所有权。
  static function rdma_status build(
    rdma_function_identity source_identity,
    dpu_resource_snapshot source_resources,
    rdma_host_mem_router source_host_mem,
    rdma_pcie_router source_pcie,
    uvm_object registry,
    time build_timeout,
    output rdma_function_context result_context,
    rdma_reset_coordinator coordinator = null,
    rdma_function_binding source_binding = null
  );
    // 兼容入口保留历史参数顺序；实际构造统一走参数顺序稳定的共享实现。
    return build_shared(source_identity, source_resources, source_host_mem,
                        source_pcie, coordinator, source_binding, registry,
                        build_timeout, result_context);
  endfunction

  // 功能：使用显式的 coordinator 参数构造 Function context，供 device env
  //       在多 Function 拓扑中保证所有 context 共享同一 reset ledger。
  // 输入/输出及副作用：source_identity/source_binding 被克隆，resources、router、registry 仅
  //   以非拥有引用写入 result_context；coordinator 被连接 Host router 并登记 identity。
  //   build_timeout 保留在 API 中但不会阻塞或调度事务。
  // 失败/边界：任一依赖校验或克隆失败时返回错误，result_context 保持 null，不产生半成品。
  static function rdma_status build_shared(
    rdma_function_identity source_identity,
    dpu_resource_snapshot source_resources,
    rdma_host_mem_router source_host_mem,
    rdma_pcie_router source_pcie,
    rdma_reset_coordinator coordinator,
    rdma_function_binding source_binding,
    uvm_object registry,
    time build_timeout,
    output rdma_function_context result_context
  );
    rdma_function_identity identity_copy;
    rdma_function_binding binding_copy;
    rdma_resource_manager manager;
    uvm_object cloned_object;
    rdma_status status;

    result_context = null;
    if (source_identity == null || source_resources == null ||
        source_host_mem == null || source_pcie == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "Function context dependency is null");
    status = source_identity.validate();
    if (status == null || !status.ok() || !source_resources.is_frozen())
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "Function context snapshot invalid");
    cloned_object = source_identity.clone();
    if (cloned_object == null || !$cast(identity_copy, cloned_object))
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "Function identity clone failed");

    if (source_binding != null) begin
      cloned_object = source_binding.clone();
      if (cloned_object == null || !$cast(binding_copy, cloned_object))
        return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "Function binding clone failed");
    end
    else begin
      binding_copy = rdma_function_binding::type_id::create(
        "context_binding");
      status = binding_copy.configure_identity(identity_copy);
      if (status == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "Function context binding configuration returned null status"
        );
      if (!status.ok())
        return status;
    end

    result_context = rdma_function_context::type_id::create(
      "function_context");
    result_context.identity = identity_copy;
    result_context.binding = binding_copy;
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
    result_context.state = RDMA_CONTEXT_DISCOVERED;
    // build_timeout 保留在兼容签名中；context 构造不引入隐式延迟。
    return rdma_status::success();
  endfunction

  // 功能：允许已构造的 Function context 接收新的控制面/数据面事务。
  // 输入/输出及副作用：无参数；成功时仅把 DISCOVERED context 标记为 ACTIVE、创建新的 owner handle
  //   并更新 binding 状态，不分配队列或 DMA 资源。
  // 失败/边界：QUARANTINED、identity validator 返回 null 或未完成 identity 绑定时拒绝激活；重复激活保持幂等成功。
  function rdma_status activate();
    rdma_status identity_status;

    if (identity == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "Function context identity is invalid");
    identity_status = identity.validate();
    if (identity_status == null || !identity_status.ok())
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "Function context identity is invalid");
    if (state == RDMA_CONTEXT_ACTIVE)
      return rdma_status::success();
    if (state == RDMA_CONTEXT_QUARANTINED)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "quarantined Function context cannot activate");
    if (binding == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "Function context binding is missing");
    binding.owner_h = binding.make_handle();
    binding.state = RDMA_BIND_ACTIVE;
    state = RDMA_CONTEXT_ACTIVE;
    return rdma_status::success();
  endfunction

  // 功能：停止该 Function 接收新事务，为 reset 或资源回收建立 quiesce 边界。
  // 输入/输出及副作用：无参数；ACTIVE context 转为 QUIESCING，重复调用幂等；不释放或修改外部资源。
  // 失败/边界：DISCOVERED/QUARANTINED context 不能 quiesce；重复 quiesce 幂等成功。
  function rdma_status quiesce();
    if (state == RDMA_CONTEXT_QUIESCING)
      return rdma_status::success();
    if (state != RDMA_CONTEXT_ACTIVE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "Function context is not active");
    state = RDMA_CONTEXT_QUIESCING;
    return rdma_status::success();
  endfunction

  // 功能：发布新的 Function generation/reset epoch，并在 quiesce 边界后重新激活；
  //       尚未 activate 的 context 也会更新 authority，但保持 DISCOVERED 状态。
  // 输入/输出及副作用：new_generation/new_epoch 写入克隆 identity，并重建 binding owner handle；
  //   DISCOVERED 保持原状态，其他可恢复状态转为 ACTIVE，不重放旧事务。
  // 失败/边界：QUARANTINED、generation 为零或参数溢出时拒绝；不自动重放旧 queue 事务。
  function rdma_status reset(
    int unsigned new_generation,
    rdma_reset_epoch_t new_epoch
  );
    rdma_function_identity next_identity;
    rdma_status status;

    if (new_generation == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "new Function generation is zero");
    if (identity == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "Function context identity is missing");
    if (state == RDMA_CONTEXT_QUARANTINED)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "quarantined Function context cannot reset");

    next_identity = rdma_function_identity::type_id::create(
      "reset_identity");
    status = next_identity.configure(
      identity.key, identity.global_function_id, identity.function_uid,
      new_generation, new_epoch);
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "reset identity configuration returned null status"
      );
    if (!status.ok())
      return status;
    identity = next_identity;
    if (binding == null)
      binding = rdma_function_binding::type_id::create("reset_binding");
    status = binding.configure_identity(identity);
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "reset binding configuration returned null status"
      );
    if (!status.ok())
      return status;
    binding.owner_h = binding.make_handle();
    binding.state = RDMA_BIND_ACTIVE;
    if (state != RDMA_CONTEXT_DISCOVERED)
      state = RDMA_CONTEXT_ACTIVE;
    return rdma_status::success();
  endfunction

  // 功能：在当前 Function scope 内查询队列句柄；此阶段仅提供统一 authority 校验。
  // 输入/输出及副作用：queue_handle（输入）；只读校验 context ACTIVE 状态及 Function UID/generation，
  //   当前实现不维护队列表，因此不会发布 queue 对象或取得外部资源所有权。
  // 失败/边界：context 非 ACTIVE、句柄为空、Function UID/generation 不匹配或队列未登记时拒绝。
  function rdma_status lookup_queue(rdma_handle queue_handle);
    if (state != RDMA_CONTEXT_ACTIVE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "Function context is not active");
    if (queue_handle == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "queue handle is null");
    if (identity == null || queue_handle.function_uid != identity.function_uid)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "queue handle Function does not match context");
    if (queue_handle.generation != identity.generation)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "queue handle generation is stale");
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             "queue is not registered in Function context");
  endfunction
endclass
