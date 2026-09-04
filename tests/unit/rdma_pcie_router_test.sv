// 中文说明：PCIe router 基础未配置拒绝测试。
class rdma_pcie_router_test extends uvm_test;
  `uvm_component_utils(rdma_pcie_router_test)
  function new(string name="rdma_pcie_router_test", uvm_component parent=null); super.new(name,parent); endfunction
  task run_phase(uvm_phase phase); rdma_pcie_router r; rdma_pcie_function_info i; rdma_bdf_t b; rdma_status s; phase.raise_objection(this); r=rdma_pcie_router::type_id::create("router"); b='0; s=r.get_function_info(b,i); if(s.code!=RDMA_SC_DMA_TRANSLATION) `uvm_error("PCIE_ROUTE","missing route was not rejected"); phase.drop_objection(this); endtask
endclass
