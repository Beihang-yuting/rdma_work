class rdma_queue_backing_access_test extends uvm_test;
  `uvm_component_utils(rdma_queue_backing_access_test)
  function new(string name="rdma_queue_backing_access_test", uvm_component parent=null);
    super.new(name,parent);
  endfunction
  function automatic rdma_function_handle fn();
    rdma_function_handle f=rdma_function_handle::type_id::create("f");
    f.function_uid=64'h1234; f.object_id=1; f.generation=2; return f;
  endfunction
  function automatic rdma_dma_request_context ctx();
    rdma_dma_request_context c=rdma_dma_request_context::type_id::create("ctx");
    c.function_h=fn(); c.requester_bdf=16'h0102; c.pasid_valid=1; c.pasid=20'h12345; c.dma_domain_valid=1; c.dma_domain_id=7; return c;
  endfunction
  task run_phase(uvm_phase phase);
    rdma_mock_host_mem mem; rdma_dma_mapping m0,m1; rdma_status s;
    rdma_queue_backing_ref bref; rdma_queue_backing_segment seg;
    rdma_queue_backing_access access; rdma_queue_backing_span spans[$]; byte data[]; byte wr[];
    phase.raise_objection(this);
    mem=rdma_mock_host_mem::type_id::create("mem");
    s=mem.allocate(ctx(),4096,4096,RDMA_DMA_BIDIRECTIONAL,m0);
    if(s==null || !s.ok()) `uvm_error("ALLOC0","allocation failed")
    s=mem.allocate(ctx(),4096,4096,RDMA_DMA_BIDIRECTIONAL,m1);
    if(s==null || !s.ok()) `uvm_error("ALLOC1","allocation failed")
    bref=rdma_queue_backing_ref::type_id::create("ref"); bref.role=RDMA_QUEUE_ROLE_CQ_RING; bref.mapping=m0; bref.length=4096; bref.mapping_offset=0; bref.logical_queue_offset=0; bref.ownership=RDMA_OWNERSHIP_BORROWED;
    seg=rdma_queue_backing_segment::type_id::create("seg"); seg.role=bref.role; seg.mapping=m1; seg.length=4096; seg.mapping_offset=0; seg.logical_queue_offset=4096; seg.ownership=bref.ownership; bref.additional_segments.push_back(seg);
    access=rdma_queue_backing_access::type_id::create("access"); s=access.configure(fn(),mem); if(s==null || !s.ok()) `uvm_error("CONFIG","configure failed");
    s=access.attach_queue(bref); if(s==null || !s.ok()) `uvm_error("ATTACH","attach failed");
    s=access.resolve(4096-8,16,spans); if(s==null || !s.ok() || spans.size()!=2 || spans[0].length!=8 || spans[1].length!=8) `uvm_error("CROSS","cross-segment resolve failed");
    wr=new[16]; foreach(wr[i]) wr[i]=i; s=access.write(4096-8,wr); if(s==null || !s.ok()) `uvm_error("WRITE","multi-span write failed");
    data=new[0]; s=access.read(4096-8,16,data); if(s==null || !s.ok() || data.size()!=16) `uvm_error("READ","multi-span read failed");
    s=access.resolve(1,8,spans); if(s==null || s.ok()) `uvm_error("ALIGN","unaligned resolve accepted");
    phase.drop_objection(this);
  endtask
endclass
