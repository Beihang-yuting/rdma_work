class rdma_bar_info extends uvm_object;
  `uvm_object_utils(rdma_bar_info)

  bit [2:0] bar_id;
  rdma_bar_addr_t base;
  longint unsigned size;
  bit enabled;

  function new(string name = "rdma_bar_info");
    super.new(name);
    bar_id = '0;
    base = '0;
    size = '0;
    enabled = 1'b0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_bar_info rhs_bar;

    super.do_copy(rhs);
    if (!$cast(rhs_bar, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "rdma_bar_info copy type mismatch")
    bar_id = rhs_bar.bar_id;
    base = rhs_bar.base;
    size = rhs_bar.size;
    enabled = rhs_bar.enabled;
  endfunction
endclass

class rdma_pcie_identity extends uvm_object;
  `uvm_object_utils(rdma_pcie_identity)

  rdma_bdf_t bdf;
  rdma_bdf_t parent_pf_bdf;
  int unsigned vf_index;
  bit mse;
  bit bme;
  rdma_bar_info bar[6];

  function new(string name = "rdma_pcie_identity");
    super.new(name);
    bdf = '0;
    parent_pf_bdf = '0;
    vf_index = '0;
    mse = 1'b0;
    bme = 1'b0;
    foreach (bar[i]) begin
      bar[i] = rdma_bar_info::type_id::create($sformatf("bar_%0d", i));
      bar[i].bar_id = i;
    end
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_pcie_identity rhs_pcie;
    uvm_object cloned_object;

    super.do_copy(rhs);
    if (!$cast(rhs_pcie, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "rdma_pcie_identity copy type mismatch")
    bdf = rhs_pcie.bdf;
    parent_pf_bdf = rhs_pcie.parent_pf_bdf;
    vf_index = rhs_pcie.vf_index;
    mse = rhs_pcie.mse;
    bme = rhs_pcie.bme;
    foreach (bar[i]) begin
      if (rhs_pcie.bar[i] == null) begin
        bar[i] = null;
      end
      else begin
        cloned_object = rhs_pcie.bar[i].clone();
        if (cloned_object == null || !$cast(bar[i], cloned_object))
          `uvm_fatal("RDMA_COPY_TYPE", "rdma_bar_info clone type mismatch")
      end
    end
  endfunction
endclass

class rdma_pcie_function_info extends rdma_pcie_identity;
  `uvm_object_utils(rdma_pcie_function_info)

  function new(string name = "rdma_pcie_function_info");
    super.new(name);
  endfunction
endclass

class rdma_bar_decode extends uvm_object;
  `uvm_object_utils(rdma_bar_decode)

  rdma_bdf_t target_bdf;
  bit [2:0] bar_id;
  longint unsigned bar_offset;

  function new(string name = "rdma_bar_decode");
    super.new(name);
    target_bdf = '0;
    bar_id = '0;
    bar_offset = '0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_bar_decode rhs_decode;

    super.do_copy(rhs);
    if (!$cast(rhs_decode, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "rdma_bar_decode copy type mismatch")
    target_bdf = rhs_decode.target_bdf;
    bar_id = rhs_decode.bar_id;
    bar_offset = rhs_decode.bar_offset;
  endfunction
endclass

typedef struct {
  rdma_bdf_t requester_bdf;
  bit pasid_valid;
  bit [19:0] pasid;
  bit dma_domain_valid;
  int unsigned dma_domain_id;
} rdma_queue_dma_context;

typedef struct {
  int unsigned min_cq_depth;
  int unsigned max_cq_depth;
  int unsigned min_srq_depth;
  int unsigned max_srq_depth;
  int unsigned max_ceq_depth;
  int unsigned max_aeq_depth;
  int unsigned max_wq_sge;
  longint unsigned max_queue_ring_bytes;
  longint unsigned max_sgb_bytes;
} rdma_queue_capabilities;

typedef struct {
  int unsigned function_local_vector;
  int unsigned hardware_eq_vector;
  int unsigned msix_table_index;
  bit enabled;
} rdma_interrupt_vector_binding;

class rdma_function_binding extends uvm_object;
  `uvm_object_utils(rdma_function_binding)

  longint unsigned function_uid;
  rdma_pcie_identity pcie;

  bit [2:0] notify_bar_id;
  rdma_bar_addr_t notify_base;
  longint unsigned notify_size;
  int unsigned notify_table_sel;
  int unsigned notify_table_index;
  int unsigned host_id;
  int unsigned pfvf_id;

  int unsigned rdma_vf_id;
  int unsigned global_function_id;
  int unsigned vsi_id;

  rdma_queue_dma_context queue_dma;
  rdma_queue_capabilities queue_caps;
  rdma_interrupt_vector_binding interrupt_vectors[$];
  rdma_binding_state_e state;
  int unsigned generation;
  rdma_handle owner_h;

  bit notify_valid;
  bit notify_ready;
  bit dmi_valid;
  bit dmi_ready;
  bit vft_valid;
  bit vft_ready;

  function new(string name = "rdma_function_binding");
    super.new(name);
    function_uid = '0;
    pcie = rdma_pcie_identity::type_id::create("pcie");
    notify_bar_id = '0;
    notify_base = '0;
    notify_size = '0;
    notify_table_sel = '0;
    notify_table_index = '0;
    host_id = '0;
    pfvf_id = '0;
    rdma_vf_id = '0;
    global_function_id = '0;
    vsi_id = '0;
    queue_dma = '{default:'0};
    queue_caps = '{default:'0};
    interrupt_vectors.delete();
    state = RDMA_BIND_DISCOVERED;
    generation = '0;
    owner_h = null;
    notify_valid = 1'b0;
    notify_ready = 1'b0;
    dmi_valid = 1'b0;
    dmi_ready = 1'b0;
    vft_valid = 1'b0;
    vft_ready = 1'b0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_function_binding rhs_binding;
    uvm_object cloned_object;

    super.do_copy(rhs);
    if (!$cast(rhs_binding, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "rdma_function_binding copy type mismatch")
    function_uid = rhs_binding.function_uid;
    if (rhs_binding.pcie == null) begin
      pcie = null;
    end
    else begin
      cloned_object = rhs_binding.pcie.clone();
      if (cloned_object == null || !$cast(pcie, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "rdma_pcie_identity clone type mismatch")
    end
    notify_bar_id = rhs_binding.notify_bar_id;
    notify_base = rhs_binding.notify_base;
    notify_size = rhs_binding.notify_size;
    notify_table_sel = rhs_binding.notify_table_sel;
    notify_table_index = rhs_binding.notify_table_index;
    host_id = rhs_binding.host_id;
    pfvf_id = rhs_binding.pfvf_id;
    rdma_vf_id = rhs_binding.rdma_vf_id;
    global_function_id = rhs_binding.global_function_id;
    vsi_id = rhs_binding.vsi_id;
    queue_dma = rhs_binding.queue_dma;
    queue_caps = rhs_binding.queue_caps;
    interrupt_vectors = rhs_binding.interrupt_vectors;
    state = rhs_binding.state;
    generation = rhs_binding.generation;
    if (rhs_binding.owner_h == null) begin
      owner_h = null;
    end
    else begin
      cloned_object = rhs_binding.owner_h.clone();
      if (cloned_object == null || !$cast(owner_h, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "rdma_handle clone type mismatch")
    end
    notify_valid = rhs_binding.notify_valid;
    notify_ready = rhs_binding.notify_ready;
    dmi_valid = rhs_binding.dmi_valid;
    dmi_ready = rhs_binding.dmi_ready;
    vft_valid = rhs_binding.vft_valid;
    vft_ready = rhs_binding.vft_ready;
  endfunction

  function rdma_function_handle make_handle();
    rdma_function_handle handle;

    handle = rdma_function_handle::type_id::create("function_handle");
    handle.kind = RDMA_RESOURCE_FUNCTION;
    handle.function_uid = function_uid;
    handle.object_id = global_function_id;
    handle.generation = generation;
    return handle;
  endfunction

  function bit accepts(rdma_handle handle);
    if (handle == null)
      return 1'b0;
    return handle.kind == RDMA_RESOURCE_FUNCTION &&
           handle.function_uid == function_uid &&
           handle.object_id == global_function_id &&
           handle.generation == generation;
  endfunction

  function rdma_status validate();
    longint unsigned bar_last;
    longint unsigned notify_last;
    rdma_bar_info selected_bar;

    if (pcie == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "PCIe identity is not instantiated");
    if (!queue_dma.pasid_valid && queue_dma.pasid != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "invalid queue PASID must be zero");
    if (queue_dma.requester_bdf != pcie.bdf)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "queue requester BDF does not match PCIe BDF");
    if (queue_caps.min_cq_depth == 0 ||
        queue_caps.max_cq_depth == 0 ||
        queue_caps.min_srq_depth == 0 ||
        queue_caps.max_srq_depth == 0 ||
        queue_caps.max_ceq_depth == 0 ||
        queue_caps.max_aeq_depth == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "queue depth capability is zero");
    if (queue_caps.min_cq_depth > queue_caps.max_cq_depth)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "minimum CQ depth exceeds maximum");
    if (queue_caps.min_srq_depth > queue_caps.max_srq_depth)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "minimum SRQ depth exceeds maximum");
    if (queue_caps.max_wq_sge == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "maximum WQ SGE capability is zero");
    if (queue_caps.max_queue_ring_bytes == 0 ||
        queue_caps.max_sgb_bytes == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "queue ring or SGB byte capability is zero");
    if (rdma_vf_id > 8'hff)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "RDMA VF ID exceeds 8 bits");
    foreach (interrupt_vectors[i]) begin
      for (int j = 0; j < i; j++) begin
        if (interrupt_vectors[j].function_local_vector ==
            interrupt_vectors[i].function_local_vector)
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "interrupt Function-local vector is duplicated"
          );
      end
    end

    foreach (pcie.bar[i]) begin
      if (pcie.bar[i] == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          $sformatf("BAR %0d metadata is not instantiated", i)
        );
    end

    if (notify_size == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "notify aperture size is zero");
    if ((notify_base.value & 64'h0000_0000_0000_1fff) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "notify aperture base is not 8 KiB aligned");
    if (notify_bar_id >= 6)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "notify BAR ID is outside BAR[0:5]");

    selected_bar = pcie.bar[notify_bar_id];
    if (selected_bar.bar_id != notify_bar_id)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "notify BAR metadata ID does not match slot");
    if (!selected_bar.enabled)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "notify BAR is disabled");
    if (selected_bar.size == 0)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "notify BAR size is zero");

    if (selected_bar.base.value >
        (64'hffff_ffff_ffff_ffff - (selected_bar.size - 1'b1)))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "BAR aperture end overflows 64 bits");
    if (notify_base.value >
        (64'hffff_ffff_ffff_ffff - (notify_size - 1'b1)))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "notify aperture end overflows 64 bits");

    bar_last = selected_bar.base.value + selected_bar.size - 1'b1;
    notify_last = notify_base.value + notify_size - 1'b1;
    if (notify_base.value < selected_bar.base.value || notify_last > bar_last)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "notify aperture is outside its BAR");

    if (state == RDMA_BIND_ACTIVE) begin
      if (owner_h == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "ACTIVE binding has no owner handle");
      if (owner_h.kind != RDMA_RESOURCE_FUNCTION ||
          owner_h.function_uid != function_uid ||
          owner_h.object_id != global_function_id)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "ACTIVE binding owner identity does not match");
      if (owner_h.generation != generation)
        return rdma_status::make(RDMA_SC_STALE_GENERATION,
                                 "ACTIVE binding owner generation is stale");
      if (!queue_dma.dma_domain_valid)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "ACTIVE binding has no DMA domain");
      if (!pcie.mse)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "ACTIVE binding requires PCIe MSE");
      if (!pcie.bme)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "ACTIVE binding requires PCIe BME");
      if (!notify_valid || !notify_ready)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "ACTIVE notify state is not valid and ready");
      if (!dmi_valid || !dmi_ready)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "ACTIVE DMI state is not valid and ready");
      if (!vft_valid || !vft_ready)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "ACTIVE VFT state is not valid and ready");
    end

    return rdma_status::success();
  endfunction
endclass
