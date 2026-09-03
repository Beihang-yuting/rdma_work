// 中文说明：rdma_context_backing_api.sv 属于适配器接口层，定义主机内存、PCIe、网络及上下文后端接口。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

virtual class rdma_context_backing_api extends uvm_object;

  function new(string name = "rdma_context_backing_api");
    super.new(name);
  endfunction

  pure virtual function rdma_status acquire(
    rdma_function_binding binding,
    rdma_resource_kind_e resource_kind,
    int unsigned local_id,
    output rdma_context_backing_ref context_ref
  );

  // RDMA_RESOURCE_QP uses the same stable contract: acquire returns an opaque
  // control-plane-owned 512-byte, 512-byte-aligned QPC slot authority.  The
  // four method signatures intentionally remain shared with CQ/SRQ backing.

  pure virtual function rdma_status write(
    rdma_context_backing_ref context_ref,
    longint unsigned offset,
    byte unsigned data[]
  );

  pure virtual function rdma_status \release (rdma_context_backing_ref context_ref);

  pure virtual function rdma_status query_release_completion(
    rdma_context_backing_ref context_ref,
    output bit complete
  );
endclass
