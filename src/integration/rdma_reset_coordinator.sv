// 中文说明：集中管理 Function/Host/Device reset epoch，保证旧 DMA 资源隔离。
class rdma_reset_coordinator extends uvm_object;
  `uvm_object_utils(rdma_reset_coordinator)
  protected rdma_reset_epoch_t m_function_epochs[string];
  protected rdma_reset_epoch_t m_host_epochs[int unsigned];
  protected rdma_reset_epoch_t m_device_epoch;
  protected rdma_host_mem_router m_host_router;
  protected rdma_function_identity m_functions[$];
  function new(string name="rdma_reset_coordinator"); super.new(name); m_device_epoch=0; endfunction
  function void attach_host_router(rdma_host_mem_router router); m_host_router=router; router.attach_reset_coordinator(this); endfunction
  function void register_function(rdma_function_identity identity); if(identity!=null) begin foreach(m_functions[i]) if(m_functions[i].function_uid==identity.function_uid) return; m_functions.push_back(identity); end endfunction
  function rdma_reset_epoch_t function_epoch_uid(longint unsigned uid); foreach(m_functions[i]) if(m_functions[i].function_uid==uid) return function_epoch(m_functions[i]); return 0; endfunction
  function rdma_status request_vf_flr(rdma_function_identity identity);
    if(identity==null) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"null Function identity");
    if(identity.key.function_kind != RDMA_FUNCTION_VF) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"VF FLR requires VF identity");
    if (identity.key.function_kind == RDMA_FUNCTION_PF) begin foreach(m_functions[i]) if(m_functions[i].key.host_topology_key==identity.key.host_topology_key && ((m_functions[i].key.function_kind==RDMA_FUNCTION_PF && rdma_bdf_same(m_functions[i].key.bdf, identity.key.bdf)) || (m_functions[i].key.function_kind==RDMA_FUNCTION_VF && rdma_bdf_same(m_functions[i].key.parent_pf_bdf, identity.key.bdf)))) bump_function(m_functions[i]); end else bump_function(identity); return rdma_status::success();
  endfunction
  function rdma_status request_pf_reset(rdma_function_identity identity);
    bit found;
    if(identity==null) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"null Function identity");
    if(identity.key.function_kind != RDMA_FUNCTION_PF) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"PF reset requires PF identity");
    found = 0;
    foreach(m_functions[i]) if(m_functions[i].key.host_topology_key==identity.key.host_topology_key &&
      ((m_functions[i].key.function_kind==RDMA_FUNCTION_PF && rdma_bdf_same(m_functions[i].key.bdf, identity.key.bdf)) ||
       (m_functions[i].key.function_kind==RDMA_FUNCTION_VF && rdma_bdf_same(m_functions[i].key.parent_pf_bdf, identity.key.bdf)))) begin bump_function(m_functions[i]); found=1; end
    if(!found) bump_function(identity); return rdma_status::success();
  endfunction
  function rdma_status request_host_reset(int unsigned host_topology_key);
    m_host_epochs[host_topology_key] = m_host_epochs.exists(host_topology_key) ? m_host_epochs[host_topology_key]+1 : 1;
    if(m_host_router!=null) m_host_router.advance_host_epoch(host_topology_key);
    foreach(m_functions[i]) if(m_functions[i].key.host_topology_key==host_topology_key) bump_function(m_functions[i]);
    return rdma_status::success();
  endfunction
  function rdma_status request_device_reset(); m_device_epoch++; foreach(m_functions[i]) bump_function(m_functions[i]); return rdma_status::success(); endfunction
  function rdma_reset_epoch_t function_epoch(rdma_function_identity identity);
    if(identity==null) return 0; return m_function_epochs.exists(identity_name(identity)) ? m_function_epochs[identity_name(identity)] : 0;
  endfunction
  function rdma_reset_epoch_t host_epoch(int unsigned host_topology_key);
    return m_host_epochs.exists(host_topology_key) ? m_host_epochs[host_topology_key] : 0;
  endfunction
  function rdma_reset_epoch_t device_epoch(); return m_device_epoch; endfunction
  protected function void bump_function(rdma_function_identity identity);
    string n=identity_name(identity); m_function_epochs[n]=m_function_epochs.exists(n)?m_function_epochs[n]+1:1;
  endfunction
  protected function string identity_name(rdma_function_identity i);
    return $sformatf("%0d:%0d:%0d:%0d:%0d:%0d",i.key.host_topology_key,i.key.root_id,i.key.bdf.segment,i.key.bdf.bus,i.key.bdf.device,i.key.bdf.function_num);
  endfunction
endclass
