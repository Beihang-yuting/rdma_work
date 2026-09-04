// 中文说明：集中管理 Function/Host/Device reset epoch，保证旧 DMA 资源隔离。
class rdma_reset_coordinator extends uvm_object;
  `uvm_object_utils(rdma_reset_coordinator)
  protected rdma_reset_epoch_t m_function_epochs[string];
  protected rdma_reset_epoch_t m_host_epochs[int unsigned];
  protected rdma_reset_epoch_t m_device_epoch;
  function new(string name="rdma_reset_coordinator"); super.new(name); m_device_epoch=0; endfunction
  function rdma_status request_vf_flr(rdma_function_identity identity);
    if(identity==null) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"null Function identity");
    if(identity.key.function_kind != RDMA_FUNCTION_VF) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"VF FLR requires VF identity");
    bump_function(identity); return rdma_status::success();
  endfunction
  function rdma_status request_pf_reset(rdma_function_identity identity);
    if(identity==null) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"null Function identity");
    bump_function(identity); return rdma_status::success();
  endfunction
  function rdma_status request_host_reset(int unsigned host_topology_key);
    m_host_epochs[host_topology_key] = m_host_epochs.exists(host_topology_key) ? m_host_epochs[host_topology_key]+1 : 1;
    return rdma_status::success();
  endfunction
  function rdma_status request_device_reset(); m_device_epoch++; return rdma_status::success(); endfunction
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
