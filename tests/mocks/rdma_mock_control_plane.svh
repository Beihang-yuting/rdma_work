class rdma_mock_stag_key_policy extends rdma_stag_key_policy;
  `uvm_object_utils(rdma_mock_stag_key_policy)

  bit [7:0] fixed_key;
  int unsigned call_count;

  function new(string name = "rdma_mock_stag_key_policy");
    super.new(name);
    fixed_key = '0;
    call_count = 0;
  endfunction

  virtual function rdma_status derive(
    rdma_mr mr,
    output bit [7:0] stag_key
  );
    call_count++;
    stag_key = fixed_key;
    return rdma_status::success();
  endfunction
endclass
