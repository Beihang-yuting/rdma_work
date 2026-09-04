// 中文说明：按 host_topology_key 选择 Host-memory manager，并校验 mapping 路由/epoch。
// 创建者：rdma_device_env；所有权：router 不接管 manager 生命周期。
class rdma_host_mem_route_entry extends uvm_object;
  `uvm_object_utils(rdma_host_mem_route_entry)
  int unsigned host_topology_key;
  rdma_host_mem_api manager;
  function new(string name="rdma_host_mem_route_entry"); super.new(name); host_topology_key=0; manager=null; endfunction
endclass

class rdma_host_mem_router extends rdma_host_mem_api;
  `uvm_object_utils(rdma_host_mem_router)
  protected rdma_host_mem_api m_managers[int unsigned];
  protected rdma_reset_epoch_t m_epochs[int unsigned];
  protected rdma_dma_mapping m_maps[$];
  protected rdma_reset_epoch_t m_map_epochs[$];
  function new(string name="rdma_host_mem_router"); super.new(name); endfunction

  function rdma_status configure(rdma_host_mem_route_entry entries[$]);
    rdma_host_mem_api new_managers[int unsigned];
    rdma_reset_epoch_t new_epochs[int unsigned];
    foreach (entries[i]) begin
      if (entries[i] == null || entries[i].manager == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "null Host-memory route entry");
      if (new_managers.exists(entries[i].host_topology_key))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "duplicate Host-memory route");
      foreach (new_managers[k]) if (new_managers[k] === entries[i].manager && k != entries[i].host_topology_key)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "manager bound to multiple Host routes");
      new_managers[entries[i].host_topology_key] = entries[i].manager;
      new_epochs[entries[i].host_topology_key] = 0;
    end
    m_managers = new_managers; m_epochs = new_epochs;
    return rdma_status::success();
  endfunction

  function rdma_status allocate(rdma_dma_request_context request_context,
    int unsigned size, int unsigned alignment, rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping);
    rdma_status s, ctx_status; int unsigned h; rdma_host_mem_api mgr;
    mapping = null;
    if (request_context == null || !request_context.route_valid || !rdma_route_key_valid(request_context.route))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "invalid DMA request context");
    ctx_status = request_context.validate();
    if (!ctx_status.ok()) return ctx_status;
    h = request_context.route.host_topology_key;
    if (!m_managers.exists(h)) return rdma_status::make(RDMA_SC_DMA_TRANSLATION, "Host route not found");
    mgr = m_managers[h];
    s = mgr.allocate(request_context, size, alignment, direction, mapping);
    if (!s.ok() || mapping == null) return s;
    if (mapping.function_h != null && !mapping.function_h.same_instance(request_context.function_h))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION, "manager returned mismatched Function");
    if (mapping.owner_h != null && !mapping.owner_h.same_instance(request_context.function_h))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION, "manager returned mismatched owner");
    if (mapping.requester_bdf != '0 && mapping.requester_bdf != request_context.requester_bdf)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION, "manager returned mismatched requester BDF");
    mapping.route = request_context.route;
    mapping.route_valid = 1'b1;
    mapping.reset_epoch = m_epochs[h];
    mapping.epoch_valid = 1'b1;
    m_maps.push_back(mapping); m_map_epochs.push_back(mapping.reset_epoch);
    return s;
  endfunction

  function rdma_status write(rdma_dma_mapping mapping, longint unsigned offset, byte data[]);
    int idx; rdma_host_mem_api mgr;
    idx = find_mapping(mapping);
    if (idx < 0) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "unknown DMA mapping");
    if (mapping == null || !mapping.route_valid || !rdma_route_key_valid(mapping.route)) return rdma_status::make(RDMA_SC_DMA_TRANSLATION, "DMA mapping route is invalid");
    if (m_map_epochs[idx] != m_epochs[mapping.route.host_topology_key])
      return rdma_status::make(RDMA_SC_STALE_GENERATION, "DMA mapping reset epoch is stale");
    if (!m_managers.exists(mapping.route.host_topology_key)) return rdma_status::make(RDMA_SC_DMA_TRANSLATION, "Host route not found");
    mgr = m_managers[mapping.route.host_topology_key];
    return mgr.write(mapping, offset, data);
  endfunction

  function rdma_status read(rdma_dma_mapping mapping, longint unsigned offset, int unsigned size, output byte data[]);
    int idx; rdma_host_mem_api mgr; data.delete();
    idx = find_mapping(mapping);
    if (idx < 0) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "unknown DMA mapping");
    if (mapping == null || !mapping.route_valid || !rdma_route_key_valid(mapping.route)) return rdma_status::make(RDMA_SC_DMA_TRANSLATION, "DMA mapping route is invalid");
    if (m_map_epochs[idx] != m_epochs[mapping.route.host_topology_key]) return rdma_status::make(RDMA_SC_STALE_GENERATION, "DMA mapping reset epoch is stale");
    if (!m_managers.exists(mapping.route.host_topology_key)) return rdma_status::make(RDMA_SC_DMA_TRANSLATION, "Host route not found");
    mgr = m_managers[mapping.route.host_topology_key];
    return mgr.read(mapping, offset, size, data);
  endfunction

  function rdma_status \release (rdma_dma_mapping mapping);
    int idx; rdma_host_mem_api mgr; rdma_status s;
    idx = find_mapping(mapping);
    if (idx < 0) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "unknown DMA mapping");
    if (mapping == null || !mapping.route_valid || !rdma_route_key_valid(mapping.route)) return rdma_status::make(RDMA_SC_DMA_TRANSLATION, "DMA mapping route is invalid");
    if (m_map_epochs[idx] != m_epochs[mapping.route.host_topology_key]) return rdma_status::make(RDMA_SC_STALE_GENERATION, "DMA mapping reset epoch is stale");
    if (!m_managers.exists(mapping.route.host_topology_key)) return rdma_status::make(RDMA_SC_DMA_TRANSLATION, "Host route not found");
    mgr = m_managers[mapping.route.host_topology_key]; s = mgr.\release (mapping);
    if (s.ok()) begin m_maps.delete(idx); m_map_epochs.delete(idx); end
    return s;
  endfunction

  function void advance_host_epoch(int unsigned host_topology_key);
    if (m_epochs.exists(host_topology_key)) m_epochs[host_topology_key]++;
  endfunction
  function rdma_reset_epoch_t host_epoch(int unsigned host_topology_key);
    return m_epochs.exists(host_topology_key) ? m_epochs[host_topology_key] : 0;
  endfunction
  protected function int find_mapping(rdma_dma_mapping mapping);
    foreach (m_maps[i]) if (m_maps[i] === mapping) return i;
    return -1;
  endfunction
endclass
