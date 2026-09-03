// 中文说明：rdma_host_mem_api.sv 属于适配器接口层，定义主机内存、PCIe、网络及上下文后端接口。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

virtual class rdma_host_mem_api extends uvm_object;

  function new(string name = "rdma_host_mem_api");
    super.new(name);
  endfunction

  pure virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
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
