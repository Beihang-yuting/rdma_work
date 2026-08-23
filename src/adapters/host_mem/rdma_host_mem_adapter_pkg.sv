package rdma_host_mem_adapter_pkg;
  import uvm_pkg::*;
  import host_mem_pkg::*;
  import rdma_types_pkg::*;
  import rdma_model_pkg::*;
  import rdma_adapter_pkg::*;
  `include "uvm_macros.svh"

  // Handle identity is intentionally opaque.  It is shared by value-like
  // mapping copies, but there is no numeric token or public identity getter.
  class rdma_host_mem_allocation_identity extends uvm_object;
    `uvm_object_utils(rdma_host_mem_allocation_identity)

    function new(string name = "rdma_host_mem_allocation_identity");
      super.new(name);
    endfunction
  endclass

  class rdma_host_mem_mapping extends rdma_dma_mapping;
    `uvm_object_utils(rdma_host_mem_mapping)

    local rdma_host_mem_allocation_identity allocation_identity;

    function new(string name = "rdma_host_mem_mapping");
      super.new(name);
      allocation_identity = null;
    endfunction

    function rdma_status initialize_allocation_identity();
      if (allocation_identity != null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "host memory allocation identity is already initialized"
        );
      allocation_identity =
        rdma_host_mem_allocation_identity::type_id::create(
          "allocation_identity"
        );
      if (allocation_identity == null)
        return rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "host memory allocation identity creation failed"
        );
      return rdma_status::success();
    endfunction

    function bit same_allocation(rdma_host_mem_mapping rhs);
      if (rhs == null)
        return 1'b0;
      return allocation_identity != null &&
             rhs.allocation_identity != null &&
             allocation_identity == rhs.allocation_identity;
    endfunction

    function rdma_status make_authority_snapshot(
      output rdma_host_mem_mapping snapshot
    );
      rdma_host_mem_mapping candidate;
      rdma_function_handle function_copy;
      rdma_handle owner_copy;
      uvm_object cloned_object;

      snapshot = null;
      if (allocation_identity == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "host memory allocation identity is not initialized"
        );
      if (function_h == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "DMA mapping Function is null");
      candidate = rdma_host_mem_mapping::type_id::create(
        {get_name(), "_authority"}
      );
      if (candidate == null)
        return rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "DMA mapping authority creation failed"
        );

      cloned_object = function_h.clone();
      if (cloned_object == null || !$cast(function_copy, cloned_object) ||
          function_copy == function_h)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "DMA mapping Function clone failed");
      if (!function_copy.same_instance(function_h))
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "DMA mapping Function clone changed identity"
        );

      owner_copy = null;
      if (owner_h != null) begin
        cloned_object = owner_h.clone();
        if (cloned_object == null || !$cast(owner_copy, cloned_object) ||
            owner_copy == owner_h)
          return rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "DMA mapping owner clone failed");
        if (!owner_copy.same_instance(owner_h))
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "DMA mapping owner clone changed identity"
          );
      end

      candidate.function_h = function_copy;
      candidate.requester_bdf = requester_bdf;
      candidate.pasid_valid = pasid_valid;
      candidate.pasid = pasid;
      candidate.backing_addr = backing_addr;
      candidate.iova = iova;
      candidate.size = size;
      candidate.direction = direction;
      candidate.permissions = permissions;
      candidate.state = state;
      candidate.owner_h = owner_copy;
      candidate.allocation_identity = allocation_identity;
      snapshot = candidate;
      return rdma_status::success();
    endfunction

    virtual function void do_copy(uvm_object rhs);
      rdma_host_mem_mapping rhs_mapping;
      rdma_host_mem_allocation_identity destination_identity;

      destination_identity = allocation_identity;
      super.do_copy(rhs);
      if (!$cast(rhs_mapping, rhs))
        `uvm_fatal("HOST_MEM_COPY",
                   "host memory DMA mapping copy type mismatch")
      if (destination_identity != null) begin
        // An established destination remains the same allocation even when
        // public value fields are copied from a different mapping.
        allocation_identity = destination_identity;
      end
      else begin
        // Factory clone/copy into a fresh value preserves the opaque identity.
        allocation_identity = rhs_mapping.allocation_identity;
      end
    endfunction
  endclass

  class rdma_host_mem_allocation_record extends uvm_object;
    `uvm_object_utils(rdma_host_mem_allocation_record)

    rdma_host_mem_mapping authority;
    host_mem_pkg::host_mem_api backing_mem;
    bit active;

    function new(string name = "rdma_host_mem_allocation_record");
      super.new(name);
      authority = null;
      backing_mem = null;
      active = 1'b0;
    endfunction
  endclass

  class rdma_host_mem_adapter extends rdma_host_mem_api;
    `uvm_object_utils(rdma_host_mem_adapter)

    // Upstream owns initialization and lifetime of this manager.  The adapter
    // composes it and never changes its configured address regions.
    host_mem_pkg::host_mem_api mem;

    // Zero selects explicit identity mapping.  A non-zero value is the first
    // IOVA cursor; successful offset mappings align and advance that cursor.
    bit [63:0] iova_base;

    protected rdma_host_mem_allocation_record allocations[$];
    protected bit iova_config_locked;
    protected bit [63:0] locked_iova_base;
    protected bit iova_cursor_valid;
    protected bit [64:0] next_iova;

    function new(string name = "rdma_host_mem_adapter");
      super.new(name);
      mem = null;
      iova_base = '0;
      iova_config_locked = 1'b0;
      locked_iova_base = '0;
      iova_cursor_valid = 1'b0;
      next_iova = '0;
    endfunction

    protected function rdma_function_handle clone_function_handle(
      rdma_function_handle source
    );
      uvm_object cloned_object;
      rdma_function_handle result;

      if (source == null)
        return null;
      cloned_object = source.clone();
      if (cloned_object == null || !$cast(result, cloned_object))
        return null;
      return result;
    endfunction

    protected function rdma_handle clone_owner_handle(rdma_handle source);
      uvm_object cloned_object;
      rdma_handle result;

      if (source == null)
        return null;
      cloned_object = source.clone();
      if (cloned_object == null || !$cast(result, cloned_object))
        return null;
      return result;
    endfunction

    protected function bit same_handle(rdma_handle lhs, rdma_handle rhs);
      if (lhs == null || rhs == null)
        return lhs == null && rhs == null;
      return lhs.same_instance(rhs);
    endfunction

    protected function bit mapping_values_match(
      rdma_dma_mapping candidate,
      rdma_dma_mapping authority
    );
      if (candidate == null || authority == null)
        return 1'b0;
      return same_handle(candidate.function_h, authority.function_h) &&
             candidate.requester_bdf == authority.requester_bdf &&
             candidate.pasid_valid == authority.pasid_valid &&
             candidate.pasid == authority.pasid &&
             candidate.backing_addr == authority.backing_addr &&
             candidate.iova == authority.iova &&
             candidate.size == authority.size &&
             candidate.direction == authority.direction &&
             candidate.permissions == authority.permissions &&
             candidate.state == authority.state &&
             same_handle(candidate.owner_h, authority.owner_h);
    endfunction

    protected function int find_allocation(rdma_host_mem_mapping mapping);
      if (mapping == null)
        return -1;
      foreach (allocations[i]) begin
        if (allocations[i] != null && allocations[i].authority != null &&
            allocations[i].authority.same_allocation(mapping))
          return i;
      end
      return -1;
    endfunction

    protected function rdma_status validate_mapping(
      rdma_dma_mapping mapping,
      output int allocation_index
    );
      rdma_host_mem_mapping concrete_mapping;

      allocation_index = -1;
      if (mapping == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "DMA mapping is null");
      if (mapping.state != RDMA_MAPPING_ACTIVE)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "DMA mapping is not ACTIVE");
      if (!$cast(concrete_mapping, mapping))
        return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                 "DMA mapping has no host allocation identity");
      allocation_index = find_allocation(concrete_mapping);
      if (allocation_index < 0)
        return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                 "DMA mapping is not owned by this adapter");
      if (!allocations[allocation_index].active ||
          allocations[allocation_index].authority.state !=
            RDMA_MAPPING_ACTIVE)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "host allocation has been released");
      if (!mapping_values_match(
            mapping, allocations[allocation_index].authority
          ))
        return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                 "DMA mapping value fields were modified");
      return rdma_status::success();
    endfunction

    protected function rdma_status validate_range(
      rdma_host_mem_allocation_record allocation,
      longint unsigned offset,
      longint unsigned length,
      output bit [63:0] backing_address
    );
      bit [64:0] offset_end;
      bit [64:0] address_sum;
      bit [64:0] address_end;

      backing_address = '0;
      if (allocation == null || allocation.authority == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "allocation ledger entry is invalid");
      offset_end = {1'b0, offset} + {1'b0, length};
      if (offset_end[64] ||
          offset_end > {1'b0, allocation.authority.size})
        return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                 "access is outside the DMA mapping");
      if (length == 0)
        return rdma_status::success();
      address_sum =
        {1'b0, allocation.authority.backing_addr.value} + {1'b0, offset};
      if (address_sum[64])
        return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                 "backing address addition overflowed");
      address_end = address_sum + {1'b0, length};
      if (address_end > {1'b1, 64'b0})
        return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                 "backing access end overflowed");
      backing_address = address_sum[63:0];
      return rdma_status::success();
    endfunction

    protected function bit iova_overlaps_active(
      bit [63:0] first_iova,
      bit [64:0] end_iova
    );
      bit [64:0] existing_first;
      bit [64:0] existing_end;

      foreach (allocations[i]) begin
        if (allocations[i] == null || !allocations[i].active ||
            allocations[i].authority == null)
          continue;
        existing_first =
          {1'b0, allocations[i].authority.iova.value};
        existing_end = existing_first +
                       {1'b0, allocations[i].authority.size};
        if ({1'b0, first_iova} < existing_end &&
            existing_first < end_iova)
          return 1'b1;
      end
      return 1'b0;
    endfunction

    protected function rdma_status choose_iova(
      bit [63:0] backing_address,
      int unsigned size,
      int unsigned alignment,
      output bit [63:0] selected_iova,
      output bit [64:0] committed_cursor
    );
      bit [64:0] cursor;
      bit [64:0] alignment_mask;
      bit [64:0] aligned_cursor;
      bit [64:0] range_end;

      selected_iova = '0;
      committed_cursor = next_iova;
      if (iova_base == 0) begin
        range_end = {1'b0, backing_address} + {1'b0, size};
        if (range_end > {1'b1, 64'b0})
          return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                   "identity IOVA range overflows 64 bits");
        selected_iova = backing_address;
        committed_cursor = next_iova;
      end
      else begin
        cursor = iova_cursor_valid ? next_iova : {1'b0, iova_base};
        if (cursor[64])
          return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                   "IOVA cursor is exhausted");
        alignment_mask = {1'b0, alignment - 1'b1};
        aligned_cursor = cursor + alignment_mask;
        if (aligned_cursor[64])
          return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                   "IOVA alignment overflows 64 bits");
        aligned_cursor = aligned_cursor & ~alignment_mask;
        range_end = aligned_cursor + {1'b0, size};
        if (range_end > {1'b1, 64'b0})
          return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                   "IOVA allocation end overflows 64 bits");
        selected_iova = aligned_cursor[63:0];
        committed_cursor = range_end;
      end
      if (iova_overlaps_active(selected_iova, range_end))
        return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "IOVA range overlaps an active mapping");
      return rdma_status::success();
    endfunction

    virtual function rdma_status allocate(
      rdma_dma_request_context request_context,
      int unsigned size,
      int unsigned alignment,
      rdma_dma_direction_e direction,
      output rdma_dma_mapping mapping
    );
      bit [63:0] backing_address;
      bit [63:0] selected_iova;
      bit [64:0] committed_cursor;
      bit [64:0] backing_end;
      rdma_function_handle function_copy;
      rdma_host_mem_mapping allocated_mapping;
      rdma_host_mem_mapping authority;
      rdma_host_mem_allocation_record allocation;
      rdma_status status;

      mapping = null;
      if (request_context == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "DMA request context is null");
      status = request_context.validate();
      if (!status.ok())
        return status;
      if (mem == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "host_mem API is not configured");
      if (iova_config_locked && iova_base != locked_iova_base)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "IOVA configuration cannot change after a successful allocation"
        );
      if (size == 0 || alignment == 0 ||
          (alignment & (alignment - 1'b1)) != 0)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "size and alignment must be non-zero and alignment must be a power of two");
      if (!(direction inside {RDMA_DMA_DEVICE_READ,
                              RDMA_DMA_DEVICE_WRITE,
                              RDMA_DMA_BIDIRECTIONAL}))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "DMA direction is invalid");

      backing_address = mem.alloc(size, alignment, `__FILE__, `__LINE__);
      if (backing_address == 64'hffff_ffff_ffff_ffff)
        return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "host_mem allocation failed");
      backing_end = {1'b0, backing_address} + {1'b0, size};
      if ((backing_address & (alignment - 1'b1)) != 0 ||
          backing_end > {1'b1, 64'b0}) begin
        mem.free(backing_address, `__FILE__, `__LINE__);
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "host_mem returned a misaligned or overflowing allocation"
        );
      end

      status = choose_iova(backing_address, size, alignment,
                           selected_iova, committed_cursor);
      if (!status.ok()) begin
        mem.free(backing_address, `__FILE__, `__LINE__);
        return status;
      end

      function_copy = clone_function_handle(request_context.function_h);
      if (function_copy == null) begin
        mem.free(backing_address, `__FILE__, `__LINE__);
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "Function handle clone failed");
      end
      allocated_mapping = rdma_host_mem_mapping::type_id::create(
        $sformatf("host_mapping_%0d", allocations.size())
      );
      if (allocated_mapping == null) begin
        mem.free(backing_address, `__FILE__, `__LINE__);
        return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "DMA mapping creation failed");
      end
      status = allocated_mapping.initialize_allocation_identity();
      if (!status.ok()) begin
        mem.free(backing_address, `__FILE__, `__LINE__);
        return status;
      end
      allocated_mapping.function_h = function_copy;
      allocated_mapping.requester_bdf = request_context.requester_bdf;
      allocated_mapping.pasid_valid = request_context.pasid_valid;
      allocated_mapping.pasid = request_context.pasid;
      allocated_mapping.backing_addr.value = backing_address;
      allocated_mapping.iova.value = selected_iova;
      allocated_mapping.size = size;
      allocated_mapping.direction = direction;
      allocated_mapping.permissions.device_read =
        direction inside {RDMA_DMA_DEVICE_READ, RDMA_DMA_BIDIRECTIONAL};
      allocated_mapping.permissions.device_write =
        direction inside {RDMA_DMA_DEVICE_WRITE, RDMA_DMA_BIDIRECTIONAL};
      allocated_mapping.permissions.atomic = 1'b0;
      allocated_mapping.state = RDMA_MAPPING_ACTIVE;
      allocated_mapping.owner_h = clone_owner_handle(
        request_context.owner_h
      );
      if (request_context.owner_h != null &&
          allocated_mapping.owner_h == null) begin
        mem.free(backing_address, `__FILE__, `__LINE__);
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "DMA mapping owner clone failed");
      end

      status = allocated_mapping.make_authority_snapshot(authority);
      if (!status.ok()) begin
        mem.free(backing_address, `__FILE__, `__LINE__);
        return status;
      end
      if (authority == null ||
          !authority.same_allocation(allocated_mapping) ||
          !mapping_values_match(allocated_mapping, authority)) begin
        mem.free(backing_address, `__FILE__, `__LINE__);
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "DMA mapping authority snapshot is inconsistent"
        );
      end
      allocation = rdma_host_mem_allocation_record::type_id::create(
        $sformatf("host_allocation_%0d", allocations.size())
      );
      if (allocation == null) begin
        mem.free(backing_address, `__FILE__, `__LINE__);
        return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "allocation ledger entry creation failed");
      end
      allocation.authority = authority;
      allocation.backing_mem = mem;
      allocation.active = 1'b1;
      allocations.push_back(allocation);
      if (!iova_config_locked) begin
        locked_iova_base = iova_base;
        iova_config_locked = 1'b1;
      end
      if (iova_base != 0) begin
        next_iova = committed_cursor;
        iova_cursor_valid = 1'b1;
      end
      mapping = allocated_mapping;
      return rdma_status::success();
    endfunction

    virtual function rdma_status write(
      rdma_dma_mapping mapping,
      longint unsigned offset,
      byte data[]
    );
      int allocation_index;
      bit [63:0] backing_address;
      rdma_status status;

      status = validate_mapping(mapping, allocation_index);
      if (!status.ok())
        return status;
      status = validate_range(allocations[allocation_index], offset,
                              data.size(), backing_address);
      if (!status.ok())
        return status;
      if (data.size() == 0)
        return rdma_status::success();
      allocations[allocation_index].backing_mem.write_mem(
        backing_address, data, `__FILE__, `__LINE__
      );
      return rdma_status::success();
    endfunction

    virtual function rdma_status read(
      rdma_dma_mapping mapping,
      longint unsigned offset,
      int unsigned size,
      output byte data[]
    );
      int allocation_index;
      bit [63:0] backing_address;
      rdma_status status;

      data = new[0];
      status = validate_mapping(mapping, allocation_index);
      if (!status.ok())
        return status;
      status = validate_range(allocations[allocation_index], offset, size,
                              backing_address);
      if (!status.ok())
        return status;
      if (size == 0)
        return rdma_status::success();
      allocations[allocation_index].backing_mem.read_mem(
        backing_address, size, data, `__FILE__, `__LINE__
      );
      if (data.size() != size) begin
        data = new[0];
        return rdma_status::make(RDMA_SC_UNKNOWN_HW_ERROR,
                                 "host_mem read returned the wrong size");
      end
      return rdma_status::success();
    endfunction

    virtual function rdma_status \release (rdma_dma_mapping mapping);
      int allocation_index;
      rdma_status status;

      status = validate_mapping(mapping, allocation_index);
      if (!status.ok())
        return status;
      // The authoritative address and original manager select the allocation;
      // no caller-writable field participates in the actual free operation.
      allocations[allocation_index].backing_mem.free(
        allocations[allocation_index].authority.backing_addr.value,
        `__FILE__, `__LINE__
      );
      allocations[allocation_index].active = 1'b0;
      allocations[allocation_index].authority.state = RDMA_MAPPING_RELEASED;
      mapping.state = RDMA_MAPPING_RELEASED;
      return rdma_status::success();
    endfunction

    // host_mem leak_check is manager-global.  leak_count is adapter-owner
    // local; callers should isolate or first release unrelated manager users
    // when they require a pristine global host_mem report.
    function rdma_status check_leaks(output int unsigned leak_count);
      host_mem_pkg::host_mem_api checked_mem[$];
      bit already_checked;

      leak_count = 0;
      foreach (allocations[i]) begin
        if (allocations[i] != null && allocations[i].active)
          leak_count++;
      end
      if (mem == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "host_mem API is not configured");

      mem.leak_check(`__FILE__, `__LINE__);
      checked_mem.push_back(mem);
      foreach (allocations[i]) begin
        if (allocations[i] == null || allocations[i].backing_mem == null)
          continue;
        already_checked = 1'b0;
        foreach (checked_mem[j]) begin
          if (checked_mem[j] == allocations[i].backing_mem) begin
            already_checked = 1'b1;
            break;
          end
        end
        if (!already_checked) begin
          allocations[i].backing_mem.leak_check(`__FILE__, `__LINE__);
          checked_mem.push_back(allocations[i].backing_mem);
        end
      end
      if (leak_count != 0)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          $sformatf("adapter has %0d active DMA mappings", leak_count)
        );
      return rdma_status::success();
    endfunction
  endclass
endpackage
