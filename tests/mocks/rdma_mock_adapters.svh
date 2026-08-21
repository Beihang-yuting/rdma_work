function automatic rdma_status rdma_mock_clone_status(rdma_status source);
  rdma_status result;

  if (source == null)
    return null;
  result = rdma_status::type_id::create("mock_status_copy");
  result.category = source.category;
  result.code = source.code;
  result.hardware_code = source.hardware_code;
  result.hardware_code_valid = source.hardware_code_valid;
  result.source_engine = source.source_engine;
  result.function_uid = source.function_uid;
  result.generation = source.generation;
  result.resource_id = source.resource_id;
  result.command_id = source.command_id;
  result.wr_id = source.wr_id;
  result.severity = source.severity;
  result.retryable = source.retryable;
  result.message = source.message;
  return result;
endfunction

function automatic rdma_function_handle rdma_mock_clone_function_handle(
  rdma_function_handle source
);
  uvm_object cloned_object;
  rdma_function_handle result;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(result, cloned_object))
    `uvm_fatal("MOCK_COPY", "function handle clone type mismatch")
  return result;
endfunction

function automatic rdma_dma_mapping rdma_mock_clone_mapping(
  rdma_dma_mapping source
);
  uvm_object cloned_object;
  rdma_dma_mapping result;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(result, cloned_object))
    `uvm_fatal("MOCK_COPY", "DMA mapping clone type mismatch")
  return result;
endfunction

function automatic rdma_function_binding rdma_mock_clone_binding(
  rdma_function_binding source
);
  uvm_object cloned_object;
  rdma_function_binding result;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(result, cloned_object))
    `uvm_fatal("MOCK_COPY", "function binding clone type mismatch")
  return result;
endfunction

function automatic rdma_packet rdma_mock_clone_packet(rdma_packet source);
  uvm_object cloned_object;
  rdma_packet result;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(result, cloned_object))
    `uvm_fatal("MOCK_COPY", "packet clone type mismatch")
  return result;
endfunction

function automatic rdma_net_response_policy rdma_mock_clone_policy(
  rdma_net_response_policy source
);
  uvm_object cloned_object;
  rdma_net_response_policy result;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(result, cloned_object))
    `uvm_fatal("MOCK_COPY", "response policy clone type mismatch")
  return result;
endfunction

function automatic rdma_net_fault rdma_mock_clone_fault(rdma_net_fault source);
  uvm_object cloned_object;
  rdma_net_fault result;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(result, cloned_object))
    `uvm_fatal("MOCK_COPY", "network fault clone type mismatch")
  return result;
endfunction

function automatic rdma_pcie_function_info rdma_mock_clone_function_info(
  rdma_pcie_function_info source
);
  uvm_object cloned_object;
  rdma_pcie_function_info result;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(result, cloned_object))
    `uvm_fatal("MOCK_COPY", "PCIe function info clone type mismatch")
  return result;
endfunction

function automatic rdma_bar_decode rdma_mock_clone_bar_decode(
  rdma_bar_decode source
);
  uvm_object cloned_object;
  rdma_bar_decode result;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(result, cloned_object))
    `uvm_fatal("MOCK_COPY", "BAR decode clone type mismatch")
  return result;
endfunction

class rdma_mock_host_mem_call extends uvm_object;
  `uvm_object_utils(rdma_mock_host_mem_call)

  longint unsigned call_sequence;
  string method_name;
  rdma_function_handle function_h;
  rdma_dma_mapping mapping;
  int unsigned size;
  int unsigned alignment;
  rdma_dma_direction_e direction;
  longint unsigned offset;
  byte data[];

  function new(string name = "rdma_mock_host_mem_call");
    super.new(name);
    call_sequence = 0;
    method_name = "";
    function_h = null;
    mapping = null;
    size = 0;
    alignment = 0;
    direction = RDMA_DMA_DEVICE_READ;
    offset = 0;
  endfunction
endclass

class rdma_mock_dma_mapping extends rdma_dma_mapping;
  `uvm_object_utils(rdma_mock_dma_mapping)

  local longint unsigned allocation_token;
  local bit allocation_token_initialized;

  function new(string name = "rdma_mock_dma_mapping");
    super.new(name);
    allocation_token = 0;
    allocation_token_initialized = 1'b0;
  endfunction

  function rdma_status initialize_allocation_token(longint unsigned token);
    if (allocation_token_initialized)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "allocation token is already initialized");
    if (token == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "allocation token must be nonzero");
    allocation_token = token;
    allocation_token_initialized = 1'b1;
    return rdma_status::success();
  endfunction

  function bit has_allocation_token();
    return allocation_token_initialized;
  endfunction

  function longint unsigned get_allocation_token();
    return allocation_token;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    rdma_mock_dma_mapping rhs_mapping;

    super.do_copy(rhs);
    if (!$cast(rhs_mapping, rhs))
      `uvm_fatal("MOCK_COPY", "mock DMA mapping copy type mismatch")
    allocation_token = rhs_mapping.allocation_token;
    allocation_token_initialized = rhs_mapping.allocation_token_initialized;
  endfunction
endclass

class rdma_mock_memory_region extends uvm_object;
  `uvm_object_utils(rdma_mock_memory_region)

  rdma_dma_mapping mapping;
  byte data[];

  function new(string name = "rdma_mock_memory_region");
    super.new(name);
    mapping = null;
  endfunction
