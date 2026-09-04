// 中文说明：Host router 基础拒绝路径测试，确保未配置 Host 不会隐式回退。
class rdma_test_host_mgr extends rdma_host_mem_api;
  `uvm_object_utils(rdma_test_host_mgr)
  int unsigned tag;
  function new(string name="mgr"); super.new(name); tag=0; endfunction
  function rdma_status allocate(rdma_dma_request_context c,int unsigned size,int unsigned alignment,rdma_dma_direction_e d,output rdma_dma_mapping m); m=rdma_dma_mapping::type_id::create("m"); m.state=RDMA_MAPPING_ACTIVE; m.iova.value=tag; m.size=size; return rdma_status::success(); endfunction
  function rdma_status write(rdma_dma_mapping m,longint unsigned o,byte d[]); return rdma_status::success(); endfunction
  function rdma_status read(rdma_dma_mapping m,longint unsigned o,int unsigned s,output byte d[]); d=new[s]; return rdma_status::success(); endfunction
  function rdma_status \release (rdma_dma_mapping m); return rdma_status::success(); endfunction
endclass
class rdma_host_mem_router_test extends uvm_test;
  `uvm_component_utils(rdma_host_mem_router_test)
  function new(string name="rdma_host_mem_router_test", uvm_component parent=null); super.new(name,parent); endfunction
  task run_phase(uvm_phase phase); rdma_host_mem_router r; rdma_host_mem_route_entry e[$]; rdma_test_host_mgr m0,m1; rdma_dma_request_context c; rdma_function_handle h; rdma_dma_mapping map; byte d[]; rdma_status s; phase.raise_objection(this); r=rdma_host_mem_router::type_id::create("router"); m0=rdma_test_host_mgr::type_id::create("m0"); m1=rdma_test_host_mgr::type_id::create("m1"); m0.tag=32'h1000; m1.tag=32'h1000; e.push_back(rdma_host_mem_route_entry::type_id::create("e0")); e[0].host_topology_key=0; e[0].manager=m0; e.push_back(rdma_host_mem_route_entry::type_id::create("e1")); e[1].host_topology_key=1; e[1].manager=m1; s=r.configure(e); if(!s.ok()) `uvm_fatal("HOST_ROUTE","configure failed"); h=rdma_function_handle::type_id::create("h"); h.function_uid=1; h.generation=1; c=rdma_dma_request_context::type_id::create("c"); c.function_h=h; c.route.host_topology_key=1; c.route.root_id=0; c.route.segment=0; c.route.bdf='h0100; c.route_valid=1; s=r.allocate(c,16,4,RDMA_DMA_DEVICE_READ,map); if(!s.ok()||map==null||map.route.host_topology_key!=1) `uvm_error("HOST_ROUTE","Host1 route not selected"); r.advance_host_epoch(1); s=r.read(map,0,1,d); if(s.code!=RDMA_SC_STALE_GENERATION) `uvm_error("HOST_ROUTE","stale epoch was not rejected"); phase.drop_objection(this); endtask
endclass
