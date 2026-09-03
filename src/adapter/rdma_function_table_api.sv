// 中文说明：rdma_function_table_api.sv 属于适配器接口层，定义主机内存、PCIe、网络及上下文后端接口。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

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