endclass

class rdma_mock_host_mem extends rdma_host_mem_api;
  `uvm_object_utils(rdma_mock_host_mem)

  rdma_mock_host_mem_call calls[$];
  rdma_mock_memory_region regions[$];
  rdma_status failures[string];
  longint unsigned next_sequence;
  longint unsigned next_address;
  local longint unsigned next_allocation_token;

  function new(string name = "rdma_mock_host_mem");
    super.new(name);
    next_sequence = 0;
    next_address = 64'h0000_0001_0000_0000;
    next_allocation_token = 1;
  endfunction

  function rdma_status fail_next(string method_name, rdma_status status);
    if (!(method_name inside {"allocate", "write", "read", "release"}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "unknown host memory method");
    if (status == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "failure status is null");
    failures[method_name] = rdma_mock_clone_status(status);
    return rdma_status::success();
  endfunction

  function automatic rdma_status take_failure(string method_name);
    rdma_status result;

    if (!failures.exists(method_name))
      return null;
    result = rdma_mock_clone_status(failures[method_name]);
    failures.delete(method_name);
    return result;
  endfunction

  function automatic rdma_mock_host_mem_call record_call(
    string method_name,
    rdma_function_handle function_h = null,
    rdma_dma_mapping mapping = null,
    int unsigned size = 0,
    int unsigned alignment = 0,
    rdma_dma_direction_e direction = RDMA_DMA_DEVICE_READ,
    longint unsigned offset = 0,
    byte data[] = '{}
  );
    rdma_mock_host_mem_call call_record;

    call_record = rdma_mock_host_mem_call::type_id::create(
      $sformatf("host_call_%0d", next_sequence + 1'b1)
    );
    next_sequence++;
    call_record.call_sequence = next_sequence;
    call_record.method_name = method_name;
    call_record.function_h = rdma_mock_clone_function_handle(function_h);
    call_record.mapping = rdma_mock_clone_mapping(mapping);
    call_record.size = size;
    call_record.alignment = alignment;
    call_record.direction = direction;
    call_record.offset = offset;
    call_record.data = data;
    calls.push_back(call_record);
    return call_record;
  endfunction

  function automatic int find_region(rdma_dma_mapping mapping);
    rdma_mock_dma_mapping requested_mapping;
    rdma_mock_dma_mapping region_mapping;

    if (mapping == null)
      return -1;
    if (!$cast(requested_mapping, mapping))
      return -1;
    if (!requested_mapping.has_allocation_token())
      return -1;
    foreach (regions[i]) begin
      if (!$cast(region_mapping, regions[i].mapping))
        continue;
      if (region_mapping.has_allocation_token() &&
          region_mapping.get_allocation_token() ==
            requested_mapping.get_allocation_token() &&
          region_mapping.function_h != null && mapping.function_h != null &&
          region_mapping.function_h.same_instance(mapping.function_h))
        return i;
    end
    return -1;
  endfunction

  virtual function rdma_status allocate(
    rdma_function_handle function_h,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    rdma_status failure;
    rdma_status token_status;
    rdma_mock_memory_region region;
    rdma_mock_dma_mapping allocated_mapping;
    longint unsigned aligned_address;
    longint unsigned alignment_mask;

    record_call("allocate", function_h, null, size, alignment, direction);
    mapping = null;
    failure = take_failure("allocate");
    if (failure != null)
      return failure;
    if (function_h == null || function_h.kind != RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "function handle is invalid");
    if (size == 0 || alignment == 0 ||
        (alignment & (alignment - 1'b1)) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "size or alignment is invalid");
    if (!(direction inside {RDMA_DMA_DEVICE_READ, RDMA_DMA_DEVICE_WRITE,
                            RDMA_DMA_BIDIRECTIONAL}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "DMA direction is invalid");

    alignment_mask = alignment - 1'b1;
    if (next_address > (64'hffff_ffff_ffff_ffff - alignment_mask))
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "aligned DMA address overflows");
    aligned_address = (next_address + alignment_mask) & ~alignment_mask;
    if (size > (64'hffff_ffff_ffff_ffff - aligned_address))
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "DMA allocation end overflows");
    if (next_allocation_token == 0)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "DMA allocation tokens are exhausted");
    allocated_mapping = rdma_mock_dma_mapping::type_id::create(
      $sformatf("mapping_%0d", regions.size())
    );
    token_status = allocated_mapping.initialize_allocation_token(
      next_allocation_token
    );
    if (!token_status.ok())
      return token_status;
    allocated_mapping.function_h = rdma_mock_clone_function_handle(function_h);
    allocated_mapping.backing_addr.value = aligned_address;
    allocated_mapping.iova.value = aligned_address;
    allocated_mapping.size = size;
    allocated_mapping.direction = direction;
    allocated_mapping.permissions.device_read =
      direction inside {RDMA_DMA_DEVICE_READ, RDMA_DMA_BIDIRECTIONAL};
    allocated_mapping.permissions.device_write =
      direction inside {RDMA_DMA_DEVICE_WRITE, RDMA_DMA_BIDIRECTIONAL};
    allocated_mapping.permissions.atomic = 1'b0;
    allocated_mapping.state = RDMA_MAPPING_ACTIVE;
    mapping = allocated_mapping;

    region = rdma_mock_memory_region::type_id::create(
      $sformatf("region_%0d", regions.size())
    );
    region.mapping = rdma_mock_clone_mapping(mapping);
    region.data = new[size];
    regions.push_back(region);
    next_address = aligned_address + size;
    next_allocation_token++;
    return rdma_status::success();
  endfunction

  virtual function rdma_status write(
    rdma_dma_mapping mapping,
    longint unsigned offset,
    byte data[]
  );
    rdma_status failure;
    int region_index;
    longint unsigned allocated_size;

    record_call("write", null, mapping, data.size(), 0,
                RDMA_DMA_DEVICE_READ, offset, data);
    failure = take_failure("write");
    if (failure != null)
      return failure;
    if (mapping == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "DMA mapping is null");
    if (mapping.state != RDMA_MAPPING_ACTIVE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "DMA mapping is not active");
    region_index = find_region(mapping);
    if (region_index < 0)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "DMA mapping is unknown");
    if (regions[region_index].mapping.state != RDMA_MAPPING_ACTIVE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "DMA allocation is not active");
    allocated_size = regions[region_index].mapping.size;
    if (offset > allocated_size)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "write is outside the DMA mapping");
    if (data.size() > (allocated_size - offset))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "write is outside the DMA mapping");
    foreach (data[i])
      regions[region_index].data[offset + i] = data[i];
    return rdma_status::success();
  endfunction

  virtual function rdma_status read(
    rdma_dma_mapping mapping,
    longint unsigned offset,
    int unsigned size,
    output byte data[]
  );
    rdma_status failure;
    int region_index;
    longint unsigned allocated_size;

    record_call("read", null, mapping, size, 0, RDMA_DMA_DEVICE_READ,
                offset);
    data = new[0];
    failure = take_failure("read");
    if (failure != null)
      return failure;
    if (mapping == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "DMA mapping is null");
    if (mapping.state != RDMA_MAPPING_ACTIVE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "DMA mapping is not active");
    region_index = find_region(mapping);
    if (region_index < 0)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "DMA mapping is unknown");
    if (regions[region_index].mapping.state != RDMA_MAPPING_ACTIVE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "DMA allocation is not active");
    allocated_size = regions[region_index].mapping.size;
    if (offset > allocated_size)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "read is outside the DMA mapping");
    if (size > (allocated_size - offset))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "read is outside the DMA mapping");
    data = new[size];
    foreach (data[i])
      data[i] = regions[region_index].data[offset + i];
    return rdma_status::success();
  endfunction

  virtual function rdma_status \release (rdma_dma_mapping mapping);
    rdma_status failure;
    int region_index;

    record_call("release", null, mapping);
    failure = take_failure("release");
    if (failure != null)
      return failure;
    if (mapping == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "DMA mapping is null");
    if (mapping.state != RDMA_MAPPING_ACTIVE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "DMA mapping is not active");
    region_index = find_region(mapping);
    if (region_index < 0)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "DMA mapping is unknown");
    if (regions[region_index].mapping.state != RDMA_MAPPING_ACTIVE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "DMA allocation is not active");
    mapping.state = RDMA_MAPPING_RELEASED;
    regions[region_index].mapping.state = RDMA_MAPPING_RELEASED;
    return rdma_status::success();
  endfunction
endclass

class rdma_mock_pcie_call extends uvm_object;
  `uvm_object_utils(rdma_mock_pcie_call)

  longint unsigned call_sequence;
  string method_name;
  rdma_bdf_t target;
  rdma_cfg_offset_t offset;
  bit [31:0] cfg_data;
  bit [3:0] byte_enable;
  rdma_function_handle function_h;
  rdma_bar_addr_t address;
  byte data[];

  function new(string name = "rdma_mock_pcie_call");
    super.new(name);
    call_sequence = 0;
    method_name = "";
    target = '0;
    offset = '0;
    cfg_data = '0;
    byte_enable = '0;
    function_h = null;
    address = '0;
  endfunction
