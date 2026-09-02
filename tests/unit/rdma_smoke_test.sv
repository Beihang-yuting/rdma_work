class rdma_smoke_test extends uvm_test;
  `uvm_component_utils(rdma_smoke_test)
  function new(string name = "rdma_smoke_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    `uvm_info("RDMA_SMOKE", "rdma core package compiled", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass
