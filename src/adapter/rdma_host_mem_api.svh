virtual class rdma_host_mem_api extends uvm_object;
  function new(string name = "rdma_host_mem_api");
    super.new(name);
  endfunction

  pure virtual function rdma_status allocate(
    rdma_function_handle function_h,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );

  pure virtual function rdma_status write(
    rdma_dma_mapping mapping,
    longint unsigned offset,
    byte data[]
  );

  pure virtual function rdma_status read(
    rdma_dma_mapping mapping,
    longint unsigned offset,
    int unsigned size,
    output byte data[]
  );

  pure virtual function rdma_status \release (rdma_dma_mapping mapping);
endclass
