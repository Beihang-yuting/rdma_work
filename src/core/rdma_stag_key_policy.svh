virtual class rdma_stag_key_policy extends uvm_object;
  function new(string name = "rdma_stag_key_policy");
    super.new(name);
  endfunction

  pure virtual function rdma_status derive(
    rdma_mr mr,
    output bit [7:0] stag_key
  );
endclass

class rdma_incarnation_stag_key_policy extends rdma_stag_key_policy;
  `uvm_object_utils(rdma_incarnation_stag_key_policy)

  function new(string name = "rdma_incarnation_stag_key_policy");
    super.new(name);
  endfunction

  virtual function rdma_status derive(
    rdma_mr mr,
    output bit [7:0] stag_key
  );
    stag_key = '0;
    if (mr == null || mr.handle == null ||
        mr.handle.kind != RDMA_RESOURCE_MR)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "MR STAG key source is invalid");
    stag_key = mr.handle.object_id[7:0];
    return rdma_status::success();
  endfunction
endclass
