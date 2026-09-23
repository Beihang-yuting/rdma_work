// 目录：设备集成层 integration/rdma_host_mem_router.sv。
// 职责：按完整 Host/root/segment/BDF route 选择 host-memory manager，验证 Function/owner
//       authority 与四维 reset epoch，并维护 allocation mapping 的可回收平行账本。
// 依赖：依赖 rdma_host_mem_api、rdma_dma_request_context、rdma_dma_mapping、rdma_status、
//       rdma_reset_coordinator 及 dpu_common 提供的冻结 topology/route 值快照。
// 所有权与生命周期：router 只拥有自身的 mapping authority/epoch 值账本和 detached request
//       snapshot；manager、backing、coordinator 与 caller mapping 均为非拥有引用，必须在外部
//       lifecycle teardown 前完成 release/detach，router 不负责销毁这些资源。

// 中文说明：本文件位于 integration/，是 dpu_common topology 与外部
// Host-memory manager 的唯一路由边界。router 不拥有 manager 或 mapping
// 的底层存储，只按 Host route 选择 manager，并保存 allocation 时的
// Function/owner/Host/Device reset authority 快照。
//
// 之所以把每个 epoch 维度分别保存，是因为 Host reset、Function FLR 和
// Device reset 可能独立发生；用 max() 合并会丢掉“某一维已变化、另一维
// 恰好相同”的事实。所有读写释放操作都必须通过同一组 ledger 校验。
class rdma_host_mem_route_entry extends uvm_object;
  `uvm_object_utils(rdma_host_mem_route_entry)

  int unsigned host_topology_key;
  rdma_host_mem_api manager;

  // 功能：构造一个未绑定 manager 的 Host route entry；调用方随后填写 Host key 和
  //       非拥有 manager 引用，再交给 router.configure() 做完整校验。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：构造过程不分配 Host-memory、PCIe endpoint 或 manager 资源；空 name 也必须得到可配置对象。
  function new(string name = "rdma_host_mem_route_entry");
    super.new(name);
    host_topology_key = 0;
    manager = null;
  endfunction
endclass

class rdma_host_mem_router extends rdma_host_mem_api;
  `uvm_object_utils(rdma_host_mem_router)

  // 配置表由 Device env 发布；router 只保存非拥有引用。
  protected rdma_host_mem_api m_managers[int unsigned];
  protected rdma_reset_epoch_t m_epochs[int unsigned];

  // m_maps 中的 object 是 manager 返回、由调用方持有的 mapping。其余
  // parallel arrays 是 router 自己拥有的不可变 authority ledger，任何
  // release 都必须同步删除，避免后续 allocation 与 ledger 错位。
  protected rdma_dma_mapping m_maps[$];
  protected rdma_reset_epoch_t m_map_epochs[$];
  protected rdma_reset_epoch_t m_map_local_host_epochs[$];
  protected rdma_reset_epoch_t m_map_host_epochs[$];
  protected rdma_reset_epoch_t m_map_function_epochs[$];
  protected rdma_reset_epoch_t m_map_device_epochs[$];
  protected rdma_route_key_t m_map_routes[$];
  protected longint unsigned m_map_uids[$];
  protected int unsigned m_map_generations[$];
  protected int unsigned m_map_object_ids[$];
  protected rdma_resource_kind_e m_map_kinds[$];
  protected bit m_map_owner_valid[$];
  protected longint unsigned m_map_owner_uids[$];
  protected int unsigned m_map_owner_object_ids[$];
  protected int unsigned m_map_owner_generations[$];
  protected rdma_resource_kind_e m_map_owner_kinds[$];
  protected rdma_bdf_t m_map_requester_bdfs[$];
  protected rdma_reset_coordinator m_reset;

  // 功能：统一验证 router 可变入口是否由当前 coordinator lease owner 调用，避免
  //       direct configure/epoch advance 在 env reset transaction 中绕过 ownership 边界；
  //       Host epoch publication 由 coordinator 主入口授权后可显式允许 active seam。
  // 输入/输出及副作用：owner/token（输入）描述可选 lease；require_active（输入）要求
  //       coordinator transaction 已开始；allow_active（输入）仅供 coordinator 已授权的
  //       epoch publication seam 使用；函数只读 m_reset 与 coordinator lease，不修改 mapping。
  // 失败/边界：未绑定 coordinator 时保留 legacy null/0 语义；已绑定但尚未 claim lease
  //       的 legacy coordinator 仍必须经过 coordinator 的 publication/transaction guard，
  //       不能借 router 这条入口绕过同步 callback 屏障。已有 lease 且 owner/token 不匹配
  //       返回 RESOURCE_BUSY，要求 active 但未 begin 返回 INVALID_STATE；active 期间未显式
  //       允许的 direct callback 仍被拒绝。
  protected function rdma_status authorize_router_operation(
    uvm_object owner,
    longint unsigned token,
    bit require_active = 1'b0,
    bit allow_active = 1'b0
  );
    if (m_reset == null) begin
      if (owner != null || token != 0)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "router operation supplied an owner without a bound lease"
        );
      return rdma_status::success();
    end
    return m_reset.authorize_owned_operation(
      owner, token, require_active, allow_active
    );
  endfunction

  // 功能：把五个不携带 owner/token 的 Host-router dataplane 入口接到 coordinator 的
  //       reset-admission seam；正常数据面在 reset publication/transaction 中停止，释放
  //       路径可显式声明 cleanup 以继续排空旧 mapping 或回滚外部 allocation。
  // 输入/输出及副作用：operation_name（输入）用于诊断；allow_cleanup（输入）仅由
  //       release/release_opaque 传入；函数只读 m_reset 的 admission 状态，不修改 mapping、
  //       manager 或任一 epoch ledger，返回 rdma_status。
  // 失败/边界：未绑定 coordinator 时保留 legacy tokenless 语义并返回 OK；绑定 coordinator
  //       且 reset publication/transaction active 时，非 cleanup 操作返回 RESOURCE_BUSY；
  //       cleanup 操作继续交给 mapping authority/stale-drain 校验。该 helper 不要求 lease
  //       owner/token，也不提供跨线程或跨进程互斥。
  protected function rdma_status authorize_dataplane_operation(
    string operation_name,
    bit allow_cleanup = 1'b0
  );
    if (m_reset == null)
      return rdma_status::success();
    return m_reset.authorize_tokenless_dataplane(
      operation_name, allow_cleanup
    );
  endfunction

  // 功能：构造空 Host-memory router，初始化 reset coordinator 引用；路由表由 configure()
  //       发布，mapping ledger 由 allocate() 建立。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：构造过程不分配 Host-memory、PCIe endpoint 或 manager 资源；空 name 也必须得到可配置对象。
  function new(string name = "rdma_host_mem_router");
    super.new(name);
    m_reset = null;
  endfunction

  // 所有权：只保存非拥有引用，不负责 coordinator 的创建或销毁。
  // 功能：通过 coordinator 的 legacy facade 连接共享 reset coordinator，使 router 能读取
  //       Function/Host/Device epoch，同时维持 coordinator/router 双侧绑定。
  // 输入/输出及副作用：coordinator（输入）；非空且未被 lease 独占时转发到
  //   coordinator.attach_host_router_status(this)，成功才更新双方非拥有引用；不取得任何
  //   coordinator/manager 所有权，也不改写 mapping。
  // 失败/边界：传入 null 时兼容 void wrapper 保持现有引用不变；非空 coordinator 在已有
  //   active mapping、跨 coordinator replacement 或旧 coordinator lease 时由 facade 拒绝。
  //   void 入口无法返回错误码，需要诊断的调用方应使用 attach_reset_coordinator_owned()
  //   或 coordinator.attach_host_router_status()。
  function void attach_reset_coordinator(
    rdma_reset_coordinator coordinator
  );
    if (coordinator != null)
      void'(coordinator.attach_host_router_status(this));
  endfunction

  // 功能：由 coordinator 内部以受控 seam 校验并绑定/解绑 reset coordinator，给 registration
  //       commit 一个可观察的 attach 结果，避免兼容 void wrapper 吞掉拒绝。
  // 输入/输出及副作用：coordinator（输入）为目标非拥有引用；coordinator_initiated（输入）
  //   只是兼容标志，必须同时携带 coordinator 产生的一次性 capability；成功时更新 m_reset，
  //   失败时保留旧 coordinator、mapping 和 epoch ledger，不取得任何外部所有权。
  // 失败/边界：目标 coordinator 已被其它 env lease、现有 mapping、旧 coordinator lease 或
  //   其它 active authority 阻挡时返回 RESOURCE_BUSY；缺少 capability、null 解绑或跨
  //   coordinator rebind 均 fail-closed。持有 lease 的合法调用者必须改用 owned attach。
  function rdma_status attach_reset_coordinator_status(
    rdma_reset_coordinator coordinator,
    bit coordinator_initiated = 1'b0,
    uvm_object capability = null
  );
    rdma_status capability_status;

    if (!coordinator_initiated)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "router coordinator attach requires the coordinator facade"
      );
    if (coordinator == null || capability == null)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "router coordinator attach requires a one-shot capability"
      );
    if (coordinator.lease_held())
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "target reset coordinator already has an ownership lease"
      );
    // null coordinator 的 legacy detach 没有可以核验的双侧 capability；必须走
    // coordinator.detach_host_router_owned()，避免清掉 router 单侧引用后留下反向指针。
    if (m_reset == null && m_maps.size() != 0)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "active router state prevents coordinator attach"
      );
    // 换绑到另一个 coordinator 同样会改变 mapping 读取时使用的 epoch
    // authority。active mapping 或旧 coordinator lease 任一存在时，旧绑定
    // 必须保持不变；相同 coordinator 的重复 attach 仍是幂等操作。
    if (m_reset != null && m_reset !== coordinator)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "active router state prevents coordinator rebind"
      );
    capability_status = coordinator.authorize_router_attach_capability(
      this, capability
    );
    if (capability_status == null || !capability_status.ok())
      return capability_status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "router coordinator attach capability validation returned null"
        ) : capability_status;
    if (m_reset == null)
      reset_local_host_epochs();
    m_reset = coordinator;
    return rdma_status::success();
  endfunction

  // 功能：在 coordinator 已验证 owner/token 且准备同时清除反向引用时，解除当前 router
  //       与该 coordinator 的绑定；这是严格一对一生命周期的唯一 detach seam。
  // 输入/输出及副作用：coordinator、owner、token、capability（输入）；成功时清除 m_reset，
  //   但不释放 Host mapping 或 manager backing；capability 经 coordinator 回验后立即消费，
  //   调用方随后由 coordinator 清除 m_host_router。
  // 失败/边界：coordinator 为空、owner/token 不匹配、缺少/伪造 capability、当前绑定不是
  //   该 coordinator 或仍有 mapping 时返回 INVALID_ARGUMENT/RESOURCE_BUSY，失败路径保持
  //   原绑定与 ledger，不能形成 router 单侧 detach。
  function rdma_status detach_reset_coordinator_owned(
    rdma_reset_coordinator coordinator,
    uvm_object owner,
    longint unsigned token,
    uvm_object capability = null
  );
    rdma_status status;

    if (coordinator == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "reset coordinator is null"
      );
    status = coordinator.authorize_owned_operation(owner, token, 1'b0);
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "router coordinator detach lease validation returned null"
        ) : status;
    if (!coordinator.lease_held())
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "owned Host router detach requires an active coordinator lease"
      );
    if (capability == null)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "owned Host router detach requires a coordinator-issued capability"
      );
    if (m_reset !== coordinator)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "router is not bound to the requested coordinator"
      );
    if (m_maps.size() != 0)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "active mappings prevent coordinator detach"
      );
    status = coordinator.authorize_router_owned_capability(
      this, capability, 1'b0, owner, token
    );
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "router owned detach capability validation returned null"
        ) : status;
    m_reset = null;
    reset_local_host_epochs();
    return rdma_status::success();
  endfunction

  // 功能：在 coordinator 已发布的一次性 capability 和明确 owner lease 下绑定或确认
  //       coordinator，阻止调用方直接改写 router 的 reset ledger。
  // 输入/输出及副作用：coordinator、owner、token、capability（输入）；成功时保存非拥有
  //       coordinator 引用，不清理 mapping；capability 经 coordinator 回验后立即消费，返回
  //       status 供 coordinator registration commit 判断是否可继续。
  // 失败/边界：null coordinator、owner/token 不匹配、缺少/伪造 capability、已有 mapping 或
  //       另一个 coordinator 绑定时返回 INVALID_ARGUMENT、RESOURCE_BUSY；失败路径保留旧
  //       m_reset 与 mapping ledger，不能形成 router 单侧 attach。
  function rdma_status attach_reset_coordinator_owned(
    rdma_reset_coordinator coordinator,
    uvm_object owner,
    longint unsigned token,
    uvm_object capability = null
  );
    rdma_status status;

    if (coordinator == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "reset coordinator is null"
      );
    status = coordinator.authorize_owned_operation(owner, token, 1'b0);
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "router coordinator lease validation returned null"
        ) : status;
    if (!coordinator.lease_held())
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "owned Host router attach requires an active coordinator lease"
      );
    if (capability == null)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "owned Host router attach requires a coordinator-issued capability"
      );
    // m_reset 为空时也可能已有 mapping（例如先配置/分配，再首次 attach）。
    // 这类 mapping 的 epoch authority 已经固定为旧的 null-coordinator 视图，
    // 不能通过 owned attach 偷换到新 ledger；只有无 mapping 的首次绑定或
    // 同一 coordinator 幂等确认可以继续。
    if ((m_reset == null && m_maps.size() != 0) ||
        (m_reset !== null && m_reset !== coordinator))
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "active router state prevents coordinator rebind"
      );
    status = coordinator.authorize_router_owned_capability(
      this, capability, 1'b1, owner, token
    );
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "router owned attach capability validation returned null"
        ) : status;
    if (m_reset == null)
      reset_local_host_epochs();
    m_reset = coordinator;
    return rdma_status::success();
  endfunction

  // 功能：事务性校验并替换 Host→manager 路由表，同时重置本地 Host epoch ledger。
  // 输入/输出及副作用：entries（输入）逐项提供 Host key 与非拥有 manager 引用；函数先在
  //       局部表校验 entry/manager 非空、Host key 唯一且 manager 不跨 Host 复用，成功后替换
  //       本对象路由和 local epoch ledger，返回 rdma_status。
  // 失败/边界：owner/token 不通过 lease 或 publication guard、存在 active mapping、空 entry、
  //       重复 Host 或同一 manager 绑定多个 Host 时拒绝，旧配置保持不变以保留 mapping 的释放出口。
  function rdma_status configure(
    rdma_host_mem_route_entry entries[$],
    uvm_object owner = null,
    longint unsigned token = 0
  );
    rdma_host_mem_api new_managers[int unsigned];
    rdma_reset_epoch_t new_epochs[int unsigned];
    rdma_status lease_status;

    lease_status = authorize_router_operation(owner, token, 1'b0);
    if (lease_status == null || !lease_status.ok())
      return lease_status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "Host router configure lease validation returned null"
        ) : lease_status;

    // 清理路由表会使仍在使用的 backing 失去释放出口，因此必须事务性
    // 拒绝，而不是先清空旧表再报告失败。
    if (m_maps.size() != 0)
      return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                               "active mappings prevent reconfigure");
    foreach (entries[i]) begin
      if (entries[i] == null || entries[i].manager == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "null Host-memory route entry");
      if (new_managers.exists(entries[i].host_topology_key))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "duplicate Host-memory route");
      foreach (new_managers[k]) begin
        if ((new_managers[k] === entries[i].manager) &&
            (k != entries[i].host_topology_key))
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "manager bound to multiple Host routes");
      end
      new_managers[entries[i].host_topology_key] = entries[i].manager;
      new_epochs[entries[i].host_topology_key] = 0;
    end

    m_managers = new_managers;
    m_epochs = new_epochs;
    clear_mapping_ledgers();
    return rdma_status::success();
  endfunction

  // 功能：依据请求快照选择 Host manager，分配 DMA mapping，并保存完整 Function/owner/
  //       route/requester BDF 及四维 reset epoch ledger。
  // 输入/输出及副作用：request_context（输入）、size（输入）、alignment（输入）、direction（输入）、mapping（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或
  //   output 发布新句柄/映射。
  // 失败/边界：route/epoch 缺失、Host 未配置、reset publication/transaction active、
  //   manager 返回 authority 不匹配或 epoch 过期时拒绝；拒绝路径不能调用 manager 或
  //   发布 router mapping row。
  function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    rdma_dma_request_context request_snapshot;
    rdma_dma_request_context manager_request;
    rdma_dma_mapping manager_mapping;
    rdma_host_mem_api manager;
    rdma_status status;
    int unsigned host_key;
    rdma_reset_epoch_t local_host_epoch;
    rdma_reset_epoch_t coordinator_host_epoch;
    rdma_reset_epoch_t function_epoch_value;
    rdma_reset_epoch_t device_epoch_value;
    rdma_reset_epoch_t canonical_request_epoch;
    rdma_reset_epoch_t validated_function_epoch;

    mapping = null;
    if (request_context == null || !request_context.route_valid ||
        !rdma_route_key_valid(request_context.route))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "invalid DMA request route");
    if (!request_context.epoch_valid)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "DMA request reset epoch is required");
    status = request_context.validate();
    status = normalize_status(status, "DMA request validation");
    if (!status.ok())
      return status;
    host_key = request_context.route.host_topology_key;
    if (!m_managers.exists(host_key))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "Host route not found");
    status = authorize_dataplane_operation("allocate");
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "Host router dataplane admission returned null"
        ) : status;

    // request_snapshot 是 caller 输入的 immutable value authority；manager 只能
    // 看到它的第二份 detached work copy。这样 manager 即使在 allocate() 内
    // 原地改写 request_context 的 Function/owner/route/epoch，也不能污染
    // router 后续用于比较和 ledger 发布的 caller snapshot。
    request_snapshot = rdma_dma_request_context::type_id::create(
      "host_dma_request_snapshot");
    if (request_snapshot == null)
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "DMA request snapshot allocation failed"
      );
    request_snapshot.copy(request_context);
    // coordinator 绑定后，Function handle、完整 route、generation 和
    // canonical reset_epoch 必须先通过 coordinator-owned registration
    // authority；否则未知 UID 的 function_epoch_uid()==0 哨兵可能被误当成
    // 合法初始 epoch，并在 manager.allocate() 已产生副作用后才暴露错误。
    // 该只读预检位于 manager 调用前，确保未知/重复 UID 直接 fail closed。
    if (m_reset != null) begin
      status = m_reset.validate_registered_function_handle(
        request_snapshot.function_h,
        request_snapshot.route,
        validated_function_epoch
      );
      if (status == null || !status.ok())
        return status == null ?
          rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "registered Function authority validation returned null"
          ) : status;
      function_epoch_value = validated_function_epoch;
    end
    else begin
      function_epoch_value = 0;
    end
    local_host_epoch = m_epochs.exists(host_key) ? m_epochs[host_key] : 0;
    coordinator_host_epoch = (m_reset != null) ?
                              m_reset.host_epoch(host_key) : 0;
    device_epoch_value = (m_reset != null) ? m_reset.device_epoch() : 0;
    canonical_request_epoch = (m_reset != null) ?
                              function_epoch_value : local_host_epoch;
    if (request_snapshot.reset_epoch != canonical_request_epoch)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "DMA request reset epoch is stale"
      );
    manager_request = rdma_dma_request_context::type_id::create(
      "host_dma_manager_request"
    );
    if (manager_request == null)
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "DMA manager request snapshot allocation failed"
      );
    manager_request.copy(request_snapshot);
    manager = m_managers[host_key];
    if (manager == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Host route manager is null"
      );
    manager_mapping = null;
    status = manager.allocate(manager_request, size, alignment, direction,
                              manager_mapping);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "Host manager allocation returned null status"
        );
      return rollback_manager_mapping(manager, manager_mapping, status);
    end
    if (manager_mapping == null) begin
      // allocate() 的 success 契约要求 output mapping 携带 opaque identity；
      // 没有 identity 就不存在安全的回滚目标，不能猜测“最近一次 allocation”。
      // 因此把 success+null 明确报告为 adapter contract violation，并要求
      // 具体 manager 遵守“success+null 不得遗留 allocation”的接口约束。
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "manager allocation violated success mapping contract"
      );
    end
    if (manager_mapping.function_h == null ||
        !manager_mapping.function_h.same_instance(
          request_snapshot.function_h))
      return rollback_manager_mapping(
        manager, manager_mapping,
        rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                          "manager returned mismatched Function"));
    if ((request_snapshot.owner_h == null) !=
        (manager_mapping.owner_h == null))
      return rollback_manager_mapping(
        manager, manager_mapping,
        rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                          "manager returned mismatched owner presence"));
    if (request_snapshot.owner_h != null &&
        !manager_mapping.owner_h.same_instance(request_snapshot.owner_h))
      return rollback_manager_mapping(
        manager, manager_mapping,
        rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                          "manager returned mismatched owner"));
    if (manager_mapping.requester_bdf != request_snapshot.requester_bdf)
      return rollback_manager_mapping(
        manager, manager_mapping,
        rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                          "manager returned mismatched requester BDF"));
    if (manager_mapping.state != RDMA_MAPPING_ACTIVE ||
        manager_mapping.size != size ||
        manager_mapping.direction != direction)
      return rollback_manager_mapping(
        manager, manager_mapping,
        rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                          "manager returned invalid mapping geometry"));
    if (!manager_mapping.route_valid ||
        !rdma_route_key_valid(manager_mapping.route) ||
        !same_route(manager_mapping.route, request_snapshot.route))
      return rollback_manager_mapping(
        manager, manager_mapping,
        rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                          "manager returned mismatched route"));
    if (!manager_mapping.epoch_valid ||
        manager_mapping.reset_epoch != request_snapshot.reset_epoch)
      return rollback_manager_mapping(
        manager, manager_mapping,
        rdma_status::make(RDMA_SC_STALE_GENERATION,
                          "manager returned mismatched reset epoch"));

    local_host_epoch = m_epochs.exists(host_key) ? m_epochs[host_key] : 0;
    coordinator_host_epoch = (m_reset != null) ?
                              m_reset.host_epoch(host_key) : 0;
    device_epoch_value = (m_reset != null) ? m_reset.device_epoch() : 0;
    // manager.allocate() 是外部可重入边界；它返回前 coordinator 可能已经
    // 发布了 reset。再次验证当前 handle/incarnation，避免把 preflight 时的
    // Function epoch 当成提交时 authority；失败时 rollback opaque mapping。
    if (m_reset != null) begin
      status = m_reset.validate_registered_function_handle(
        request_snapshot.function_h,
        request_snapshot.route,
        validated_function_epoch
      );
      if (status == null || !status.ok())
        return rollback_manager_mapping(
          manager, manager_mapping,
          status == null ?
            rdma_status::make(
              RDMA_SC_INVALID_STATE,
              "registered Function authority revalidation returned null"
            ) : status
        );
      if (validated_function_epoch != function_epoch_value)
        return rollback_manager_mapping(
          manager, manager_mapping,
          rdma_status::make(
            RDMA_SC_STALE_GENERATION,
            "Function reset epoch advanced during Host allocation"
          )
        );
      function_epoch_value = validated_function_epoch;
    end
    // request_context.reset_epoch 的唯一生产来源是 Function identity。
    // Host/Device reset 虽然会级联推进该 identity epoch，但 coordinator
    // 仍分别保留 Host/Device ledger 作为旧 mapping 的失效维度；把这些
    // 计数再次相加会让一次 Host reset 变成“1 (Function) + 1 (Host) +
    // 1 (router-local Host)”的伪造 epoch，导致 reset rebuild 产生的新
    // request context 永远无法重新 allocate。未绑定 coordinator 时，
    // router-local Host epoch 是唯一可验证的 legacy reset authority。
    canonical_request_epoch = (m_reset != null) ?
                              function_epoch_value : local_host_epoch;
    if (request_snapshot.reset_epoch != canonical_request_epoch)
      return rollback_manager_mapping(
        manager, manager_mapping,
        rdma_status::make(RDMA_SC_STALE_GENERATION,
                          "DMA request reset epoch is stale"));

    // manager.allocate() 是外部可重入边界；即使 Function authority 与 epoch
    // 没有变化，coordinator 也可能在该调用期间进入 reset transaction 或
    // publication guard。该同步 admission 必须紧邻 ledger commit，再次阻止
    // tokenless allocation 在 reset 窗口发布 router mapping；失败时仍使用
    // opaque identity 回滚 manager backing，保持 router/manager 两侧原子性。
    status = authorize_dataplane_operation("allocate");
    if (status == null || !status.ok())
      return rollback_manager_mapping(
        manager, manager_mapping,
        status == null ?
          rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "Host router dataplane admission returned null"
          ) : status
      );

    mapping = manager_mapping;
    // 替换 manager 返回的可变 alias，mapping 的 authority 由 router 自己
    // 拥有值快照；底层 backing/iova/size 等数据仍由 manager 返回对象提供。
    mapping.function_h = rdma_clone_function_handle_value(
      request_snapshot.function_h, "Host mapping Function");
    if (request_snapshot.owner_h == null)
      mapping.owner_h = null;
    else
      mapping.owner_h = rdma_clone_handle_value(
        request_snapshot.owner_h, "Host mapping owner");
    mapping.route = request_snapshot.route;
    mapping.route_valid = 1'b1;
    // mapping.reset_epoch 必须与 request_context/Function identity 的
    // canonical scalar 一致；四个独立 epoch 已在平行 ledger 中保存，
    // validate_mapping() 会逐维检查它们，不能再用聚合和覆盖该字段。
    mapping.reset_epoch = canonical_request_epoch;
    mapping.epoch_valid = 1'b1;
    mapping.requester_bdf = request_snapshot.requester_bdf;

    m_maps.push_back(mapping);
    m_map_epochs.push_back(mapping.reset_epoch);
    m_map_local_host_epochs.push_back(local_host_epoch);
    m_map_host_epochs.push_back(coordinator_host_epoch);
    m_map_function_epochs.push_back(function_epoch_value);
    m_map_device_epochs.push_back(device_epoch_value);
    m_map_routes.push_back(mapping.route);
    m_map_uids.push_back(mapping.function_h.function_uid);
    m_map_generations.push_back(mapping.function_h.generation);
    m_map_object_ids.push_back(mapping.function_h.object_id);
    m_map_kinds.push_back(mapping.function_h.kind);
    m_map_owner_valid.push_back(mapping.owner_h != null);
    if (mapping.owner_h == null) begin
      m_map_owner_uids.push_back(0);
      m_map_owner_object_ids.push_back(0);
      m_map_owner_generations.push_back(0);
      m_map_owner_kinds.push_back(RDMA_RESOURCE_FUNCTION);
    end
    else begin
      m_map_owner_uids.push_back(mapping.owner_h.function_uid);
      m_map_owner_object_ids.push_back(mapping.owner_h.object_id);
      m_map_owner_generations.push_back(mapping.owner_h.generation);
      m_map_owner_kinds.push_back(mapping.owner_h.kind);
    end
    m_map_requester_bdfs.push_back(mapping.requester_bdf);
    return status;
  endfunction

  // 功能：验证 mapping 的 route、authority 和 reset ledger 后，将写请求转发到对应 Host manager。
  // 输入/输出及副作用：mapping/offset/data（输入）；校验通过后把写请求转发给 mapping 所在
  //   Host manager，底层 manager 自行维护其 backing 状态。
  // 失败/边界：mapping 被篡改、释放、过期、Host 路由不存在或 reset publication/transaction
  //   active 时不触碰底层 manager；正常 leased dataplane 不需要携带 owner/token。
  function rdma_status write(
    rdma_dma_mapping mapping,
    longint unsigned offset,
    byte data[]
  );
    int index;
    rdma_host_mem_api manager;
    rdma_status status;

    index = find_mapping(mapping);
    status = validate_mapping(mapping, index);
    if (!status.ok())
      return status;
    status = authorize_dataplane_operation("write");
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "Host router dataplane admission returned null"
        ) : status;
    manager = m_managers[mapping.route.host_topology_key];
    if (manager == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Host route manager is null during write"
      );
    status = manager.write(mapping, offset, data);
    return normalize_status(status, "Host manager write");
  endfunction

  // 功能：验证 mapping 后从对应 Host manager 读取指定范围，并通过 data 返回字节数组。
  // 输入/输出及副作用：mapping/offset/size（输入）、data（输出）；函数入口先清空 data，校验
  //   通过后由对应 Host manager 填充读取字节，不取得 mapping 或 manager 所有权。
  // 失败/边界：校验失败或 reset publication/transaction active 时先清空 data 并返回错误，
  //   避免调用方误用旧读数据，也不触碰底层 manager。
  function rdma_status read(
    rdma_dma_mapping mapping,
    longint unsigned offset,
    int unsigned size,
    output byte data[]
  );
    int index;
    rdma_host_mem_api manager;
    rdma_status status;

    data.delete();
    index = find_mapping(mapping);
    // 正常读取仍必须观察当前四维 reset epoch；旧 mapping 的 drain 例外
    // 只适用于下面的 release()，不能让失效 backing 继续暴露数据。
    status = validate_mapping(mapping, index);
    if (!status.ok())
      return status;
    status = authorize_dataplane_operation("read");
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "Host router dataplane admission returned null"
        ) : status;
    manager = m_managers[mapping.route.host_topology_key];
    if (manager == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Host route manager is null during read"
      );
    status = manager.read(mapping, offset, size, data);
    status = normalize_status(status, "Host manager read");
    if (!status.ok())
      data.delete();
    return status;
  endfunction

  // 功能：验证 mapping 后把释放操作交给原 Host manager；底层成功时同步删除所有 parallel
  //       authority ledger，防止同一对象再次被路由访问。
  // 输入/输出及副作用：mapping（输入）；先校验本地 ledger，再调用原 Host manager 释放；底层
  //   成功后同步删除 parallel authority/epoch 数组，失败时保留 ledger 供重试。
  // 失败/边界：校验失败或 manager 释放失败时保留 ledger，便于调用方重试或诊断；reset
  //   publication/transaction active 时仍允许 cleanup admission，保留 stale-drain 语义。
  function rdma_status \release (rdma_dma_mapping mapping);
    int index;
    rdma_host_mem_api manager;
    rdma_status status;

    index = find_mapping(mapping);
    // 释放是 reset recovery 的 drain 操作：仍要求 mapping 与旧 ledger
    // 的 route/identity/epoch 完全一致，但允许当前 reset epoch 已前进。
    status = validate_mapping(mapping, index, 1'b1);
    if (!status.ok())
      return status;
    status = authorize_dataplane_operation("release", 1'b1);
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "Host router cleanup admission returned null"
        ) : status;
    manager = m_managers[mapping.route.host_topology_key];
    if (manager == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Host route manager is null during release"
      );
    status = manager.\release (mapping);
    status = normalize_status(status, "Host manager release");
    if (status.ok())
      delete_mapping_ledgers(index);
    return status;
  endfunction

  // 功能：按 opaque allocation identity 唯一定位 router row，并向该 row 的 stored manager 做只读能力查询。
  // 输入/输出及副作用：mapping 为待验证 authority；只读 parallel ledger 与 manager，不 release 或删除 row。
  // 失败/边界：未知/歧义 row、stored manager 缺失及 manager null/non-OK 均 fail closed 且保持 ledger。
  virtual function rdma_status validate_failure_atomic_release(
    rdma_dma_mapping mapping
  );
    rdma_host_mem_api manager;
    rdma_status status;
    int index;
    int unsigned host_key;

    index = find_mapping(mapping);
    if (index < 0)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "failure-atomic router mapping is unknown or ambiguous"
      );
    host_key = m_map_routes[index].host_topology_key;
    if (!m_managers.exists(host_key) || m_managers[host_key] == null)
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "failure-atomic router stored manager is unavailable"
      );
    manager = m_managers[host_key];
    status = manager.validate_failure_atomic_release(mapping);
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Host manager failure-atomic validation returned null"
      );
    return status;
  endfunction

  // 功能：按 router retained opaque row 选择 stored manager，验证能力后执行 failure-atomic release。
  // 输入/输出及副作用：mapping 为释放 authority；manager 非空 OK 后同步删除 exact parallel-ledger row。
  // 失败/边界：lookup/validator/release 的 null 或 non-OK 均在删除前返回，保留 read/retry
  //   authority；reset active 时允许该入口作为明确 cleanup/rollback seam 排空 mapping。
  virtual function rdma_status release_opaque(rdma_dma_mapping mapping);
    rdma_host_mem_api manager;
    rdma_status status;
    int index;
    int unsigned host_key;

    index = find_mapping(mapping);
    if (index < 0)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "opaque router mapping is unknown or ambiguous"
      );
    status = authorize_dataplane_operation("release_opaque", 1'b1);
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "Host router cleanup admission returned null"
        ) : status;
    host_key = m_map_routes[index].host_topology_key;
    if (!m_managers.exists(host_key) || m_managers[host_key] == null)
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "opaque router stored manager is unavailable"
      );
    manager = m_managers[host_key];

    status = manager.validate_failure_atomic_release(mapping);
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Host manager failure-atomic validation returned null"
      );
    if (!status.ok())
      return status;

    status = manager.release_opaque(mapping);
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Host manager opaque release returned null"
      );
    if (!status.ok())
      return status;

    delete_mapping_ledgers(index);
    return status;
  endfunction

  // 功能：只读预检指定 Host 的 router-local epoch 是否还能安全递增，为 coordinator 的
  //       Host reset 事务提供与本地 mapping ledger 相同的容量边界。
  // 输入/输出及副作用：host_topology_key、owner、token（输入）描述 Host 与可选 lease；
  //       publication_capability（输入）仅由 coordinator 内部预检 seam 携带；函数只读取
  //       m_epochs 和授权状态，返回 OK、INVALID_STATE 或 RESOURCE_EXHAUSTED，不创建 route、
  //       不失效 mapping，也不修改 reset 状态。
  // 失败/边界：Host route 未配置时返回 OK，表示旧兼容语义下没有 router-local ledger 需要
  //       推进；local epoch 已为全一最大值时返回 RESOURCE_EXHAUSTED；无 capability 的 direct
  //       callback 在 coordinator publication active 时返回 RESOURCE_BUSY，不能借公开
  //       allow_active 语义伪装成内部 publication。
  function rdma_status validate_host_epoch_capacity(
    int unsigned host_topology_key,
    uvm_object owner = null,
    longint unsigned token = 0,
    uvm_object publication_capability = null
  );
    rdma_status lease_status;

    if (publication_capability == null)
      // 普通调用只能在 publication guard 未 active 时运行；coordinator 的内部
      // request_host_reset() 通过一次性 capability 走下方专用回验。
      lease_status = authorize_router_operation(owner, token, 1'b1, 1'b0);
    else if (m_reset == null)
      lease_status = rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "Host router epoch capability requires a bound coordinator"
      );
    else
      lease_status = m_reset.authorize_router_epoch_capability(
        this, host_topology_key, 1'b0, publication_capability,
        owner, token
      );
    if (lease_status == null || !lease_status.ok())
      return lease_status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "Host router epoch capacity lease validation returned null"
        ) : lease_status;
    if (!m_epochs.exists(host_topology_key))
      return rdma_status::success();
    if (m_epochs[host_topology_key] == 64'hffff_ffff_ffff_ffff)
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "Host router local reset epoch is exhausted"
      );
    return rdma_status::success();
  endfunction

  // 功能：推进指定 Host 的 router-local epoch，使该 Host 上已有 mapping 在下一次访问时失效，
  //       并把容量/配置错误以 status 返回给共享 reset coordinator。
  // 输入/输出及副作用：host_topology_key、owner、token（输入）选择 Host 与可选 lease；
  //       publication_capability（输入）仅由 coordinator 内部 advance seam 携带；成功时
  //       只递增 m_epochs 中对应值，不创建路由、不直接释放 mapping，返回值供调用方决定是否
  //       继续提交其它 epoch。
  // 失败/边界：Host route 未配置时返回 OK 且保持 m_epochs 不变，以保留空 router fixture 的
  //       no-op 语义；local epoch 已达最大值时返回错误且保持原值；无 capability 的 direct
  //       callback 在 publication active 时被拒绝，函数不会回绕或隐式创建 Host route。
  function rdma_status advance_host_epoch(
    int unsigned host_topology_key,
    uvm_object owner = null,
    longint unsigned token = 0,
    uvm_object publication_capability = null
  );
    rdma_status status;

    if (publication_capability == null)
      status = validate_host_epoch_capacity(
        host_topology_key, owner, token
      );
    else if (m_reset == null)
      status = rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "Host router epoch capability requires a bound coordinator"
      );
    else
      status = m_reset.authorize_router_epoch_capability(
        this, host_topology_key, 1'b1, publication_capability,
        owner, token
      );
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "Host router epoch capacity validation returned null"
        ) : status;
    if (m_epochs.exists(host_topology_key) &&
        m_epochs[host_topology_key] == 64'hffff_ffff_ffff_ffff)
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "Host router local reset epoch is exhausted"
      );
    if (m_epochs.exists(host_topology_key))
      m_epochs[host_topology_key]++;
    return rdma_status::success();
  endfunction

  // 功能：返回指定 Host 的 local、coordinator Host 和 Device epoch 的兼容聚合值，供旧的
  //       可观测性/诊断调用方比较 reset 活动；该值不是 DMA request 或 mapping 的 canonical
  //       reset_epoch，真正的 authority 仍由 Function incarnation 与四个独立 ledger 维度决定。
  // 输入/输出及副作用：host_topology_key（输入）；返回 router-local、coordinator Host 和
  //   Device epoch 的算术和；未配置 Host 时 local 维度为 0，但仍可观察已绑定 coordinator
  //   的 Host/Device 维度；函数只读 ledger，不创建隐式 Host 路由。
  // 失败/边界：聚合值可能在定宽算术下回绕，也可能因不同维度组合相同而产生碰撞；调用方
  //   不得把它写入 request_context.reset_epoch、mapping.reset_epoch 或用它替代逐维 stale
  //   校验。需要 canonical request epoch 时必须先通过 coordinator 的 Function authority seam。
  function rdma_reset_epoch_t host_epoch(int unsigned host_topology_key);
    rdma_reset_epoch_t local_host_epoch;
    rdma_reset_epoch_t coordinator_host_epoch;
    local_host_epoch = m_epochs.exists(host_topology_key) ?
                       m_epochs[host_topology_key] : 0;
    coordinator_host_epoch = (m_reset != null) ?
                             m_reset.host_epoch(host_topology_key) : 0;
    return local_host_epoch + coordinator_host_epoch +
           ((m_reset != null) ? m_reset.device_epoch() : 0);
  endfunction

  // 功能：对 mapping 做边界完整性检查，包括 route、Function/owner authority、requester
  //       BDF、四维 reset epoch 和 manager 存在性；返回错误时禁止任何外部访问。
  // 输入/输出及副作用：mapping（输入）、index（输入）；validate_mapping 读取 mapping、index 并使用字段 local_host_epoch、coordinator_host_epoch、function_epoch_value、device_epoch_value；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate_mapping 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_DMA_TRANSLATION、RDMA_SC_STALE_GENERATION；典型拒绝条件为“unknown DMA mapping”“DMA mapping route was modified”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status validate_mapping(
    rdma_dma_mapping mapping,
    int index,
    bit allow_stale_epoch = 1'b0
  );
    rdma_reset_epoch_t local_host_epoch;
    rdma_reset_epoch_t coordinator_host_epoch;
    rdma_reset_epoch_t function_epoch_value;
    rdma_reset_epoch_t device_epoch_value;
    rdma_reset_epoch_t registered_function_epoch;
    rdma_status authority_status;

    if (mapping == null || index < 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "unknown DMA mapping");
    if (!mapping.route_valid || !rdma_route_key_valid(mapping.route) ||
        !same_route(mapping.route, m_map_routes[index]))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "DMA mapping route was modified");
    if (!mapping.epoch_valid ||
        mapping.reset_epoch != m_map_epochs[index])
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "DMA mapping reset epoch was modified");
    if (mapping.function_h == null ||
        mapping.function_h.kind != m_map_kinds[index] ||
        mapping.function_h.function_uid != m_map_uids[index] ||
        mapping.function_h.object_id != m_map_object_ids[index] ||
        mapping.function_h.generation != m_map_generations[index])
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "DMA mapping Function authority was modified");
    if ((mapping.owner_h != null) != m_map_owner_valid[index])
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "DMA mapping owner authority was modified");
    if (mapping.owner_h != null &&
        (mapping.owner_h.kind != m_map_owner_kinds[index] ||
         mapping.owner_h.function_uid != m_map_owner_uids[index] ||
         mapping.owner_h.object_id != m_map_owner_object_ids[index] ||
         mapping.owner_h.generation != m_map_owner_generations[index]))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "DMA mapping owner authority was modified");
    if (mapping.requester_bdf != m_map_requester_bdfs[index])
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "DMA mapping requester BDF was modified");
    if (!m_managers.exists(mapping.route.host_topology_key))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "Host route not found");

    if (m_reset != null) begin
      if (allow_stale_epoch)
        authority_status =
          m_reset.validate_registered_function_handle_for_drain(
            mapping.function_h,
            mapping.route,
            registered_function_epoch
          );
      else
        authority_status = m_reset.validate_registered_function_handle(
          mapping.function_h,
          mapping.route,
          registered_function_epoch
        );
      if (authority_status == null || !authority_status.ok())
        return authority_status == null ?
          rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "registered Function mapping validation returned null"
          ) : authority_status;
    end

    local_host_epoch = m_epochs.exists(mapping.route.host_topology_key) ?
                       m_epochs[mapping.route.host_topology_key] : 0;
    coordinator_host_epoch = (m_reset != null) ?
      m_reset.host_epoch(mapping.route.host_topology_key) : 0;
    function_epoch_value = (m_reset != null) ?
      registered_function_epoch : 0;
    device_epoch_value = (m_reset != null) ? m_reset.device_epoch() : 0;
    if (!allow_stale_epoch &&
        (local_host_epoch != m_map_local_host_epochs[index] ||
         coordinator_host_epoch != m_map_host_epochs[index] ||
         function_epoch_value != m_map_function_epochs[index] ||
         device_epoch_value != m_map_device_epochs[index]))
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "DMA mapping reset epoch is stale");
    return rdma_status::success();
  endfunction

  // 功能：回滚 manager.allocate 已成功但尚未登记到 router ledger 的 mapping，
  //       避免 authority 校验失败时遗留 Host-memory backing。
  // 输入/输出及副作用：manager/mapping/original_status 为输入；函数最多调用一次
  //       manager.release_opaque(mapping)，不修改 router ledger，并保留 opaque identity
  //       作为底层 cleanup 的唯一释放依据。
  // 失败/边界：底层释放失败时返回 cleanup 错误并保留原始诊断；mapping 为空时原样返回。
  protected function rdma_status rollback_manager_mapping(
    rdma_host_mem_api manager,
    rdma_dma_mapping mapping,
    rdma_status original_status
  );
    rdma_status cleanup_status;

    if (mapping == null)
      return original_status;
    if (manager == null)
      cleanup_status = null;
    else
      // 回滚入口使用 manager 的 opaque identity；mapping 的 public route/geometry
      // 可能正是导致本次校验失败的篡改字段，不能再依赖严格 release()。
      cleanup_status = manager.release_opaque(mapping);
    if (cleanup_status == null || !cleanup_status.ok()) begin
      if (cleanup_status == null)
        cleanup_status = rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "Host manager rollback release returned null"
        );
      return rdma_status::make(
        cleanup_status.code,
        {"Host manager allocation rollback failed: ",
         cleanup_status.message, "; original failure: ",
         original_status == null ? "" : original_status.message}
      );
    end
    return original_status;
  endfunction

  // 功能：保留旧版四维 epoch 聚合 helper 的兼容形状，供仓库外仍编译该 protected seam 的
  //       adapter/测试使用；当前 allocation、mapping ledger 和 stale 校验均不调用它。
  // 输入/输出及副作用：四个独立 epoch（输入）；只读返回定宽算术和，不修改 router ledger，
  //   也不参与 request_context.reset_epoch 或 mapping.reset_epoch 的 authority 生产。
  // 失败/边界：结果允许定宽回绕且可能与另一组维度碰撞；新代码不得用它生成 canonical
  //   request epoch。确认所有外部 protected consumers 消失后，后续批次才可删除该兼容 helper。
  protected function rdma_reset_epoch_t epoch_sum(
    rdma_reset_epoch_t local_host_epoch,
    rdma_reset_epoch_t coordinator_host_epoch,
    rdma_reset_epoch_t function_epoch_value,
    rdma_reset_epoch_t device_epoch_value
  );
    return local_host_epoch + coordinator_host_epoch +
           function_epoch_value + device_epoch_value;
  endfunction

  // 功能：按对象或 opaque release authority 在 router 自有 mapping 列表中定位 ledger 下标。
  // 输入/输出及副作用：mapping（输入）；优先按原对象身份查找，随后调用各 manager mapping
  //       的 authority 等价校验以支持 planner 产生的 detached 快照；不修改数组。
  // 失败/边界：mapping 为空、未知或匹配多个 allocation 时返回 -1，避免释放歧义资源。
  protected function int find_mapping(rdma_dma_mapping mapping);
    int matched_index;
    rdma_status authority_status;

    matched_index = -1;
    if (mapping == null)
      return matched_index;
    foreach (m_maps[index]) begin
      if (m_maps[index] === mapping) begin
        if (matched_index >= 0)
          return -1;
        matched_index = index;
        continue;
      end
      authority_status = m_maps[index].release_authority_status(mapping);
      if (authority_status != null && authority_status.ok()) begin
        if (matched_index >= 0)
          return -1;
        matched_index = index;
      end
    end
    return matched_index;
  endfunction

  // 功能：比较 Host/root/segment/BDF 完整 route key，用于 mapping ledger 一致性校验。
  // 输入/输出及副作用：lhs/rhs（输入值）；只读比较 Host/root/segment/BDF 标量字段，不更新
  //   mapping 或 ledger；该值类型比较没有失败返回路径。
  // 失败/边界：任一路由字段不相等时返回 0；packed route 比较不抛出异常。
  protected function bit same_route(rdma_route_key_t lhs,
                                    rdma_route_key_t rhs);
    return lhs.host_topology_key == rhs.host_topology_key &&
           lhs.root_id == rhs.root_id && lhs.segment == rhs.segment &&
           rdma_bdf_same(lhs.bdf, rhs.bdf);
  endfunction

  // 功能：清空所有 mapping 与 parallel authority ledger；仅在确认没有 active mapping
  //       的 configure() 提交阶段调用。
  // 输入/输出及副作用：无参数；清空 router 自有 mapping 及所有 parallel authority/epoch ledger。
  //   仅由 configure() 在确认无 active mapping 后调用，不负责释放底层 manager backing。
  // 失败/边界：调用方若未先确认无 active mapping，清空会丢失本地索引；函数本身不检查或释放 manager backing。
  protected function void clear_mapping_ledgers();
    m_maps.delete();
    m_map_epochs.delete();
    m_map_local_host_epochs.delete();
    m_map_host_epochs.delete();
    m_map_function_epochs.delete();
    m_map_device_epochs.delete();
    m_map_routes.delete();
    m_map_uids.delete();
    m_map_generations.delete();
    m_map_object_ids.delete();
    m_map_kinds.delete();
    m_map_owner_valid.delete();
    m_map_owner_uids.delete();
    m_map_owner_object_ids.delete();
    m_map_owner_generations.delete();
    m_map_owner_kinds.delete();
    m_map_requester_bdfs.delete();
  endfunction

  // 功能：在 coordinator 绑定生命周期切换后，把 router-local Host epoch 重新锚定到
  //       当前配置的 route 集合，避免旧 env 的 local counter 污染新 coordinator ledger。
  // 输入/输出及副作用：无参数；删除旧 m_epochs 并为 m_managers 中每个已配置 Host 写入零，
  //       不修改 manager 引用、mapping 或外部 backing；调用方必须已确认 mapping 为空。
  // 失败/边界：函数本身不验证 active mapping，也不创建新 Host route；若调用方绕过 attach/
  //       detach 生命周期直接调用会丢失 local stale 记录，因此只允许内部 teardown/rebind seam 使用。
  protected function void reset_local_host_epochs();
    m_epochs.delete();
    foreach (m_managers[host_key])
      m_epochs[host_key] = 0;
  endfunction

  // 功能：按同一 index 同步删除 mapping 的全部 authority/epoch ledger，保持数组对齐。
  // 输入/输出及副作用：index（输入）；从所有 parallel 数组删除同一下标，保持 ledger 对齐。
  //   调用前必须已完成 manager 释放和 index 查找；本函数不校验对象，也不执行底层释放。
  // 失败/边界：index 不存在时各 associative array 的 delete 保持幂等；函数不触发底层 Host-memory release。
  protected function void delete_mapping_ledgers(int index);
    m_maps.delete(index);
    m_map_epochs.delete(index);
    m_map_local_host_epochs.delete(index);
    m_map_host_epochs.delete(index);
    m_map_function_epochs.delete(index);
    m_map_device_epochs.delete(index);
    m_map_routes.delete(index);
    m_map_uids.delete(index);
    m_map_generations.delete(index);
    m_map_object_ids.delete(index);
    m_map_kinds.delete(index);
    m_map_owner_valid.delete(index);
    m_map_owner_uids.delete(index);
    m_map_owner_object_ids.delete(index);
    m_map_owner_generations.delete(index);
    m_map_owner_kinds.delete(index);
    m_map_requester_bdfs.delete(index);
  endfunction
endclass
