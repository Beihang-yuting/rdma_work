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
  protected rdma_reset_epoch_t m_map_function_epochs[$];
  protected rdma_route_key_t m_map_routes[$];
  protected rdma_reset_epoch_t m_map_host_epochs[$], m_map_device_epochs[$];
  protected longint unsigned m_map_uids[$]; protected int unsigned m_map_generations[$];
  protected int unsigned m_map_object_ids[$]; protected rdma_resource_kind_e m_map_kinds[$];
  protected rdma_reset_coordinator m_reset;
  function new(string name="rdma_host_mem_router"); super.new(name); endfunction
  function void attach_reset_coordinator(rdma_reset_coordinator coordinator); m_reset=coordinator; endfunction

  function rdma_status configure(rdma_host_mem_route_entry entries[$]);
    rdma_host_mem_api new_managers[int unsigned];
    rdma_reset_epoch_t new_epochs[int unsigned];
    if (m_maps.size() != 0) return rdma_status::make(RDMA_SC_RESOURCE_BUSY, "active mappings prevent reconfigure");
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
    m_managers = new_managers; m_epochs = new_epochs; m_map_function_epochs.delete(); m_map_routes.delete(); m_map_host_epochs.delete(); m_map_device_epochs.delete(); m_map_uids.delete(); m_map_generations.delete(); m_map_object_ids.delete(); m_map_kinds.delete(); m_map_epochs.delete(); m_maps.delete();
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
    if (!s.ok()) return s;
    if (mapping == null) return rdma_status::make(RDMA_SC_INVALID_STATE, "manager returned null mapping");
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
    mapping.function_h = request_context.function_h;
    mapping.owner_h = request_context.owner_h;
    mapping.requester_bdf = request_context.requester_bdf;
    m_maps.push_back(mapping); m_map_epochs.push_back(mapping.reset_epoch);
    m_map_function_epochs.push_back((m_reset != null) ? m_reset.function_epoch_uid(request_context.function_h.function_uid) : 0);
    m_map_routes.push_back(request_context.route);
    m_map_host_epochs.push_back(m_epochs[h]); m_map_device_epochs.push_back((m_reset != null) ? m_reset.device_epoch() : 0);
    m_map_uids.push_back(request_context.function_h.function_uid); m_map_generations.push_back(request_context.function_h.generation);
    m_map_object_ids.push_back(request_context.function_h.object_id); m_map_kinds.push_back(request_context.function_h.kind);
    return s;
  endfunction

  function rdma_status write(rdma_dma_mapping mapping, longint unsigned offset, byte data[]);
    int idx; rdma_host_mem_api mgr;
    idx = find_mapping(mapping);
    if (idx < 0) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "unknown DMA mapping");
    if (!same_route(mapping.route, m_map_routes[idx]) || mapping.function_h==null || mapping.function_h.function_uid!=m_map_uids[idx] || mapping.function_h.generation!=m_map_generations[idx] || mapping.function_h.object_id!=m_map_object_ids[idx] || mapping.function_h.kind!=m_map_kinds[idx]) return rdma_status::make(RDMA_SC_DMA_TRANSLATION, "DMA mapping authority was modified");
    if (mapping == null || !mapping.route_valid || !rdma_route_key_valid(mapping.route)) return rdma_status::make(RDMA_SC_DMA_TRANSLATION, "DMA mapping route is invalid");
    if (m_map_epochs[idx] != current_epoch(mapping.route.host_topology_key, idx) || m_map_host_epochs[idx] != current_host_epoch(mapping.route.host_topology_key) || m_map_device_epochs[idx] != current_device_epoch())
      return rdma_status::make(RDMA_SC_STALE_GENERATION, "DMA mapping reset epoch is stale");
    if (!m_managers.exists(mapping.route.host_topology_key)) return rdma_status::make(RDMA_SC_DMA_TRANSLATION, "Host route not found");
    mgr = m_managers[mapping.route.host_topology_key];
    return mgr.write(mapping, offset, data);
  endfunction

  function rdma_status read(rdma_dma_mapping mapping, longint unsigned offset, int unsigned size, output byte data[]);
    int idx; rdma_host_mem_api mgr; data.delete();
    idx = find_mapping(mapping);
    if (idx < 0) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "unknown DMA mapping");
    if (!same_route(mapping.route, m_map_routes[idx]) || mapping.function_h==null || mapping.function_h.function_uid!=m_map_uids[idx] || mapping.function_h.generation!=m_map_generations[idx] || mapping.function_h.object_id!=m_map_object_ids[idx] || mapping.function_h.kind!=m_map_kinds[idx]) return rdma_status::make(RDMA_SC_DMA_TRANSLATION, "DMA mapping authority was modified");
    if (mapping == null || !mapping.route_valid || !rdma_route_key_valid(mapping.route)) return rdma_status::make(RDMA_SC_DMA_TRANSLATION, "DMA mapping route is invalid");
    if (m_map_epochs[idx] != current_epoch(mapping.route.host_topology_key, idx) || m_map_host_epochs[idx] != current_host_epoch(mapping.route.host_topology_key) || m_map_device_epochs[idx] != current_device_epoch()) return rdma_status::make(RDMA_SC_STALE_GENERATION, "DMA mapping reset epoch is stale");
    if (!m_managers.exists(mapping.route.host_topology_key)) return rdma_status::make(RDMA_SC_DMA_TRANSLATION, "Host route not found");
    mgr = m_managers[mapping.route.host_topology_key];
    return mgr.read(mapping, offset, size, data);
  endfunction

  function rdma_status \release (rdma_dma_mapping mapping);
    int idx; rdma_host_mem_api mgr; rdma_status s;
    idx = find_mapping(mapping);
    if (idx < 0) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "unknown DMA mapping");
    if (!same_route(mapping.route, m_map_routes[idx]) || mapping.function_h==null || mapping.function_h.function_uid!=m_map_uids[idx] || mapping.function_h.generation!=m_map_generations[idx] || mapping.function_h.object_id!=m_map_object_ids[idx] || mapping.function_h.kind!=m_map_kinds[idx]) return rdma_status::make(RDMA_SC_DMA_TRANSLATION, "DMA mapping authority was modified");
    if (mapping == null || !mapping.route_valid || !rdma_route_key_valid(mapping.route)) return rdma_status::make(RDMA_SC_DMA_TRANSLATION, "DMA mapping route is invalid");
    if (m_map_epochs[idx] != current_epoch(mapping.route.host_topology_key, idx) || m_map_host_epochs[idx] != current_host_epoch(mapping.route.host_topology_key) || m_map_device_epochs[idx] != current_device_epoch()) return rdma_status::make(RDMA_SC_STALE_GENERATION, "DMA mapping reset epoch is stale");
    if (!m_managers.exists(mapping.route.host_topology_key)) return rdma_status::make(RDMA_SC_DMA_TRANSLATION, "Host route not found");
    mgr = m_managers[mapping.route.host_topology_key]; s = mgr.\release (mapping);
    if (s.ok()) begin m_maps.delete(idx); m_map_epochs.delete(idx); m_map_function_epochs.delete(idx); m_map_routes.delete(idx); m_map_host_epochs.delete(idx); m_map_device_epochs.delete(idx); m_map_uids.delete(idx); m_map_generations.delete(idx); m_map_object_ids.delete(idx); m_map_kinds.delete(idx); end
    return s;
  endfunction

  function void advance_host_epoch(int unsigned host_topology_key);
    if (m_epochs.exists(host_topology_key)) m_epochs[host_topology_key]++;
  endfunction
  function rdma_reset_epoch_t host_epoch(int unsigned host_topology_key);
    return current_epoch(host_topology_key);
  endfunction
  protected function rdma_reset_epoch_t current_epoch(int unsigned host_topology_key, int idx=-1);
    rdma_reset_epoch_t e;
    if (m_reset != null) begin e = m_reset.host_epoch(host_topology_key); if(m_epochs.exists(host_topology_key) && m_epochs[host_topology_key]>e)e=m_epochs[host_topology_key]; e = (m_reset.device_epoch()>e)?m_reset.device_epoch():e; if(idx>=0 && m_maps[idx].function_h!=null && m_reset.function_epoch_uid(m_maps[idx].function_h.function_uid)>e) e=m_reset.function_epoch_uid(m_maps[idx].function_h.function_uid); return e; end
    return m_epochs.exists(host_topology_key) ? m_epochs[host_topology_key] : 0;
  endfunction
  protected function rdma_reset_epoch_t current_host_epoch(int unsigned h); return m_reset!=null ? m_reset.host_epoch(h) : (m_epochs.exists(h)?m_epochs[h]:0); endfunction
  protected function rdma_reset_epoch_t current_device_epoch(); return m_reset!=null ? m_reset.device_epoch() : 0; endfunction
  protected function int find_mapping(rdma_dma_mapping mapping);
    foreach (m_maps[i]) if (m_maps[i] === mapping) return i;
    return -1;
  endfunction
  protected function bit same_route(rdma_route_key_t a, rdma_route_key_t b);
    return a.host_topology_key==b.host_topology_key && a.root_id==b.root_id && a.segment==b.segment && rdma_bdf_same(a.bdf,b.bdf);
  endfunction
endclass
