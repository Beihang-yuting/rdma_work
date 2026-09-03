class rdma_sq_payload_writer_test extends uvm_test;
  `uvm_component_utils(rdma_sq_payload_writer_test)
  function new(string name="rdma_sq_payload_writer_test", uvm_component parent=null); super.new(name,parent); endfunction
  virtual task run_phase(uvm_phase phase); phase.raise_objection(this); phase.drop_objection(this); endtask
endclass
