virtual class rdma_cmq_hw_profile extends uvm_object;
  function new(string name = "rdma_cmq_hw_profile");
    super.new(name);
  endfunction

  pure virtual function string profile_name();
  pure virtual function rdma_status validate_profile();
  virtual function rdma_status snapshot_command_body(
    rdma_hw_model source,
    output rdma_hw_model snapshot
  );
    snapshot = null;
    return rdma_status::make(
      RDMA_SC_INVALID_ARGUMENT,
      "CMQ profile does not recognize the command body type"
    );
  endfunction
  virtual function bit same_command_body_value(
    rdma_hw_model lhs,
    rdma_hw_model rhs
  );
    return 1'b0;
  endfunction
  virtual function bit command_body_graph_detached(
    rdma_hw_model source,
    rdma_hw_model snapshot
  );
    return 1'b0;
  endfunction
  pure virtual function rdma_status compose_sqe(
    rdma_cmq_command_desc command,
    rdma_cmq_slot_context slot,
    output rdma_hw_image sqe,
    output rdma_cmq_expected_response expected
  );
  pure virtual function rdma_status inspect_cqe(
    rdma_hw_image raw_cqe,
    bit expected_owner,
    output bit ready,
    output rdma_cmq_decoded_cqe decoded
  );
  pure virtual function rdma_status encode_doorbell(
    rdma_handle cmq_h,
    int unsigned final_pi,
    bit polarity,
    output rdma_hw_image image
  );
endclass