endclass

class rdma_mock_pcie extends rdma_pcie_api;
  `uvm_object_utils(rdma_mock_pcie)

  rdma_mock_pcie_call calls[$];
  rdma_status failures[string];
  longint unsigned next_sequence;
  bit [31:0] cfg_read_value;
  rdma_pcie_function_info function_info_response;
  rdma_bar_decode decode_response;

  function new(string name = "rdma_mock_pcie");
    super.new(name);
    next_sequence = 0;
    cfg_read_value = '0;
    function_info_response = null;
    decode_response = null;
  endfunction

  function rdma_status fail_next(string method_name, rdma_status status);
    if (!(method_name inside {
          "cfg_read32", "cfg_write32", "mmio_write",
          "dma_visibility_barrier", "mmio_ordering_barrier",
          "get_function_info", "decode_bar"
        }))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "unknown PCIe method");
    if (status == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "failure status is null");
    failures[method_name] = rdma_mock_clone_status(status);
    return rdma_status::success();
  endfunction

  function automatic rdma_status take_failure(string method_name);
    rdma_status result;

    if (!failures.exists(method_name))
      return null;
    result = rdma_mock_clone_status(failures[method_name]);
    failures.delete(method_name);
    return result;
  endfunction

  function automatic rdma_mock_pcie_call record_call(
    string method_name,
    rdma_bdf_t target = '0,
    rdma_cfg_offset_t offset = '0,
    bit [31:0] cfg_data = '0,
    bit [3:0] byte_enable = '0,
    rdma_function_handle function_h = null,
    rdma_bar_addr_t address = '0,
    byte data[] = '{}
  );
    rdma_mock_pcie_call call_record;

    call_record = rdma_mock_pcie_call::type_id::create(
      $sformatf("pcie_call_%0d", next_sequence + 1'b1)
    );
    next_sequence++;
    call_record.call_sequence = next_sequence;
    call_record.method_name = method_name;
    call_record.target = target;
    call_record.offset = offset;
    call_record.cfg_data = cfg_data;
    call_record.byte_enable = byte_enable;
    call_record.function_h = rdma_mock_clone_function_handle(function_h);
    call_record.address = address;
    call_record.data = data;
    calls.push_back(call_record);
    return call_record;
  endfunction

  virtual task cfg_read32(
    rdma_bdf_t target,
    rdma_cfg_offset_t offset,
    output bit [31:0] data,
    output rdma_status status
  );
    record_call("cfg_read32", target, offset);
    data = '0;
    status = take_failure("cfg_read32");
    if (status != null)
      return;
    data = cfg_read_value;
    status = rdma_status::success();
  endtask

  virtual task cfg_write32(
    rdma_bdf_t target,
    rdma_cfg_offset_t offset,
    bit [31:0] data,
    bit [3:0] byte_enable,
    output rdma_status status
  );
    record_call("cfg_write32", target, offset, data, byte_enable);
    status = take_failure("cfg_write32");
    if (status == null)
      status = rdma_status::success();
  endtask

  virtual task mmio_write(
    rdma_function_handle function_h,
    rdma_bar_addr_t address,
    byte data[],
    output rdma_status status
  );
    record_call("mmio_write", '0, '0, '0, '0, function_h, address, data);
    status = take_failure("mmio_write");
    if (status == null)
      status = rdma_status::success();
  endtask

  virtual task dma_visibility_barrier(
    rdma_function_handle function_h,
    output rdma_status status
  );
    record_call("dma_visibility_barrier", '0, '0, '0, '0, function_h);
    status = take_failure("dma_visibility_barrier");
    if (status == null)
      status = rdma_status::success();
  endtask

  virtual task mmio_ordering_barrier(
    rdma_function_handle function_h,
    output rdma_status status
  );
    record_call("mmio_ordering_barrier", '0, '0, '0, '0, function_h);
    status = take_failure("mmio_ordering_barrier");
    if (status == null)
      status = rdma_status::success();
  endtask

  virtual function rdma_status get_function_info(
    rdma_bdf_t bdf,
    output rdma_pcie_function_info info
  );
    rdma_status failure;

    record_call("get_function_info", bdf);
    info = null;
    failure = take_failure("get_function_info");
    if (failure != null)
      return failure;
    if (function_info_response == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "function info response is not configured");
    info = rdma_mock_clone_function_info(function_info_response);
    return rdma_status::success();
  endfunction

  virtual function rdma_status decode_bar(
    rdma_bar_addr_t address,
    output rdma_bar_decode result
  );
    rdma_status failure;

    record_call("decode_bar", '0, '0, '0, '0, null, address);
    result = null;
    failure = take_failure("decode_bar");
    if (failure != null)
      return failure;
    if (decode_response == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "BAR decode response is not configured");
    result = rdma_mock_clone_bar_decode(decode_response);
    return rdma_status::success();
  endfunction
endclass

class rdma_mock_function_table_call extends uvm_object;
  `uvm_object_utils(rdma_mock_function_table_call)

  longint unsigned call_sequence;
  string method_name;
  rdma_function_binding binding;

  function new(string name = "rdma_mock_function_table_call");
    super.new(name);
    call_sequence = 0;
    method_name = "";
    binding = null;
  endfunction
