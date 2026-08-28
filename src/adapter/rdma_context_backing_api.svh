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
