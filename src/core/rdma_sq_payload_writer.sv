// 中文说明：本文件实现 staged non-inline payload 的注册、写入和逐字节回读校验。
// 生命周期约束：writer 只借用 caller-owned mapping，不取得 host_mem.release() 权限。

class rdma_sq_payload_write_receipt extends uvm_object;
  // receipt 保存 detached 的 payload/SGE 快照，供后续 record 生命周期使用。
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
  virtual function void do_copy(uvm_object rhs);
    rdma_sq_payload_write_receipt r; super.do_copy(rhs); if(!$cast(r,rhs)) `uvm_fatal("COPY","receipt type"); verified=r.verified; released=r.released; payload=r.payload; registration_ids=r.registration_ids; function_generation=r.function_generation;
    if(r.function_h!=null) begin function_h=rdma_function_handle::type_id::create("fh"); function_h.copy(r.function_h); end
    foreach(r.sges[i]) begin rdma_sge s=rdma_sge::type_id::create("sge"); s.copy(r.sges[i]); sges.push_back(s); end
    foreach(r.mappings[i]) begin rdma_dma_mapping m; uvm_object o=r.mappings[i].clone(); if($cast(m,o)) mappings.push_back(m); end
  endfunction
endclass

virtual class rdma_sq_payload_writer extends uvm_object;
  // 抽象接口把“注册映射”和“写入验证”与队列数据引擎解耦。

  function new(string name="rdma_sq_payload_writer"); super.new(name); endfunction

  pure virtual function rdma_status configure(rdma_host_mem_api api, rdma_function_binding binding, time timeout);

  pure virtual function rdma_status register_mapping(rdma_dma_mapping mapping, output longint unsigned registration_id);

  pure virtual function rdma_status unregister_mapping(longint unsigned registration_id);

  pure virtual function rdma_status stage_and_verify(rdma_dma_request_context request_context, rdma_sge sges[$], byte unsigned payload[$], output rdma_sq_payload_write_receipt receipt);

  pure virtual function rdma_status release_receipt(rdma_sq_payload_write_receipt receipt);
endclass

class rdma_host_mem_sq_payload_writer extends rdma_sq_payload_writer;
  // 默认实现使用真实 rdma_host_mem_api；所有写入前检查必须先完成。
  `uvm_object_utils(rdma_host_mem_sq_payload_writer)
  typedef struct { longint unsigned id; rdma_dma_mapping mapping; int unsigned refs; } registration_t;
  rdma_host_mem_api api;
  rdma_function_binding binding;
  time timeout;
  registration_t regs[$];
  longint unsigned next_id;

  // registration_t 的 refs 记录仍被 receipt 引用的注册项数量。
  function new(string name="rdma_host_mem_sq_payload_writer"); super.new(name); next_id=1; endfunction

  function rdma_status configure(rdma_host_mem_api a, rdma_function_binding b, time t); api=a; binding=b; timeout=t; return (a==null||b==null) ? rdma_status::make(RDMA_SC_INVALID_ARGUMENT,"null configuration") : rdma_status::success(); endfunction

  // 注册只保存 detached authority；重叠区间和溢出必须在登记阶段拒绝。
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

  // 先完成 context、长度、注册项、权限和地址范围检查，再产生任何 host 写入。
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

  // abort 或 SQ record retire 时调用；released 标志保证引用只递减一次。
  function rdma_status release_receipt(rdma_sq_payload_write_receipt receipt);
    if (receipt==null || receipt.released) return rdma_status::success();
    foreach(receipt.registration_ids[i]) foreach(regs[j]) if(regs[j].id==receipt.registration_ids[i] && regs[j].refs>0) regs[j].refs--;
    receipt.released=1; return rdma_status::success();
  endfunction
endclass