endclass

class rdma_mock_function_table extends rdma_function_table_api;
  `uvm_object_utils(rdma_mock_function_table)

  rdma_mock_function_table_call calls[$];
  rdma_status failures[string];
  longint unsigned next_sequence;

  function new(string name = "rdma_mock_function_table");
    super.new(name);
    next_sequence = 0;
  endfunction

  function rdma_status fail_next(string method_name, rdma_status status);
    if (!(method_name inside {
          "program_notify", "clear_notify", "program_dmi", "clear_dmi",
          "program_vft", "clear_vft"
        }))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "unknown function table method");
    if (status == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "failure status is null");
    failures[method_name] = rdma_mock_clone_status(status);
    return rdma_status::success();
  endfunction

  function automatic rdma_status take_failure(string method_name);
    rdma_status result;

    if (!failures.exists(method_name))
      return null;
    result = rdma_mock_clone_status(failures[method_name]);
    failures.delete(method_name);
    return result;
  endfunction

  function void record_call(string method_name,
                            rdma_function_binding binding);
    rdma_mock_function_table_call call_record;

    call_record = rdma_mock_function_table_call::type_id::create(
      $sformatf("table_call_%0d", next_sequence + 1'b1)
    );
    next_sequence++;
    call_record.call_sequence = next_sequence;
    call_record.method_name = method_name;
    call_record.binding = rdma_mock_clone_binding(binding);
    calls.push_back(call_record);
  endfunction

  task automatic complete_call(string method_name,
                               rdma_function_binding binding,
                               output rdma_status status);
    record_call(method_name, binding);
    status = take_failure(method_name);
    if (status == null)
      status = rdma_status::success();
  endtask

  virtual task program_notify(rdma_function_binding binding,
                              output rdma_status status);
    complete_call("program_notify", binding, status);
  endtask

  virtual task clear_notify(rdma_function_binding binding,
                            output rdma_status status);
    complete_call("clear_notify", binding, status);
  endtask

  virtual task program_dmi(rdma_function_binding binding,
                           output rdma_status status);
    complete_call("program_dmi", binding, status);
  endtask

  virtual task clear_dmi(rdma_function_binding binding,
                         output rdma_status status);
    complete_call("clear_dmi", binding, status);
  endtask

  virtual task program_vft(rdma_function_binding binding,
                           output rdma_status status);
    complete_call("program_vft", binding, status);
  endtask

  virtual task clear_vft(rdma_function_binding binding,
                         output rdma_status status);
    complete_call("clear_vft", binding, status);
  endtask
endclass

class rdma_mock_net_call extends uvm_object;
  `uvm_object_utils(rdma_mock_net_call)

  longint unsigned call_sequence;
  string method_name;
  rdma_packet packet;
  bit observer_present;
  string observer_type_name;
  string observer_instance_name;
  rdma_net_response_policy policy;
  rdma_net_fault fault;

  function new(string name = "rdma_mock_net_call");
    super.new(name);
    call_sequence = 0;
    method_name = "";
    packet = null;
    observer_present = 1'b0;
    observer_type_name = "";
    observer_instance_name = "";
    policy = null;
    fault = null;
  endfunction
