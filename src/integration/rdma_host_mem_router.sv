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

  // 功能：构造未绑定 manager 的 Host route entry。
  // 输入/输出及副作用：name 为对象名；调用方随后填写 Host key 和非拥有 manager 引用。
  // 失败/边界：无。
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

  // m_maps 存 manager 返回、由调用方持有的 mapping；其余平行数组是 router 自有的 authority ledger，
  // release 时必须同步删除，避免与后续 allocation 错位。
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

  // 功能：校验 router 可变入口是否由当前 coordinator lease owner 调用，防止绕过 reset 事务。
  // 输入/输出及副作用：owner/token 描述 lease；require_active 要求 coordinator 事务已开始；
  //   allow_active 仅供 coordinator 授权的 epoch publication seam；只读 m_reset，不改 mapping。
  // 失败/边界：未绑定 coordinator 时保留 legacy 语义；lease 已存在且 owner/token 不符返回
  //   RESOURCE_BUSY；要求 active 但未 begin 返回 INVALID_STATE；active 期间未允许的直接调用被拒绝。
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

  // 功能：把不带 owner/token 的 dataplane 入口接到 coordinator 的 reset-admission seam。
  // 输入/输出及副作用：operation_name 用于诊断；allow_cleanup 仅 release/release_opaque 传入；
  //   只读 admission 状态，返回 rdma_status。
  // 失败/边界：未绑定 coordinator 返回 OK；reset publication/transaction active 时非 cleanup
  //   操作返回 RESOURCE_BUSY；cleanup 继续交给 stale-drain 校验；不提供跨线程互斥。
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

  // 功能：构造空 Host-memory router；路由表由 configure() 发布，ledger 由 allocate() 建立。
  // 输入/输出及副作用：name 为对象名；初始化 reset coordinator 引用。
  // 失败/边界：无。
  function new(string name = "rdma_host_mem_router");
    super.new(name);
    m_reset = null;
  endfunction

  // 功能：经 coordinator legacy facade 连接共享 reset coordinator，维持双侧绑定；只保存非拥有引用。
  // 输入/输出及副作用：coordinator 非空且未被 lease 独占时转发 attach_host_router_status(this)，
  //   成功才更新双方引用；不改 mapping。
  // 失败/边界：null 时保持现有引用；已有 active mapping、跨 coordinator 替换或旧 lease 时被
  //   facade 拒绝；void 入口无法返回错误，需诊断应改用 attach_reset_coordinator_owned()。
  function void attach_reset_coordinator(
    rdma_reset_coordinator coordinator
  );
    if (coordinator != null)
      void'(coordinator.attach_host_router_status(this));
  endfunction

  // 功能：由 coordinator 以受控 seam 校验并绑定/解绑 reset coordinator，返回可观察的结果。
  // 输入/输出及副作用：coordinator 为目标引用；coordinator_initiated 须配合一次性 capability；
  //   成功更新 m_reset，失败保留旧 coordinator、mapping 和 epoch ledger。
  // 失败/边界：目标被其它 lease、现有 mapping 或 active authority 阻挡返回 RESOURCE_BUSY；
  //   缺 capability、null 解绑、跨 coordinator rebind 均 fail-closed。
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
    // null coordinator 的 legacy detach 无法核验双侧 capability，须走
    // coordinator.detach_host_router_owned()，避免只清 router 单侧引用留下反向指针。
    if (m_reset == null && m_maps.size() != 0)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "active router state prevents coordinator attach"
      );
    // 换绑 coordinator 会改变 mapping 读取的 epoch authority；有 active mapping 或旧 lease 时
    // 保持旧绑定；同一 coordinator 重复 attach 是幂等的。
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

  // 功能：在 coordinator 已验证 owner/token 后解除与它的绑定（严格一对一的唯一 detach seam）。
  // 输入/输出及副作用：coordinator/owner/token/capability 为输入；成功清除 m_reset，不释放
  //   mapping 或 backing；capability 回验后即消费，随后由 coordinator 清除反向引用。
  // 失败/边界：coordinator 为空、owner/token 或 capability 不符、绑定不匹配或仍有 mapping
  //   时返回 INVALID_ARGUMENT/RESOURCE_BUSY，保持原绑定。
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

  // 功能：在一次性 capability 和 owner lease 下绑定或确认 coordinator，禁止直接改写 reset ledger。
  // 输入/输出及副作用：coordinator/owner/token/capability 为输入；成功保存非拥有引用，
  //   capability 回验后即消费；返回 status 供 registration commit 判断。
  // 失败/边界：null、owner/token 不符、capability 缺失/伪造、已有 mapping 或绑定了另一
  //   coordinator 时返回 INVALID_ARGUMENT/RESOURCE_BUSY，保留旧 m_reset 与 ledger。
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
    // m_reset 为空时也可能已有 mapping（先配置/分配、再首次 attach）；其 epoch authority 已固定为
    // null-coordinator 视图，不能经 owned attach 换到新 ledger；仅无 mapping 首次绑定或同一
    // coordinator 幂等确认可继续。
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
  // 输入/输出及副作用：entries 逐项给出 Host key 与 manager；先在局部表校验，成功后替换路由
  //   和 local epoch ledger，返回 rdma_status。
  // 失败/边界：lease/publication guard 不通过、存在 active mapping、空 entry、重复 Host 或
  //   manager 跨 Host 复用时拒绝，旧配置保持不变。
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

    // 清空路由表会让在用 backing 失去释放出口，必须事务性拒绝，而非先清表再报错。
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

  // 功能：按请求快照选 Host manager 分配 DMA mapping，并登记 Function/owner/route/BDF 及四维 epoch。
  // 输入/输出及副作用：request_context/size/alignment/direction 为输入；mapping 为输出；
  //   成功时更新 ledger 并发布 mapping。
  // 失败/边界：route/epoch 缺失、Host 未配置、reset active、authority 不匹配或 epoch 过期时
  //   拒绝；拒绝路径不调用 manager，也不发布 mapping row。
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

    // request_snapshot 是 caller 输入的不可变快照；manager 只拿到第二份 detached 副本，
    // 即使其改写 request_context 也不会污染 router 后续比较和 ledger 发布。
    request_snapshot = rdma_dma_request_context::type_id::create(
      "host_dma_request_snapshot");
    if (request_snapshot == null)
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "DMA request snapshot allocation failed"
      );
    request_snapshot.copy(request_context);
    // coordinator 绑定后，Function handle、route、generation 和 reset_epoch 须先通过
    // coordinator 的 registration authority；否则未知 UID 的 function_epoch_uid()==0 哨兵可能
    // 被当作合法初始 epoch，并在 manager.allocate() 产生副作用后才暴露错误。
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
      // success 契约要求 output mapping 带 opaque identity；没有 identity 就没有安全回滚目标，
      // 故把 success+null 报告为 adapter contract violation。
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
    // manager.allocate() 是外部可重入边界，返回前 coordinator 可能已发布 reset；
    // 重新验证 handle/incarnation，失败时 rollback opaque mapping。
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
    // request_context.reset_epoch 只来自 Function identity。Host/Device reset 已级联推进它，
    // 再叠加各 ledger 计数会伪造 epoch，使 reset 重建后的 request context 无法再 allocate。
    // 未绑定 coordinator 时 router-local Host epoch 是唯一可验证的 legacy authority。
    canonical_request_epoch = (m_reset != null) ?
                              function_epoch_value : local_host_epoch;
    if (request_snapshot.reset_epoch != canonical_request_epoch)
      return rollback_manager_mapping(
        manager, manager_mapping,
        rdma_status::make(RDMA_SC_STALE_GENERATION,
                          "DMA request reset epoch is stale"));

    // allocate() 可重入：期间 coordinator 可能进入 reset transaction/publication guard。
    // 该 admission 须紧邻 ledger commit；失败时用 opaque identity 回滚 manager backing，
    // 保持 router/manager 两侧原子。
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
    // 替换 manager 返回的可变 alias，mapping authority 由 router 自有的值快照承载；
    // backing/iova/size 仍由 manager 返回对象提供。
    mapping.function_h = rdma_clone_function_handle_value(
      request_snapshot.function_h, "Host mapping Function");
    if (request_snapshot.owner_h == null)
      mapping.owner_h = null;
    else
      mapping.owner_h = rdma_clone_handle_value(
        request_snapshot.owner_h, "Host mapping owner");
    mapping.route = request_snapshot.route;
    mapping.route_valid = 1'b1;
    // mapping.reset_epoch 须与 Function identity 的 canonical scalar 一致；四个独立 epoch 已存于
    // 平行 ledger，由 validate_mapping() 逐维检查，不能再用聚合值覆盖该字段。
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

  // 功能：校验 mapping 的 route/authority/reset ledger 后，把写请求转发给对应 Host manager。
  // 输入/输出及副作用：mapping/offset/data 为输入；backing 状态由 manager 维护。
  // 失败/边界：mapping 被篡改、已释放、过期、无 Host 路由或 reset active 时不触碰 manager。
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

  // 功能：校验 mapping 后从对应 Host manager 读取指定范围。
  // 输入/输出及副作用：mapping/offset/size 为输入；data 为输出，入口先清空，校验通过后由 manager 填充。
  // 失败/边界：校验失败或 reset active 时 data 保持清空并返回错误，不触碰 manager。
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
    // 读取必须观察当前四维 reset epoch；stale-drain 例外只适用于 release()。
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

  // 功能：校验 mapping 后交给原 Host manager 释放，成功时同步删除全部 parallel ledger。
  // 输入/输出及副作用：mapping 为输入；先校验本地 ledger，再调用 manager 释放。
  // 失败/边界：校验或 manager 释放失败时保留 ledger 以便重试；reset active 时仍允许 cleanup。
  function rdma_status \release (rdma_dma_mapping mapping);
    int index;
    rdma_host_mem_api manager;
    rdma_status status;

    index = find_mapping(mapping);
    // 释放是 reset recovery 的 drain 操作：route/identity/epoch 须与旧 ledger 一致，但允许当前
    // reset epoch 已前进。
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

  // 功能：按 opaque identity 唯一定位 router row，并向其 stored manager 做只读能力查询。
  // 输入/输出及副作用：mapping 为待验证 authority；只读 ledger 与 manager，不删除 row。
  // 失败/边界：row 未知/歧义、manager 缺失或返回 null/non-OK 均 fail closed 并保持 ledger。
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

  // 功能：按保留的 opaque row 选 stored manager，验证能力后执行 failure-atomic release。
  // 输入/输出及副作用：mapping 为释放 authority；manager 返回 OK 后同步删除对应 ledger row。
  // 失败/边界：lookup/validator/release 返回 null 或 non-OK 时不删除 row；reset active 时允许
  //   作为 cleanup/rollback seam 排空 mapping。
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

    status = rdma_status::nonnull(
      manager.validate_failure_atomic_release(mapping),
      "Host manager failure-atomic validation returned null"
    );
    if (!status.ok())
      return status;

    status = rdma_status::nonnull(
      manager.release_opaque(mapping),
      "Host manager opaque release returned null"
    );
    if (!status.ok())
      return status;

    delete_mapping_ledgers(index);
    return status;
  endfunction

  // 功能：只读预检指定 Host 的 router-local epoch 是否还能递增。
  // 输入/输出及副作用：host_topology_key/owner/token 描述 Host 与 lease；publication_capability
  //   仅 coordinator 预检 seam 携带；只读 m_epochs，返回 status，不改状态。
  // 失败/边界：Host 未配置返回 OK；epoch 已达全一最大值返回 RESOURCE_EXHAUSTED；无 capability
  //   的直接调用在 publication active 时返回 RESOURCE_BUSY。
  function rdma_status validate_host_epoch_capacity(
    int unsigned host_topology_key,
    uvm_object owner = null,
    longint unsigned token = 0,
    uvm_object publication_capability = null
  );
    rdma_status lease_status;

    if (publication_capability == null)
      // 普通调用只能在 publication guard 未 active 时运行；coordinator 的 request_host_reset()
      // 通过一次性 capability 走下方专用回验。
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

  // 功能：递增指定 Host 的 router-local epoch，使该 Host 已有 mapping 在下次访问时失效。
  // 输入/输出及副作用：host_topology_key/owner/token 选 Host 与 lease；publication_capability
  //   仅 coordinator advance seam 携带；成功只递增 m_epochs 对应值，不释放 mapping。
  // 失败/边界：Host 未配置返回 OK 且不变；epoch 已达最大值返回错误且保持原值（不回绕）；
  //   无 capability 的直接调用在 publication active 时被拒绝。
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

  // 功能：返回 local、coordinator Host 和 Device epoch 的兼容聚合值，仅供旧的诊断调用方使用。
  // 输入/输出及副作用：host_topology_key 为输入；返回三者算术和；未配置 Host 时 local 为 0；只读。
  // 失败/边界：定宽算术可能回绕或碰撞；不得写入 reset_epoch 或替代逐维 stale 校验，
  //   canonical epoch 须经 coordinator 的 Function authority。
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

  // 功能：校验 mapping 的 route、Function/owner authority、BDF、四维 reset epoch 和 manager。
  // 输入/输出及副作用：mapping 与 ledger index 为输入；返回 rdma_status，只读。
  // 失败/边界：返回 INVALID_ARGUMENT、DMA_TRANSLATION 或 STALE_GENERATION；失败时禁止外部访问。
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

  // 功能：回滚 manager.allocate 已成功但尚未登记 ledger 的 mapping，避免遗留 backing。
  // 输入/输出及副作用：manager/mapping/original_status 为输入；最多调用一次
  //   manager.release_opaque(mapping)，不改 ledger。
  // 失败/边界：释放失败返回 cleanup 错误并保留原始诊断；mapping 为空时原样返回。
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
      // 回滚用 manager 的 opaque identity；mapping 的 public route/geometry 可能正是被篡改的字段，
      // 不能再依赖严格 release()。
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

  // 功能：按对象或 opaque release authority 在 mapping 列表中定位 ledger 下标。
  // 输入/输出及副作用：mapping 为输入；先按对象身份找，再用 authority 等价校验支持 detached 快照；只读。
  // 失败/边界：mapping 为空、未知或匹配多个 allocation 时返回 -1。
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

  // 功能：比较 Host/root/segment/BDF 完整 route key。
  // 输入/输出及副作用：lhs/rhs 为输入值；只读比较标量字段。
  // 失败/边界：任一字段不等返回 0。
  protected function bit same_route(rdma_route_key_t lhs,
                                    rdma_route_key_t rhs);
    return lhs.host_topology_key == rhs.host_topology_key &&
           lhs.root_id == rhs.root_id && lhs.segment == rhs.segment &&
           rdma_bdf_same(lhs.bdf, rhs.bdf);
  endfunction

  // 功能：清空所有 mapping 与 parallel authority ledger；仅在 configure() 确认无 active mapping 后调用。
  // 输入/输出及副作用：无参数；清空 router 自有 mapping 与 ledger，不释放 manager backing。
  // 失败/边界：不检查 active mapping，调用方须先确认，否则丢失本地索引。
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

  // 功能：coordinator 绑定切换后，把 router-local Host epoch 重新锚定到当前 route 集合。
  // 输入/输出及副作用：无参数；删除旧 m_epochs，为每个已配置 Host 写 0；不改 manager 和 mapping。
  // 失败/边界：不验证 active mapping、不创建 Host route；仅限内部 teardown/rebind seam，
  //   调用方须已确认 mapping 为空。
  protected function void reset_local_host_epochs();
    m_epochs.delete();
    foreach (m_managers[host_key])
      m_epochs[host_key] = 0;
  endfunction

  // 功能：按同一 index 删除 mapping 的全部 authority/epoch ledger，保持数组对齐。
  // 输入/输出及副作用：index 为输入；从所有平行数组删除同一下标；不校验对象，不做底层释放。
  // 失败/边界：index 不存在时 delete 幂等。
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
