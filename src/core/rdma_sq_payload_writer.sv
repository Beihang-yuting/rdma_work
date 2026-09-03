class rdma_sq_payload_write_receipt extends uvm_object;
  `uvm_object_utils(rdma_sq_payload_write_receipt)
  bit verified;
  byte unsigned payload[$];
  rdma_sge sges[$];
  longint unsigned registration_ids[$];
  rdma_dma_mapping mappings[$];
  rdma_function_handle function_h;
  int unsigned function_generation;
  bit released;
  function new(string name="rdma_sq_payload_write_receipt"); super.new(name); verified=0; released=0; endfunction
endclass

virtual class rdma_sq_payload_writer extends uvm_object;
  function new(string name="rdma_sq_payload_writer"); super.new(name); endfunction
  pure virtual function rdma_status configure(rdma_host_mem_api api, rdma_function_binding binding, time timeout);
  pure virtual function rdma_status register_mapping(rdma_dma_mapping mapping, output longint unsigned registration_id);
  pure virtual function rdma_status unregister_mapping(longint unsigned registration_id);
  pure virtual function rdma_status stage_and_verify(rdma_dma_request_context request_context, rdma_sge sges[$], byte unsigned payload[$], output rdma_sq_payload_write_receipt receipt);
  pure virtual function rdma_status release_receipt(rdma_sq_payload_write_receipt receipt);
endclass

class rdma_host_mem_sq_payload_writer extends rdma_sq_payload_writer;
  `uvm_object_utils(rdma_host_mem_sq_payload_writer)
  typedef struct { longint unsigned id; rdma_dma_mapping mapping; int unsigned refs; } registration_t;
  rdma_host_mem_api api;
  rdma_function_binding binding;
  time timeout;
  registration_t regs[$];
  longint unsigned next_id;

  function new(string name="rdma_host_mem_sq_payload_writer"); super.new(name); next_id=1; endfunction
  function rdma_status configure(rdma_host_mem_api a, rdma_function_binding b, time t); api=a; binding=b; timeout=t; return (a==null||b==null) ? rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"null configuration") : rdma_status::success(); endfunction

  function rdma_status register_mapping(rdma_dma_mapping mapping, output longint unsigned registration_id);
    registration_t r; uvm_object o; rdma_dma_mapping mc;
    registration_id=0;
    if (mapping==null) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"null mapping");
    if (mapping.state!=RDMA_MAPPING_ACTIVE || mapping.size==0) return rdma_status::make(RDMA_SC_INVALID_STATE,"mapping inactive/empty");
    if (mapping.iova.value > 64'hffff_ffff_ffff_ffff - (mapping.size-1)) return rdma_status::make(RDMA_SC_DMA_TRANSLATION,"mapping range overflow");
    foreach (regs[i]) begin
      longint unsigned a0,a1,b0,b1;
      a0=regs[i].mapping.iova.value; a1=a0+(regs[i].mapping.size-1);
      b0=mapping.iova.value; b1=b0+mapping.size-1;
      if (!(b0>a1 || a0>b1)) return rdma_status::make(RDMA_SC_RESOURCE_BUSY,"mapping overlaps registration");
    end
    o=mapping.clone(); if(o==null || !$cast(mc,o)) return rdma_status::make(RDMA_SC_INVALID_STATE,"mapping clone failed"); r.mapping=mc; r.id=next_id++; r.refs=0; regs.push_back(r); registration_id=r.id; return rdma_status::success();
  endfunction
  function rdma_status unregister_mapping(longint unsigned registration_id);
    foreach (regs[i]) if (regs[i].id==registration_id) begin
      if (regs[i].refs!=0) return rdma_status::make(RDMA_SC_RESOURCE_BUSY,"registration referenced by receipt");
      regs.delete(i); return rdma_status::success();
    end
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"unknown registration");
  endfunction

  function rdma_status stage_and_verify(rdma_dma_request_context c, rdma_sge sges[$], byte unsigned payload[$], output rdma_sq_payload_write_receipt receipt);
    rdma_status st; registration_t r; int ri; longint unsigned total, off; byte unsigned chunk[$], rb[$]; longint unsigned used_ids[$]; int mapidx[$];
    receipt=null; if (api==null || binding==null) return rdma_status::make(RDMA_SC_INVALID_STATE,"writer not configured");
    st=c==null ? rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"null request context") : c.validate(); if (!st.ok()) return st;
    total=0; foreach(sges[i]) begin
      if (sges[i]==null || sges[i].length==0) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"invalid SGE");
      if (total > 64'hffff_ffff_ffff_ffff - sges[i].length) return rdma_status::make(RDMA_SC_DMA_TRANSLATION,"payload length overflow");
      total += sges[i].length;
    end
    if (total != payload.size()) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"payload length mismatch");
    foreach(sges[i]) begin ri=-1; foreach(regs[j]) begin if (regs[j].mapping.check_access(c.function_h,c.requester_bdf,c.pasid_valid,c.pasid,c.dma_domain_valid,c.dma_domain_id,sges[i].iova,sges[i].length,RDMA_DMA_DEVICE_READ,'{device_read:1'b1,device_write:1'b0,atomic:1'b0}).ok()) begin ri=j; break; end end if (ri<0) return rdma_status::make(RDMA_SC_DMA_TRANSLATION,"no registered mapping for SGE"); mapidx.push_back(ri); regs[ri].refs++; used_ids.push_back(regs[ri].id); end
    off=0; foreach(sges[i]) begin
      ri=mapidx[i];
      r=regs[ri]; chunk.delete(); for(int k=0;k<sges[i].length;k++) chunk.push_back(payload[off+k]);
      st=api.write(r.mapping,sges[i].iova.value-r.mapping.iova.value,chunk); if(!st.ok()) begin foreach(mapidx[q]) regs[mapidx[q]].refs--; return st; end
      st=api.read(r.mapping,sges[i].iova.value-r.mapping.iova.value,sges[i].length,rb); if(!st.ok()) begin foreach(mapidx[q]) regs[mapidx[q]].refs--; return st; end
      if (rb.size()!=chunk.size()) begin foreach(mapidx[q]) regs[mapidx[q]].refs--; return rdma_status::make(RDMA_SC_DMA_TRANSLATION,"staged payload readback mismatch"); end
      foreach(chunk[k]) if (rb[k]!==chunk[k]) begin foreach(mapidx[q]) regs[mapidx[q]].refs--; return rdma_status::make(RDMA_SC_DMA_TRANSLATION,"staged payload readback mismatch"); end
      off += sges[i].length;
    end
    receipt=rdma_sq_payload_write_receipt::type_id::create("receipt"); receipt.verified=1; receipt.payload=payload; receipt.released=0; receipt.function_h=rdma_function_handle::type_id::create("receipt_function"); receipt.function_h.copy(c.function_h); receipt.function_generation=c.function_h.generation;
    foreach(sges[i]) begin rdma_sge cp=rdma_sge::type_id::create("sge"); cp.copy(sges[i]); receipt.sges.push_back(cp); end
    receipt.registration_ids = used_ids;
    foreach(used_ids[i]) foreach(regs[j]) if(regs[j].id==used_ids[i]) begin uvm_object mo=regs[j].mapping.clone(); rdma_dma_mapping mm; if($cast(mm,mo)) receipt.mappings.push_back(mm); end
    return rdma_status::success();
  endfunction
  function rdma_status release_receipt(rdma_sq_payload_write_receipt receipt);
    if (receipt==null || receipt.released) return rdma_status::success();
    foreach(receipt.registration_ids[i]) foreach(regs[j]) if(regs[j].id==receipt.registration_ids[i] && regs[j].refs>0) regs[j].refs--;
    receipt.released=1; return rdma_status::success();
  endfunction
endclass
