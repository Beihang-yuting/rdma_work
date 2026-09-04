// 中文说明：PCIe router 以 Host/root/segment/BDF 完整键选择 endpoint，拒绝歧义 BDF。
// endpoint 生命周期由外部环境管理，router 仅保存非拥有引用。
class rdma_pcie_route_entry extends uvm_object;
  `uvm_object_utils(rdma_pcie_route_entry)
  rdma_route_key_t route;
  rdma_pcie_api endpoint;
  function new(string name="rdma_pcie_route_entry"); super.new(name); route='0; endpoint=null; endfunction
endclass

class rdma_pcie_router extends rdma_pcie_api;
  `uvm_object_utils(rdma_pcie_router)
  protected rdma_pcie_route_entry m_entries[$];
  function new(string name="rdma_pcie_router"); super.new(name); endfunction
  function rdma_status configure(rdma_pcie_route_entry entries[$]);
    m_entries.delete();
    foreach (entries[i]) begin
      if (entries[i] == null || entries[i].endpoint == null || !rdma_route_key_valid(entries[i].route))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "invalid PCIe route entry");
      foreach (m_entries[j]) if (same_route(m_entries[j].route, entries[i].route))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "duplicate PCIe route");
      m_entries.push_back(entries[i]);
    end
    return rdma_status::success();
  endfunction
  task cfg_read32(rdma_bdf_t target, rdma_cfg_offset_t offset, output bit [31:0] data, output rdma_status status);
    rdma_pcie_api ep; data='0; ep=endpoint_for_bdf(target,status); if (ep==null) return; ep.cfg_read32(target,offset,data,status);
  endtask
  task cfg_write32(rdma_bdf_t target, rdma_cfg_offset_t offset, bit [31:0] data, bit [3:0] byte_enable, output rdma_status status);
    rdma_pcie_api ep; ep=endpoint_for_bdf(target,status); if (ep==null) return; ep.cfg_write32(target,offset,data,byte_enable,status);
  endtask
  task mmio_write(rdma_function_handle function_h, rdma_bar_addr_t address, byte data[], output rdma_status status);
    rdma_pcie_api ep; ep=endpoint_for_handle(function_h,status); if (ep==null) return; ep.mmio_write(function_h,address,data,status);
  endtask
  task dma_visibility_barrier(rdma_function_handle function_h, output rdma_status status);
    rdma_pcie_api ep; ep=endpoint_for_handle(function_h,status); if (ep==null) return; ep.dma_visibility_barrier(function_h,status);
  endtask
  task mmio_ordering_barrier(rdma_function_handle function_h, output rdma_status status);
    rdma_pcie_api ep; ep=endpoint_for_handle(function_h,status); if (ep==null) return; ep.mmio_ordering_barrier(function_h,status);
  endtask
  function rdma_status get_function_info(rdma_bdf_t bdf, output rdma_pcie_function_info info);
    rdma_status status; rdma_pcie_api ep; info=null; ep=endpoint_for_bdf(bdf,status); if(ep==null)return status; return ep.get_function_info(bdf,info);
  endfunction
  function rdma_status decode_bar(rdma_bar_addr_t address, output rdma_bar_decode result);
    rdma_bar_decode candidate; rdma_status s; int hits;
    result=null; hits=0;
    foreach(m_entries[i]) begin
      candidate=null; s=m_entries[i].endpoint.decode_bar(address,candidate);
      if(s.ok() && candidate!=null) begin hits++; result=candidate; end
    end
    if(hits==1) return rdma_status::success();
    if(hits>1) begin result=null; return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"ambiguous BAR address; route required"); end
    return rdma_status::make(RDMA_SC_DMA_TRANSLATION,"BAR address route not found");
  endfunction
  function bit resolve_route(rdma_route_key_t route, output rdma_pcie_api endpoint);
    endpoint=null; foreach(m_entries[i]) if(same_route(m_entries[i].route,route)) begin endpoint=m_entries[i].endpoint; return 1; end return 0;
  endfunction
  protected function bit same_route(rdma_route_key_t a, rdma_route_key_t b);
    return a.host_topology_key==b.host_topology_key && a.root_id==b.root_id && a.segment==b.segment && rdma_bdf_same(a.bdf,b.bdf);
  endfunction
  protected function rdma_pcie_api endpoint_for_bdf(rdma_bdf_t bdf, output rdma_status status);
    rdma_pcie_api ep; bit found; ep=null; found=0;
    foreach(m_entries[i]) if(rdma_bdf_same(m_entries[i].route.bdf,bdf)) begin if(found) begin status=rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"ambiguous PCIe BDF; route required"); return null; end found=1; ep=m_entries[i].endpoint; end
    if(!found) status=rdma_status::make(RDMA_SC_DMA_TRANSLATION,"PCIe BDF route not found"); else status=rdma_status::success(); return ep;
  endfunction
  protected function rdma_pcie_api endpoint_for_handle(rdma_function_handle h, output rdma_status status);
    rdma_pcie_api ep; int match_count; ep=null; match_count=0;
    if(h==null) begin status=rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"null Function handle"); return null; end
    foreach(m_entries[i]) begin rdma_pcie_function_info info; if(m_entries[i].endpoint.get_function_info(m_entries[i].route.bdf,info).ok() && info != null && info.bdf == m_entries[i].route.bdf) begin match_count++; ep=m_entries[i].endpoint; end end
    if(match_count!=1) begin status=rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"ambiguous Function route; full identity required"); return null; end
    status=rdma_status::success(); return ep;
  endfunction
endclass
