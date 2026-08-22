virtual class rdma_codec_base extends uvm_object;
  function new(string name = "rdma_codec_base");
    super.new(name);
  endfunction

  pure virtual function rdma_status encode(
    rdma_hw_model model,
    output rdma_hw_image image
  );

  pure virtual function rdma_status decode(
    rdma_hw_image image,
    output rdma_hw_model model
  );

  pure virtual function rdma_status validate_model(rdma_hw_model model);

  pure virtual function rdma_status validate_image(rdma_hw_image image);

  virtual function rdma_status serialized_equal(
    rdma_hw_model lhs,
    rdma_hw_model rhs,
    output bit equal,
    output string mismatch
  );
    equal = 1'b0;
    mismatch = "serialized equality is not implemented by this codec";
    return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE, mismatch);
  endfunction

  // Endian is a codec/hardware-profile property.  The generic bit packer
  // deliberately performs no byte swapping.
  pure virtual function rdma_byte_endian_e hardware_endian();

  pure virtual function string describe_fields();
endclass
