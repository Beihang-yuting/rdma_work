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

  // 功能：构造空 Host-memory router，初始化 reset coordinator 引用；路由表由 configure()
  //       发布，mapping ledger 由 allocate() 建立。
  function new(string name = "rdma_host_mem_router");
    super.new(name);
    m_reset = null;
  endfunction

  // 功能：连接共享 reset coordinator，使 router 能读取 Function/Host/Device epoch。
  // 所有权：只保存非拥有引用，不负责 coordinator 的创建或销毁。
  function void attach_reset_coordinator(
    rdma_reset_coordinator coordinator
  );
    m_reset = coordinator;
  endfunction

  // 功能：事务性校验并替换 Host→manager 路由表，同时重置本地 Host epoch ledger。
  // 边界：存在 active mapping、空 entry、重复 Host 或同一 manager 绑定多个 Host 时拒绝，
  //       旧配置保持不变以保留 mapping 的释放出口。
  function rdma_status configure(rdma_host_mem_route_entry entries[$]);
    rdma_host_mem_api new_managers[int unsigned];
    rdma_reset_epoch_t new_epochs[int unsigned];

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
  // 输入/输出：request_context 描述完整 route 和 authority；mapping 返回 manager backing
  //       的受 router 保护视图。副作用是调用外部 manager.allocate()。
  // 边界：route/epoch 缺失、Host 未配置、manager 返回 authority 不匹配或 epoch 过期时拒绝。
  function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    rdma_dma_request_context request_snapshot;
    rdma_dma_mapping manager_mapping;
    rdma_host_mem_api manager;
    rdma_status status;
    int unsigned host_key;
    rdma_reset_epoch_t local_host_epoch;
    rdma_reset_epoch_t coordinator_host_epoch;
    rdma_reset_epoch_t function_epoch_value;
    rdma_reset_epoch_t device_epoch_value;

    mapping = null;
    if (request_context == null || !request_context.route_valid ||
        !rdma_route_key_valid(request_context.route))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "invalid DMA request route");
    if (!request_context.epoch_valid)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "DMA request reset epoch is required");
    status = request_context.validate();
    if (!status.ok())
      return status;
    host_key = request_context.route.host_topology_key;
    if (!m_managers.exists(host_key))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "Host route not found");

    // manager 不应看到调用方随后可能修改的 Function/owner 对象。传入
    // request snapshot，同时把返回 authority 与该 snapshot 严格比较。
    request_snapshot = rdma_dma_request_context::type_id::create(
      "host_dma_request_snapshot");
    request_snapshot.copy(request_context);
    manager = m_managers[host_key];
    manager_mapping = null;
    status = manager.allocate(request_snapshot, size, alignment, direction,
                              manager_mapping);
    if (!status.ok())
      return status;
    if (manager_mapping == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "manager returned null mapping");
    if (manager_mapping.function_h == null ||
        !manager_mapping.function_h.same_instance(
          request_snapshot.function_h))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "manager returned mismatched Function");
    if ((request_snapshot.owner_h == null) !=
        (manager_mapping.owner_h == null))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "manager returned mismatched owner presence");
    if (request_snapshot.owner_h != null &&
        !manager_mapping.owner_h.same_instance(request_snapshot.owner_h))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "manager returned mismatched owner");
    if (manager_mapping.requester_bdf != request_snapshot.requester_bdf)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "manager returned mismatched requester BDF");

    local_host_epoch = m_epochs.exists(host_key) ? m_epochs[host_key] : 0;
    coordinator_host_epoch = (m_reset != null) ?
                              m_reset.host_epoch(host_key) : 0;
    function_epoch_value = (m_reset != null) ?
      m_reset.function_epoch_uid(request_snapshot.function_h.function_uid) : 0;
    device_epoch_value = (m_reset != null) ? m_reset.device_epoch() : 0;
    if (request_snapshot.reset_epoch !=
        epoch_sum(local_host_epoch, coordinator_host_epoch,
                  function_epoch_value, device_epoch_value))
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "DMA request reset epoch is stale");

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
    mapping.reset_epoch = epoch_sum(local_host_epoch,
                                    coordinator_host_epoch,
                                    function_epoch_value,
                                    device_epoch_value);
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
  // 边界：mapping 被篡改、释放、过期或 Host 路由不存在时不触碰底层 manager。
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
    manager = m_managers[mapping.route.host_topology_key];
    return manager.write(mapping, offset, data);
  endfunction

  // 功能：验证 mapping 后从对应 Host manager 读取指定范围，并通过 data 返回字节数组。
  // 边界：校验失败时先清空 data 并返回错误，避免调用方误用旧读数据。
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
    status = validate_mapping(mapping, index);
    if (!status.ok())
      return status;
    manager = m_managers[mapping.route.host_topology_key];
    return manager.read(mapping, offset, size, data);
  endfunction

  // 功能：验证 mapping 后把释放操作交给原 Host manager；底层成功时同步删除所有 parallel
  //       authority ledger，防止同一对象再次被路由访问。
  // 边界：校验失败或 manager 释放失败时保留 ledger，便于调用方重试或诊断。
  function rdma_status \release (rdma_dma_mapping mapping);
    int index;
    rdma_host_mem_api manager;
    rdma_status status;

    index = find_mapping(mapping);
    status = validate_mapping(mapping, index);
    if (!status.ok())
      return status;
    manager = m_managers[mapping.route.host_topology_key];
    status = manager.\release (mapping);
    if (status.ok())
      delete_mapping_ledgers(index);
    return status;
  endfunction

  // 功能：推进指定 Host 的 router-local epoch，使该 Host 上已有 mapping 在下一次访问时失效。
  // 边界：未配置的 Host 不创建隐式路由或 epoch，保持配置错误可见。
  function void advance_host_epoch(int unsigned host_topology_key);
    if (m_epochs.exists(host_topology_key))
      m_epochs[host_topology_key]++;
  endfunction

  // 功能：返回指定 Host 的 local、coordinator 和 Device epoch 之和，供兼容调用方读取
  //       当前聚合 reset 代数；mapping 内部仍按四个维度分别比较。
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
  protected function rdma_status validate_mapping(
    rdma_dma_mapping mapping,
    int index
  );
    rdma_reset_epoch_t local_host_epoch;
    rdma_reset_epoch_t coordinator_host_epoch;
    rdma_reset_epoch_t function_epoch_value;
    rdma_reset_epoch_t device_epoch_value;

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

    local_host_epoch = m_epochs.exists(mapping.route.host_topology_key) ?
                       m_epochs[mapping.route.host_topology_key] : 0;
    coordinator_host_epoch = (m_reset != null) ?
      m_reset.host_epoch(mapping.route.host_topology_key) : 0;
    function_epoch_value = (m_reset != null) ?
      m_reset.function_epoch_uid(m_map_uids[index]) : 0;
    device_epoch_value = (m_reset != null) ? m_reset.device_epoch() : 0;
    if (local_host_epoch != m_map_local_host_epochs[index] ||
        coordinator_host_epoch != m_map_host_epochs[index] ||
        function_epoch_value != m_map_function_epochs[index] ||
        device_epoch_value != m_map_device_epochs[index])
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "DMA mapping reset epoch is stale");
    return rdma_status::success();
  endfunction

  // 功能：计算四维 epoch 的兼容聚合值，仅用于 mapping 对外字段和旧接口；不会替代逐维校验。
  protected function rdma_reset_epoch_t epoch_sum(
    rdma_reset_epoch_t local_host_epoch,
    rdma_reset_epoch_t coordinator_host_epoch,
    rdma_reset_epoch_t function_epoch_value,
    rdma_reset_epoch_t device_epoch_value
  );
    return local_host_epoch + coordinator_host_epoch +
           function_epoch_value + device_epoch_value;
  endfunction

  // 功能：按对象身份在 router 自有 mapping 列表中定位 ledger 下标；未找到返回 -1。
  protected function int find_mapping(rdma_dma_mapping mapping);
    foreach (m_maps[index])
      if (m_maps[index] === mapping)
        return index;
    return -1;
  endfunction

  // 功能：比较 Host/root/segment/BDF 完整 route key，用于 mapping ledger 一致性校验。
  protected function bit same_route(rdma_route_key_t lhs,
                                    rdma_route_key_t rhs);
    return lhs.host_topology_key == rhs.host_topology_key &&
           lhs.root_id == rhs.root_id && lhs.segment == rhs.segment &&
           rdma_bdf_same(lhs.bdf, rhs.bdf);
  endfunction

  // 功能：清空所有 mapping 与 parallel authority ledger；仅在确认没有 active mapping
  //       的 configure() 提交阶段调用。
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

  // 功能：按同一 index 同步删除 mapping 的全部 authority/epoch ledger，保持数组对齐。
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