endclass

class rdma_mock_net extends rdma_net_api;
  `uvm_object_utils(rdma_mock_net)

  rdma_mock_net_call calls[$];
  rdma_status failures[string];
  rdma_net_observer observers[$];
  rdma_packet receive_queue[$];
  longint unsigned next_sequence;

  function new(string name = "rdma_mock_net");
    super.new(name);
    next_sequence = 0;
  endfunction

  function rdma_status fail_next(string method_name, rdma_status status);
    if (!(method_name inside {
          "send_packet", "receive_packet", "configure_response_policy",
          "inject_fault"
        }))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "unknown network method");
    if (status == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "failure status is null");
    failures[method_name] = rdma_mock_clone_status(status);
    return rdma_status::success();
  endfunction

  function automatic rdma_status take_failure(string method_name);
    rdma_status result;

    if (!failures.exists(method_name))
      return null;
    result = rdma_mock_clone_status(failures[method_name]);
    failures.delete(method_name);
    return result;
  endfunction

  function automatic rdma_mock_net_call record_call(
    string method_name,
    rdma_packet packet = null,
    rdma_net_observer observer = null,
    rdma_net_response_policy policy = null,
    rdma_net_fault fault = null
  );
    rdma_mock_net_call call_record;

    call_record = rdma_mock_net_call::type_id::create(
      $sformatf("net_call_%0d", next_sequence + 1'b1)
    );
    next_sequence++;
    call_record.call_sequence = next_sequence;
    call_record.method_name = method_name;
    call_record.packet = rdma_mock_clone_packet(packet);
    call_record.observer_present = observer != null;
    if (observer != null) begin
      call_record.observer_type_name = observer.get_type_name();
      call_record.observer_instance_name = observer.get_name();
    end
    call_record.policy = rdma_mock_clone_policy(policy);
    call_record.fault = rdma_mock_clone_fault(fault);
    calls.push_back(call_record);
    return call_record;
  endfunction

  function void enqueue_receive(rdma_packet packet);
    receive_queue.push_back(rdma_mock_clone_packet(packet));
  endfunction

  virtual task send_packet(rdma_packet packet, output rdma_status status);
    rdma_packet observer_packet;

    record_call("send_packet", packet);
    status = take_failure("send_packet");
    if (status != null)
      return;
    if (packet == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "packet is null");
      return;
    end
    foreach (observers[i]) begin
      if (observers[i] != null) begin
        observer_packet = rdma_mock_clone_packet(packet);
        observers[i].write(observer_packet);
      end
    end
    status = rdma_status::success();
  endtask

  virtual task receive_packet(output rdma_packet packet,
                              output rdma_status status);
    rdma_mock_net_call call_record;

    call_record = record_call("receive_packet");
    packet = null;
    status = take_failure("receive_packet");
    if (status != null)
      return;
    if (receive_queue.size() == 0) begin
      status = rdma_status::make(RDMA_SC_QUEUE_EMPTY,
                                 "receive queue is empty");
      return;
    end
    packet = receive_queue.pop_front();
    call_record.packet = rdma_mock_clone_packet(packet);
    status = rdma_status::success();
  endtask

  virtual function void register_observer(rdma_net_observer observer);
    record_call("register_observer", null, observer);
    if (observer != null)
      observers.push_back(observer);
  endfunction

  virtual function rdma_status configure_response_policy(
    rdma_net_response_policy policy
  );
    rdma_status failure;

    record_call("configure_response_policy", null, null, policy);
    failure = take_failure("configure_response_policy");
    if (failure != null)
      return failure;
    if (policy == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "response policy is null");
    return rdma_status::success();
  endfunction

  virtual function rdma_status inject_fault(rdma_net_fault fault);
    rdma_status failure;

    record_call("inject_fault", null, null, null, fault);
    failure = take_failure("inject_fault");
    if (failure != null)
      return failure;
    if (fault == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "network fault is null");
    return rdma_status::success();
  endfunction
endclass
