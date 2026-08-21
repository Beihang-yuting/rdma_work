class rdma_hmc_lease extends uvm_object;
  `uvm_object_utils(rdma_hmc_lease)

  rdma_function_handle owner;
  rdma_resource_kind_e object_kind;
  rdma_hmc_fvm_addr_t address;
  longint unsigned size;
  longint unsigned alignment;
  bit active;

  function new(string name = "rdma_hmc_lease");
    super.new(name);
    owner = null;
    object_kind = RDMA_RESOURCE_FUNCTION;
    address = '0;
    size = '0;
    alignment = '0;
    active = 1'b0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_hmc_lease rhs_lease;

    super.do_copy(rhs);
    if (!$cast(rhs_lease, rhs))
      `uvm_fatal("HMC_COPY_TYPE", "HMC lease copy type mismatch")
    owner = rdma_clone_function_handle_value(rhs_lease.owner,
                                               "HMC lease owner");
    object_kind = rhs_lease.object_kind;
    address = rhs_lease.address;
    size = rhs_lease.size;
    alignment = rhs_lease.alignment;
    active = rhs_lease.active;
  endfunction
endclass

// One allocator instance represents one monotonic HMC aperture epoch.
// Individual release and release_function() only make leases inactive; they
// intentionally do not reclaim capacity or reuse addresses, so an old
// owner/generation/kind address can never become live again.  Start a new
// aperture epoch by constructing and configuring a new allocator object.
class rdma_hmc_allocator extends uvm_object;
  `uvm_object_utils(rdma_hmc_allocator)

  protected rdma_hmc_fvm_addr_t aperture_base;
  protected rdma_hmc_fvm_addr_t aperture_last;
  protected rdma_hmc_fvm_addr_t next_address;
  protected bit configured;
  protected bit aperture_exhausted;
  protected rdma_hmc_lease leases[string];

  function new(string name = "rdma_hmc_allocator");
    super.new(name);
    aperture_base = '0;
    aperture_last = '0;
    next_address = '0;
    configured = 1'b0;
    aperture_exhausted = 1'b0;
  endfunction

  protected function bit valid_object_kind(rdma_resource_kind_e kind);
    return kind inside {RDMA_RESOURCE_PD, RDMA_RESOURCE_MR,
                        RDMA_RESOURCE_CQ, RDMA_RESOURCE_QP,
                        RDMA_RESOURCE_SRQ, RDMA_RESOURCE_CMQ,
                        RDMA_RESOURCE_CEQ, RDMA_RESOURCE_AEQ};
  endfunction

  protected function bit valid_owner(rdma_function_handle owner);
    return owner != null && owner.kind == RDMA_RESOURCE_FUNCTION;
  endfunction

  protected function string address_key(rdma_hmc_fvm_addr_t address);
    return $sformatf("%016h", address.value);
  endfunction

  protected function rdma_status lease_identity_status(
    rdma_hmc_lease lease,
    rdma_function_handle owner,
    rdma_resource_kind_e object_kind
  );
    if (!valid_owner(owner))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "HMC lease owner is invalid");
    if (!valid_object_kind(object_kind))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "HMC object kind is invalid");
    if (lease == null || lease.owner == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "HMC lease registry is inconsistent");
    if (lease.object_kind != object_kind)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "HMC lease object kind does not match");
    if (lease.owner.function_uid != owner.function_uid ||
        lease.owner.object_id != owner.object_id ||
        lease.owner.kind != owner.kind)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "HMC lease belongs to another Function");
    if (lease.owner.generation != owner.generation)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "HMC lease Function generation is stale");
    if (!lease.owner.same_instance(owner))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "complete HMC Function identity does not match");
    return rdma_status::success();
  endfunction

  function rdma_status configure(
    rdma_hmc_fvm_addr_t base,
    longint unsigned aperture_size
  );
    if (configured || leases.num() != 0)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "HMC aperture is already configured");
    if (aperture_size == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "HMC aperture size is zero");
    if (base.value >
        (64'hffff_ffff_ffff_ffff - (aperture_size - 1'b1)))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "HMC aperture end overflows 64 bits");

    aperture_base = base;
    aperture_last.value = base.value + aperture_size - 1'b1;
    next_address = base;
    configured = 1'b1;
    aperture_exhausted = 1'b0;
    return rdma_status::success();
  endfunction

  function rdma_status allocate(
    rdma_function_handle owner,
    rdma_resource_kind_e object_kind,
    longint unsigned size,
    longint unsigned alignment,
    output rdma_hmc_fvm_addr_t address
  );
    longint unsigned alignment_mask;
    longint unsigned aligned_value;
    longint unsigned allocation_last;
    rdma_hmc_lease lease;
    string key;

    address = '0;
    if (!configured)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "HMC aperture is not configured");
    if (!valid_owner(owner))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "HMC allocation owner is invalid");
    if (!valid_object_kind(object_kind))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "HMC allocation object kind is invalid");
    if (size == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "HMC allocation size is zero");
    if (alignment == 0 || (alignment & (alignment - 1'b1)) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "HMC alignment is not a power of two");
    if (aperture_exhausted)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "HMC aperture is exhausted");

    alignment_mask = alignment - 1'b1;
    if (next_address.value >
        (64'hffff_ffff_ffff_ffff - alignment_mask))
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "HMC alignment addition overflows 64 bits");
    aligned_value = (next_address.value + alignment_mask) & ~alignment_mask;
    if (aligned_value < aperture_base.value ||
        aligned_value > aperture_last.value)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "aligned HMC address is outside aperture");
    if ((size - 1'b1) > (aperture_last.value - aligned_value))
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "HMC allocation exceeds aperture");
    if (aligned_value >
        (64'hffff_ffff_ffff_ffff - (size - 1'b1)))
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "HMC allocation end overflows 64 bits");

    allocation_last = aligned_value + size - 1'b1;
    address.value = aligned_value;
    key = address_key(address);
    if (leases.exists(key)) begin
      address = '0;
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "HMC address incarnation already exists");
    end

    lease = rdma_hmc_lease::type_id::create("lease");
    lease.owner = rdma_clone_function_handle_value(owner,
                                                    "HMC allocation owner");
    lease.object_kind = object_kind;
    lease.address = address;
    lease.size = size;
    lease.alignment = alignment;
    lease.active = 1'b1;
    leases[key] = lease;

    if (allocation_last == aperture_last.value ||
        allocation_last == 64'hffff_ffff_ffff_ffff)
      aperture_exhausted = 1'b1;
    else
      next_address.value = allocation_last + 1'b1;
    return rdma_status::success();
  endfunction

  function rdma_status lookup(
    rdma_function_handle owner,
    rdma_resource_kind_e object_kind,
    rdma_hmc_fvm_addr_t address,
    output longint unsigned size
  );
    string key;
    rdma_status status;

    size = '0;
    if (!configured)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "HMC aperture is not configured");
    key = address_key(address);
    if (!leases.exists(key))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "HMC address is unknown or forged");
    status = lease_identity_status(leases[key], owner, object_kind);
    if (!status.ok())
      return status;
    if (!leases[key].active)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "HMC lease has been released");
    size = leases[key].size;
    return rdma_status::success();
  endfunction

  function rdma_status \release (
    rdma_function_handle owner,
    rdma_resource_kind_e object_kind,
    rdma_hmc_fvm_addr_t address
  );
    string key;
    rdma_status status;

    if (!configured)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "HMC aperture is not configured");
    key = address_key(address);
    if (!leases.exists(key))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "HMC address is unknown or forged");
    status = lease_identity_status(leases[key], owner, object_kind);
    if (!status.ok())
      return status;
    if (!leases[key].active)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "HMC lease is already released");
    leases[key].active = 1'b0;
    return rdma_status::success();
  endfunction

  function rdma_status release_function(rdma_function_handle owner);
    if (!valid_owner(owner))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "HMC Function teardown owner is invalid");
    foreach (leases[key]) begin
      if (leases[key].owner != null &&
          leases[key].owner.same_instance(owner))
        leases[key].active = 1'b0;
    end
    return rdma_status::success();
  endfunction

  function rdma_status check_leaks(
    output int unsigned leak_count,
    input rdma_function_handle owner = null
  );
    leak_count = 0;
    if (owner != null && !valid_owner(owner))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "HMC leak filter is invalid");
    foreach (leases[key]) begin
      if (leases[key].active &&
          (owner == null ||
           (leases[key].owner != null &&
            leases[key].owner.same_instance(owner))))
        leak_count++;
    end
    if (leak_count != 0)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               $sformatf("%0d HMC leases leaked",
                                         leak_count));
    return rdma_status::success();
  endfunction
endclass
