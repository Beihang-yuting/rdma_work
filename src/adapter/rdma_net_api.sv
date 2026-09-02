virtual class rdma_net_observer extends uvm_object;
  function new(string name = "rdma_net_observer");
    super.new(name);
  endfunction

  pure virtual function void write(rdma_packet packet);
endclass

virtual class rdma_net_api extends uvm_object;
  function new(string name = "rdma_net_api");
    super.new(name);
  endfunction

  pure virtual task send_packet(
    rdma_packet packet,
    output rdma_status status
  );

  pure virtual task receive_packet(
    output rdma_packet packet,
    output rdma_status status
  );

  pure virtual function void register_observer(rdma_net_observer observer);

  pure virtual function rdma_status configure_response_policy(
    rdma_net_response_policy policy
  );

  pure virtual function rdma_status inject_fault(rdma_net_fault fault);
endclass
