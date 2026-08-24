virtual class rdma_cmq_port extends uvm_object;
  function new(string name = "rdma_cmq_port");
    super.new(name);
  endfunction

  pure virtual task execute(
    rdma_cmq_command_desc command,
    output rdma_cmq_ticket ticket,
    output rdma_cmq_completion completion,
    output rdma_status status
  );

  pure virtual task reconcile(
    rdma_cmq_ticket ticket,
    output bit terminal_known,
    output rdma_cmq_completion completion,
    output rdma_status status
  );
endclass
