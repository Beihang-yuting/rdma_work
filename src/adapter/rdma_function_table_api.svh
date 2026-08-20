virtual class rdma_function_table_api extends uvm_object;
  function new(string name = "rdma_function_table_api");
    super.new(name);
  endfunction

  pure virtual task program_notify(
    rdma_function_binding binding,
    output rdma_status status
  );

  pure virtual task clear_notify(
    rdma_function_binding binding,
    output rdma_status status
  );

  pure virtual task program_dmi(
    rdma_function_binding binding,
    output rdma_status status
  );

  pure virtual task clear_dmi(
    rdma_function_binding binding,
    output rdma_status status
  );

  pure virtual task program_vft(
    rdma_function_binding binding,
    output rdma_status status
  );

  pure virtual task clear_vft(
    rdma_function_binding binding,
    output rdma_status status
  );
endclass
