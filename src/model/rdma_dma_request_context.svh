class rdma_dma_request_context extends uvm_object;
  `uvm_object_utils(rdma_dma_request_context)

  rdma_function_handle function_h;
  rdma_bdf_t requester_bdf;
  bit pasid_valid;
  bit [19:0] pasid;
  bit dma_domain_valid;
  int unsigned dma_domain_id;
  rdma_handle owner_h;

  function new(string name = "rdma_dma_request_context");
    super.new(name);
    function_h = null;
    requester_bdf = '0;
    pasid_valid = 1'b0;
    pasid = '0;
    dma_domain_valid = 1'b0;
    dma_domain_id = '0;
    owner_h = null;
  endfunction

  function rdma_status validate();
    rdma_status status;

    if (function_h == null || function_h.kind != RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "DMA request Function is invalid");
    if (function_h.generation == 0)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "DMA request Function generation is zero");
    if (!pasid_valid && pasid != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "invalid PASID must be zero");
    if (owner_h != null) begin
      status = rdma_handle_owner_status(owner_h, function_h);
      if (!status.ok())
        return status;
    end
    return rdma_status::success();
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_dma_request_context rhs_context;
    uvm_object cloned_object;

    super.do_copy(rhs);
    if (!$cast(rhs_context, rhs))
      `uvm_fatal("RDMA_COPY_TYPE",
                 "rdma_dma_request_context copy type mismatch")
    if (rhs_context.function_h == null) begin
      function_h = null;
    end
    else begin
      cloned_object = rhs_context.function_h.clone();
      if (cloned_object == null || !$cast(function_h, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE",
                   "DMA request Function clone type mismatch")
    end
    requester_bdf = rhs_context.requester_bdf;
    pasid_valid = rhs_context.pasid_valid;
    pasid = rhs_context.pasid;
    dma_domain_valid = rhs_context.dma_domain_valid;
    dma_domain_id = rhs_context.dma_domain_id;
    if (rhs_context.owner_h == null) begin
      owner_h = null;
    end
    else begin
      cloned_object = rhs_context.owner_h.clone();
      if (cloned_object == null || !$cast(owner_h, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE",
                   "DMA request owner clone type mismatch")
    end
  endfunction
endclass
