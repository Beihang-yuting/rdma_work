// 中文说明：验证 integration package 可被仿真入口导入；断言包类型可创建。
class rdma_dpu_integration_test extends uvm_test;
  `uvm_component_utils(rdma_dpu_integration_test)
  function new(string name="rdma_dpu_integration_test", uvm_component parent=null); super.new(name,parent); endfunction
  task run_phase(uvm_phase phase); rdma_dpu_identity_adapter a; phase.raise_objection(this); a=rdma_dpu_identity_adapter::type_id::create("adapter"); if(a==null) `uvm_error("DPU_INT","adapter creation failed"); phase.drop_objection(this); endtask
endclass
