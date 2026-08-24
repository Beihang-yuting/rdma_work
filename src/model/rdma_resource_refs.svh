typedef enum bit [2:0] {
  RDMA_RESOURCE_NEW        = 3'd0,
  RDMA_RESOURCE_ALLOCATED  = 3'd1,
  RDMA_RESOURCE_PROGRAMMED = 3'd2,
  RDMA_RESOURCE_ACTIVE     = 3'd3,
  RDMA_RESOURCE_QUIESCING  = 3'd4,
  RDMA_RESOURCE_RELEASED   = 3'd5,
  RDMA_RESOURCE_ERROR      = 3'd6
} rdma_resource_state_e;

typedef enum bit {
  RDMA_OWNERSHIP_BORROWED,
  RDMA_OWNERSHIP_CONTROL_PLANE
} rdma_resource_ownership_e;

typedef enum bit [1:0] {
  RDMA_HW_PRESENCE_UNKNOWN,
  RDMA_HW_PRESENCE_PRESENT,
  RDMA_HW_PRESENCE_ABSENT
} rdma_hw_presence_e;

class rdma_backing_ref extends uvm_object;
  `uvm_object_utils(rdma_backing_ref)

  rdma_dma_mapping mapping;
  rdma_resource_ownership_e ownership;
  bit release_complete;

  function new(string name = "rdma_backing_ref");
    super.new(name);
    mapping = null;
    ownership = RDMA_OWNERSHIP_BORROWED;
    release_complete = 1'b0;
  endfunction

  virtual function rdma_status validate();
    if (mapping == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "backing reference mapping is null");
    if (mapping.state != RDMA_MAPPING_ACTIVE && !release_complete)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "live backing reference mapping is not active");
    if (release_complete && ownership == RDMA_OWNERSHIP_BORROWED)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "borrowed backing cannot be marked released");
    return rdma_status::success();
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_backing_ref rhs_ref;
    uvm_object cloned_object;

    super.do_copy(rhs);
    if (!$cast(rhs_ref, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "backing reference copy mismatch")
    ownership = rhs_ref.ownership;
    release_complete = rhs_ref.release_complete;
    if (rhs_ref.mapping == null) begin
      mapping = null;
    end
    else begin
      cloned_object = rhs_ref.mapping.clone();
      if (cloned_object == null || !$cast(mapping, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "backing mapping clone mismatch")
    end
  endfunction
endclass

class rdma_hmc_ref extends uvm_object;
  `uvm_object_utils(rdma_hmc_ref)

  rdma_function_handle owner;
  rdma_resource_kind_e object_kind;
  rdma_hmc_fvm_addr_t address;
  longint unsigned size;
  int unsigned first_pbl_index;
  rdma_resource_ownership_e ownership;
  bit release_complete;

  function new(string name = "rdma_hmc_ref");
    super.new(name);
    owner = null;
    object_kind = RDMA_RESOURCE_MR;
    address = '0;
    size = 0;
    first_pbl_index = 0;
    ownership = RDMA_OWNERSHIP_BORROWED;
    release_complete = 1'b0;
  endfunction

  virtual function rdma_status validate();
    if (owner == null || owner.kind != RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "HMC reference owner is invalid");
    if (object_kind != RDMA_RESOURCE_MR || size == 0 ||
        first_pbl_index == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "MR HMC reference metadata is invalid");
    if (release_complete && ownership == RDMA_OWNERSHIP_BORROWED)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "borrowed HMC reference cannot be released");
    return rdma_status::success();
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_hmc_ref rhs_ref;
    uvm_object cloned_object;

    super.do_copy(rhs);
    if (!$cast(rhs_ref, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "HMC reference copy mismatch")
    if (rhs_ref.owner == null) begin
      owner = null;
    end
    else begin
      cloned_object = rhs_ref.owner.clone();
      if (cloned_object == null || !$cast(owner, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "HMC owner clone mismatch")
    end
    object_kind = rhs_ref.object_kind;
    address = rhs_ref.address;
    size = rhs_ref.size;
    first_pbl_index = rhs_ref.first_pbl_index;
    ownership = rhs_ref.ownership;
    release_complete = rhs_ref.release_complete;
  endfunction
endclass
