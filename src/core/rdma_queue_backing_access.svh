// Logical access helper for segmented queue backing allocations.
class rdma_queue_backing_span extends uvm_object;
  `uvm_object_utils(rdma_queue_backing_span)
  rdma_dma_mapping mapping;
  longint unsigned mapping_offset;
  longint unsigned logical_offset;
  longint unsigned length;
  function new(string name="rdma_queue_backing_span");
    super.new(name); mapping=null; mapping_offset=0; logical_offset=0; length=0;
  endfunction
endclass

class rdma_queue_backing_access extends uvm_object;
  `uvm_object_utils(rdma_queue_backing_access)
  protected rdma_function_handle owner;
  protected rdma_host_mem_api host_mem;
  protected rdma_backing_ref refs[$];
  protected rdma_qp_backing_ref qp_refs[$];

  function new(string name="rdma_queue_backing_access");
    super.new(name); owner=null; host_mem=null; refs.delete(); qp_refs.delete();
  endfunction

  protected function rdma_status invalid(string m); return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,m); endfunction
  protected function rdma_status state_error(string m); return rdma_status::make(RDMA_SC_INVALID_STATE,m); endfunction
  protected function rdma_status dma_error(string m); return rdma_status::make(RDMA_SC_DMA_TRANSLATION,m); endfunction

  function rdma_status configure(rdma_function_handle function_h,
                                 rdma_host_mem_api api);
    if (function_h==null || function_h.kind!=RDMA_RESOURCE_FUNCTION)
      return invalid("backing access Function is invalid");
    if (function_h.generation==0) return rdma_status::make(RDMA_SC_STALE_GENERATION,"backing access generation is zero");
    if (api==null) return state_error("backing access host memory adapter is null");
    owner=function_h; host_mem=api; refs.delete(); qp_refs.delete(); return rdma_status::success();
  endfunction

  function rdma_status attach_queue(rdma_queue_backing_ref backing);
    rdma_status s;
    if (owner==null || host_mem==null) return state_error("backing access is not configured");
    if (backing==null) return invalid("queue backing reference is null");
    s=backing.validate(); if(!s.ok()) return s;
    if (backing.mapping.function_h==null || !backing.mapping.function_h.same_instance(owner)) return rdma_status::make(RDMA_SC_STALE_GENERATION,"queue backing Function identity mismatch");
    refs.push_back(backing); return rdma_status::success();
  endfunction

  function rdma_status attach_qp(rdma_qp_backing_ref backing);
    rdma_status s;
    if (owner==null || host_mem==null) return state_error("backing access is not configured");
    if (backing==null) return invalid("QP backing reference is null");
    s=backing.validate(); if(!s.ok()) return s;
    if (backing.mapping.function_h==null || !backing.mapping.function_h.same_instance(owner)) return rdma_status::make(RDMA_SC_STALE_GENERATION,"QP backing Function identity mismatch");
    qp_refs.push_back(backing); return rdma_status::success();
  endfunction

  function void clear(); refs.delete(); qp_refs.delete(); endfunction

  protected function rdma_status resolve_ref(
      rdma_queue_backing_ref r, longint unsigned offset,
      longint unsigned length, output rdma_queue_backing_span spans[$]);
    rdma_queue_backing_segment segs[$];
    rdma_queue_backing_span span;
    longint unsigned end_offset, seg_end, overlap_start, overlap_end;
    spans.delete();
    if (length==0 || offset > 64'hffff_ffff_ffff_ffff-length) return dma_error("logical access range overflows");
    if (offset < r.logical_queue_offset || offset+length > r.logical_queue_offset+r.length + r.additional_segments.size()*64'hffff_ffff_ffff_ffff) begin end
    segs.delete();
    span=rdma_queue_backing_span::type_id::create("primary"); span.mapping=r.mapping; span.mapping_offset=r.mapping_offset; span.logical_offset=r.logical_queue_offset; span.length=r.length; segs.push_back(null); // marker unused
    end_offset=offset+length;
    begin
      longint unsigned current_start; longint unsigned current_len; rdma_dma_mapping current_mapping; longint unsigned current_mapoff;
      current_start=r.logical_queue_offset; current_len=r.length; current_mapping=r.mapping; current_mapoff=r.mapping_offset;
      for (int i=-1; i<int'(r.additional_segments.size()); i++) begin
        if (i>=0) begin current_start=r.additional_segments[i].logical_queue_offset; current_len=r.additional_segments[i].length; current_mapping=r.additional_segments[i].mapping; current_mapoff=r.additional_segments[i].mapping_offset; end
        seg_end=current_start+current_len;
        overlap_start=(offset>current_start)?offset:current_start; overlap_end=(end_offset<seg_end)?end_offset:seg_end;
        if (overlap_end>overlap_start) begin
          span=rdma_queue_backing_span::type_id::create($sformatf("span_%0d",spans.size())); span.mapping=current_mapping; span.mapping_offset=current_mapoff+(overlap_start-current_start); span.logical_offset=overlap_start; span.length=overlap_end-overlap_start; spans.push_back(span);
        end
      end
    end
    if (spans.size()==0) return dma_error("logical access is outside backing");
    return rdma_status::success();
  endfunction

  protected function rdma_status resolve_qp_ref(
      rdma_qp_backing_ref r, longint unsigned offset,
      longint unsigned length, output rdma_queue_backing_span spans[$]);
    rdma_queue_backing_ref q; rdma_queue_backing_segment s; rdma_status st;
    q=rdma_queue_backing_ref::type_id::create("qp_as_queue"); q.role=r.role; q.mapping=r.mapping; q.mapping_offset=r.mapping_offset; q.length=r.length; q.logical_queue_offset=0; q.ownership=r.ownership;
    foreach(r.additional_segments[i]) begin s=r.additional_segments[i]; q.additional_segments.push_back(s); end
    st=resolve_ref(q,offset,length,spans); return st;
  endfunction

  function rdma_status resolve(longint unsigned offset, longint unsigned length,
                               output rdma_queue_backing_span spans[$]);
    rdma_status s; spans.delete();
    foreach(refs[i]) begin s=resolve_ref(refs[i],offset,length,spans); if(s.ok()) return s; end
    foreach(qp_refs[i]) begin s=resolve_qp_ref(qp_refs[i],offset,length,spans); if(s.ok()) return s; end
    return dma_error("logical access does not resolve to attached backing");
  endfunction

  protected function rdma_status check_span(rdma_queue_backing_span span,
                                             rdma_dma_direction_e direction);
    rdma_dma_permission_t p; rdma_iova_t iova; rdma_status s;
    if(span==null || span.mapping==null || span.length==0) return invalid("backing span is invalid");
    if(span.mapping_offset > 64'hffff_ffff_ffff_ffff-span.length || span.mapping_offset+span.length > span.mapping.size) return dma_error("backing span exceeds mapping");
    if(span.mapping.iova.value > 64'hffff_ffff_ffff_ffff-span.mapping_offset) return dma_error("backing span IOVA overflows");
    iova.value=span.mapping.iova.value+span.mapping_offset; p='0; p.device_read=(direction==RDMA_DMA_DEVICE_READ); p.device_write=(direction==RDMA_DMA_DEVICE_WRITE); s=span.mapping.check_access(owner,span.mapping.requester_bdf,span.mapping.pasid_valid,span.mapping.pasid,span.mapping.dma_domain_valid,span.mapping.dma_domain_id,iova,span.length,direction,p); if(s==null) return state_error("mapping access returned null"); return s;
  endfunction

  function rdma_status write(longint unsigned offset, byte data[]);
    rdma_queue_backing_span spans[$]; rdma_status s; int unsigned pos; byte chunk[];
    if(data.size()==0) return invalid("backing write data is empty"); s=resolve(offset,data.size(),spans); if(!s.ok()) return s; pos=0; foreach(spans[i]) begin s=check_span(spans[i],RDMA_DMA_DEVICE_READ); if(!s.ok()) return s; chunk=new[spans[i].length]; foreach(chunk[j]) chunk[j]=data[pos+j]; s=host_mem.write(spans[i].mapping,spans[i].mapping_offset,chunk); if(s==null) return state_error("host memory write returned null"); if(!s.ok()) return s; pos+=spans[i].length; end return rdma_status::success();
  endfunction

  function rdma_status read(longint unsigned offset, longint unsigned length, output byte data[]);
    rdma_queue_backing_span spans[$]; rdma_status s; byte chunk[]; int unsigned pos; data=new[0]; if(length==0) return invalid("backing read length is zero"); s=resolve(offset,length,spans); if(!s.ok()) return s; data=new[length]; pos=0; foreach(spans[i]) begin s=check_span(spans[i],RDMA_DMA_DEVICE_WRITE); if(!s.ok()) begin data=new[0]; return s; end chunk=new[0]; s=host_mem.read(spans[i].mapping,spans[i].mapping_offset,spans[i].length,chunk); if(s==null || !s.ok()) begin data=new[0]; return s==null?state_error("host memory read returned null"):s; end if(chunk.size()!=spans[i].length) begin data=new[0]; return dma_error("host memory read returned short data"); end foreach(chunk[j]) data[pos+j]=chunk[j]; pos+=spans[i].length; end return rdma_status::success();
  endfunction
endclass
