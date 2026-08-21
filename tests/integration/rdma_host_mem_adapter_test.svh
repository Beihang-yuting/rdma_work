class rdma_host_mem_adapter_test extends uvm_test;
  `uvm_component_utils(rdma_host_mem_adapter_test)

  function new(string name = "rdma_host_mem_adapter_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function automatic rdma_function_handle make_function_handle(string name);
    rdma_function_handle function_h;

    function_h = rdma_function_handle::type_id::create(name);
    function_h.kind = RDMA_RESOURCE_FUNCTION;
    function_h.function_uid = 64'h0123_4567_89ab_cdef;
    function_h.object_id = 32'h1020_3040;
    function_h.generation = 32'd17;
    return function_h;
  endfunction

  function automatic rdma_dma_mapping clone_mapping(
    string check_name,
    rdma_dma_mapping source
  );
    uvm_object cloned_object;
    rdma_dma_mapping result;

    if (source == null) begin
      `uvm_fatal(check_name, "cannot clone a null DMA mapping")
      return null;
    end
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(result, cloned_object)) begin
      `uvm_fatal(check_name, "DMA mapping clone type mismatch")
      return null;
    end
    return result;
  endfunction

  function automatic void expect_status(
    string check_name,
    rdma_status status,
    rdma_status_code_e expected_code
  );
    if (status == null) begin
      `uvm_error(check_name, "adapter returned a null status")
      return;
    end
    if (status.code != expected_code)
      `uvm_error(check_name,
                 $sformatf("expected %s, got %s (%s)",
                           expected_code.name(), status.code.name(),
                           status.message))
  endfunction

  function automatic void expect_empty(
    string check_name,
    byte data[]
  );
    if (data.size() != 0)
      `uvm_error(check_name,
                 $sformatf("failed read returned %0d bytes", data.size()))
  endfunction

  task run_phase(uvm_phase phase);
    host_mem_manager hm;
    host_mem_manager offset_hm;
    host_mem_manager overflow_hm;
    host_mem_manager equal_hm_a;
    host_mem_manager equal_hm_b;
    rdma_host_mem_adapter adapter;
    rdma_host_mem_adapter offset_adapter;
    rdma_host_mem_adapter overflow_adapter;
    rdma_host_mem_adapter equal_adapter_a;
    rdma_host_mem_adapter equal_adapter_b;
    rdma_function_handle function_h;
    rdma_function_handle invalid_function_h;
    rdma_dma_mapping mapping;
    rdma_dma_mapping mapping_b;
    rdma_dma_mapping offset_mapping_a;
    rdma_dma_mapping offset_mapping_b;
    rdma_dma_mapping overflow_mapping;
    rdma_dma_mapping equal_mapping_a;
    rdma_dma_mapping equal_mapping_b;
    rdma_dma_mapping valid_clone;
    rdma_dma_mapping stale_clone;
    rdma_dma_mapping release_view;
    rdma_dma_mapping tampered;
    rdma_dma_mapping copy_attack;
    rdma_dma_mapping forged_mapping;
    rdma_status status;
    bit [63:0] external_addr;
    int unsigned leak_count;
    byte wr[] = '{8'h11, 8'h22, 8'h33, 8'h44};
    byte wr_b[] = '{8'hb1, 8'hb2, 8'hb3, 8'hb4};
    byte one_byte[] = '{8'ha5};
    byte empty_write[] = '{};
    byte rd[];
    byte external_wr[] = '{8'he1, 8'he2, 8'he3, 8'he4};
    byte external_rd[];

    phase.raise_objection(this);

    function_h = make_function_handle("function_h");
    invalid_function_h = make_function_handle("invalid_function_h");
    invalid_function_h.kind = RDMA_RESOURCE_PD;

    hm = host_mem_manager::type_id::create("hm");
    hm.init_region(64'h0000_0001_0000_0000,
                   64'h0000_0001_00ff_ffff);
    adapter = rdma_host_mem_adapter::type_id::create("adapter");
    adapter.mem = hm;

    mapping = rdma_dma_mapping::type_id::create("non_null_seed");
    status = adapter.allocate(null, 64, 64, RDMA_DMA_BIDIRECTIONAL,
                              mapping);
    expect_status("ALLOC_NULL_FUNCTION", status, RDMA_SC_INVALID_ARGUMENT);
    if (mapping != null)
      `uvm_error("ALLOC_NULL_FUNCTION", "failure did not null the output")
    status = adapter.allocate(invalid_function_h, 64, 64,
                              RDMA_DMA_BIDIRECTIONAL, mapping);
    expect_status("ALLOC_FUNCTION_KIND", status, RDMA_SC_INVALID_ARGUMENT);
    status = adapter.allocate(function_h, 0, 64, RDMA_DMA_BIDIRECTIONAL,
                              mapping);
    expect_status("ALLOC_ZERO_SIZE", status, RDMA_SC_INVALID_ARGUMENT);
    status = adapter.allocate(function_h, 64, 0, RDMA_DMA_BIDIRECTIONAL,
                              mapping);
    expect_status("ALLOC_ZERO_ALIGNMENT", status,
                  RDMA_SC_INVALID_ARGUMENT);
    status = adapter.allocate(function_h, 64, 3, RDMA_DMA_BIDIRECTIONAL,
                              mapping);
    expect_status("ALLOC_NON_POWER_OF_TWO", status,
                  RDMA_SC_INVALID_ARGUMENT);
    status = adapter.allocate(function_h, 64, 64,
                              rdma_dma_direction_e'(3), mapping);
    expect_status("ALLOC_DIRECTION", status, RDMA_SC_INVALID_ARGUMENT);
    if (mapping != null)
      `uvm_error("ALLOC_FAILURE_OUTPUT", "invalid allocation returned mapping")

    // The first real host allocation proves rejected requests did not reach
    // or advance the underlying allocator.
    external_addr = hm.alloc(64, 64, `__FILE__, `__LINE__);
    if (external_addr != 64'h0000_0001_0000_0000)
      `uvm_error("ALLOC_NO_SIDE_EFFECT",
                 $sformatf("unexpected first host address 0x%016h",
                           external_addr))
    hm.write_mem(external_addr, external_wr, `__FILE__, `__LINE__);

    status = adapter.allocate(function_h, 4096, 4096,
                              RDMA_DMA_BIDIRECTIONAL, mapping);
    expect_status("ALLOC_64BIT", status, RDMA_SC_OK);
    if (mapping == null)
      `uvm_fatal("ALLOC_64BIT", "successful allocation returned null")
    if (mapping.backing_addr.value < 64'h0000_0001_0000_0000 ||
        mapping.backing_addr.value[11:0] != 0)
      `uvm_error("ALLOC_64BIT", "backing is not aligned above 4 GiB")
    if (mapping.iova.value != mapping.backing_addr.value)
      `uvm_error("IDENTITY_IOVA", "default mapping is not explicit identity")
    if (mapping.size != 4096 ||
        mapping.direction != RDMA_DMA_BIDIRECTIONAL ||
        mapping.permissions.device_read != 1'b1 ||
        mapping.permissions.device_write != 1'b1 ||
        mapping.permissions.atomic != 1'b0 ||
        mapping.state != RDMA_MAPPING_ACTIVE)
      `uvm_error("MAPPING_FIELDS", "mapping metadata is inconsistent")
    if (mapping.function_h == null ||
        mapping.function_h == function_h ||
        !mapping.function_h.same_instance(function_h))
      `uvm_error("FUNCTION_CLONE", "Function incarnation was not cloned")

    valid_clone = clone_mapping("VALID_CLONE", mapping);
    stale_clone = clone_mapping("STALE_CLONE", mapping);
    release_view = clone_mapping("RELEASE_CLONE", mapping);

    status = adapter.write(valid_clone, 0, wr);
    expect_status("ROUNDTRIP_WRITE", status, RDMA_SC_OK);
    status = adapter.read(valid_clone, 0, wr.size(), rd);
    expect_status("ROUNDTRIP_READ", status, RDMA_SC_OK);
    if (rd.size() != wr.size())
      `uvm_error("ROUNDTRIP_READ", "roundtrip size mismatch")
    else begin
      foreach (wr[i]) begin
        if (rd[i] != wr[i])
          `uvm_error("ROUNDTRIP_READ",
                     $sformatf("byte %0d mismatch", i))
      end
    end

    status = adapter.write(valid_clone, 4095, one_byte);
    expect_status("LAST_BYTE_WRITE", status, RDMA_SC_OK);
    status = adapter.read(valid_clone, 4095, 1, rd);
    expect_status("LAST_BYTE_READ", status, RDMA_SC_OK);
    if (rd.size() != 1 || rd[0] != one_byte[0])
      `uvm_error("LAST_BYTE_READ", "last byte did not roundtrip")

    status = adapter.write(valid_clone, 4094, wr);
    expect_status("CROSS_BOUNDARY_WRITE", status, RDMA_SC_DMA_TRANSLATION);
    rd = new[1];
    rd[0] = 8'hff;
    status = adapter.read(valid_clone, 4095, 2, rd);
    expect_status("CROSS_BOUNDARY_READ", status, RDMA_SC_DMA_TRANSLATION);
    expect_empty("CROSS_BOUNDARY_READ", rd);

    status = adapter.write(valid_clone, 4096, empty_write);
    expect_status("ZERO_LENGTH_WRITE", status, RDMA_SC_OK);
    rd = new[1];
    rd[0] = 8'hff;
    status = adapter.read(valid_clone, 4096, 0, rd);
    expect_status("ZERO_LENGTH_READ", status, RDMA_SC_OK);
    expect_empty("ZERO_LENGTH_READ", rd);
    status = adapter.write(valid_clone, 4097, empty_write);
    expect_status("ZERO_LENGTH_OUTSIDE", status,
                  RDMA_SC_DMA_TRANSLATION);

    status = adapter.write(valid_clone, 64'hffff_ffff_ffff_ffff,
                           one_byte);
    expect_status("OFFSET_65BIT_OVERFLOW", status,
                  RDMA_SC_DMA_TRANSLATION);
    rd = new[1];
    rd[0] = 8'hff;
    status = adapter.read(valid_clone, 64'hffff_ffff_ffff_ffff, 2, rd);
    expect_status("READ_65BIT_OVERFLOW", status,
                  RDMA_SC_DMA_TRANSLATION);
    expect_empty("READ_65BIT_OVERFLOW", rd);

    status = adapter.allocate(function_h, 64, 64, RDMA_DMA_DEVICE_READ,
                              mapping_b);
    expect_status("ALLOC_SECOND", status, RDMA_SC_OK);
    if (mapping_b == null || !mapping_b.permissions.device_read ||
        mapping_b.permissions.device_write || mapping_b.permissions.atomic)
      `uvm_error("READ_PERMISSIONS", "device-read permissions are wrong")
    status = adapter.write(mapping_b, 0, wr_b);
    expect_status("SECOND_SEED", status, RDMA_SC_OK);

    tampered = clone_mapping("TAMPER_FUNCTION", mapping);
    tampered.function_h.generation++;
    status = adapter.write(tampered, 0, one_byte);
    expect_status("TAMPER_FUNCTION", status, RDMA_SC_DMA_TRANSLATION);
    tampered = clone_mapping("TAMPER_BACKING", mapping);
    tampered.backing_addr.value++;
    status = adapter.read(tampered, 0, 1, rd);
    expect_status("TAMPER_BACKING", status, RDMA_SC_DMA_TRANSLATION);
    expect_empty("TAMPER_BACKING", rd);
    tampered = clone_mapping("TAMPER_IOVA", mapping);
    tampered.iova.value++;
    status = adapter.write(tampered, 0, one_byte);
    expect_status("TAMPER_IOVA", status, RDMA_SC_DMA_TRANSLATION);
    tampered = clone_mapping("TAMPER_SIZE", mapping);
    tampered.size++;
    status = adapter.read(tampered, 0, 1, rd);
    expect_status("TAMPER_SIZE", status, RDMA_SC_DMA_TRANSLATION);
    expect_empty("TAMPER_SIZE", rd);
    tampered = clone_mapping("TAMPER_DIRECTION", mapping);
    tampered.direction = RDMA_DMA_DEVICE_READ;
    status = adapter.write(tampered, 0, one_byte);
    expect_status("TAMPER_DIRECTION", status, RDMA_SC_DMA_TRANSLATION);
    tampered = clone_mapping("TAMPER_PERMISSION", mapping);
    tampered.permissions.atomic = 1'b1;
    status = adapter.write(tampered, 0, one_byte);
    expect_status("TAMPER_PERMISSION", status, RDMA_SC_DMA_TRANSLATION);

    forged_mapping = rdma_dma_mapping::type_id::create("forged_mapping");
    forged_mapping.copy(mapping);
    status = adapter.read(forged_mapping, 0, 1, rd);
    expect_status("FORGED_MAPPING", status, RDMA_SC_DMA_TRANSLATION);
    expect_empty("FORGED_MAPPING", rd);

    copy_attack = clone_mapping("COPY_ATTACK", mapping);
    copy_attack.copy(mapping_b);
    status = adapter.write(copy_attack, 0, one_byte);
    expect_status("COPY_IDENTITY_ATTACK", status,
                  RDMA_SC_DMA_TRANSLATION);
    status = adapter.read(mapping_b, 0, wr_b.size(), rd);
    expect_status("COPY_TARGET_UNCHANGED", status, RDMA_SC_OK);
    if (rd.size() != wr_b.size() || rd[0] != wr_b[0] || rd[3] != wr_b[3])
      `uvm_error("COPY_TARGET_UNCHANGED",
                 "copy attack redirected to another allocation")

    function_h.generation = 32'd99;
    if (mapping.function_h == null || mapping.function_h.generation != 17)
      `uvm_error("FUNCTION_VALUE_COPY", "caller mutation aliased mapping")
    function_h.generation = 32'd17;

    status = adapter.\release (mapping_b);
    expect_status("RELEASE_SECOND", status, RDMA_SC_OK);
    if (mapping_b.state != RDMA_MAPPING_RELEASED)
      `uvm_error("RELEASE_SECOND", "release did not mark caller mapping")
    status = adapter.\release (release_view);
    expect_status("RELEASE_PRIMARY", status, RDMA_SC_OK);
    if (release_view.state != RDMA_MAPPING_RELEASED)
      `uvm_error("RELEASE_PRIMARY", "release did not mark caller mapping")
    rd = new[1];
    rd[0] = 8'hff;
    status = adapter.read(stale_clone, 0, 1, rd);
    expect_status("USE_AFTER_RELEASE_READ", status,
                  RDMA_SC_INVALID_STATE);
    expect_empty("USE_AFTER_RELEASE_READ", rd);
    status = adapter.write(mapping, 0, one_byte);
    expect_status("USE_AFTER_RELEASE_WRITE", status,
                  RDMA_SC_INVALID_STATE);
    status = adapter.\release (release_view);
    expect_status("DOUBLE_RELEASE", status, RDMA_SC_INVALID_STATE);

    // A caller-owned allocation in the same global manager is not part of
    // this adapter's ledger and must remain allocated after adapter release.
    hm.read_mem(external_addr, external_wr.size(), external_rd,
                `__FILE__, `__LINE__);
    if (external_rd.size() != external_wr.size() ||
        external_rd[0] != external_wr[0] ||
        external_rd[3] != external_wr[3])
      `uvm_error("EXTERNAL_ALLOCATION", "adapter released caller memory")
    hm.free(external_addr, `__FILE__, `__LINE__);
    status = adapter.check_leaks(leak_count);
    expect_status("IDENTITY_LEAKS", status, RDMA_SC_OK);
    if (leak_count != 0)
      `uvm_error("IDENTITY_LEAKS", "adapter ledger is not empty")

    // A non-zero iova_base is the first end-exclusive IOVA cursor.  Each
    // successful mapping aligns that cursor and advances it by mapping size.
    offset_hm = host_mem_manager::type_id::create("offset_hm");
    offset_hm.init_region(64'h0000_0002_0000_0000,
                          64'h0000_0002_00ff_ffff);
    offset_adapter = rdma_host_mem_adapter::type_id::create("offset_adapter");
    offset_adapter.mem = offset_hm;
    offset_adapter.iova_base = 64'h0000_0000_4000_0000;
    status = offset_adapter.allocate(function_h, 64, 64,
                                     RDMA_DMA_DEVICE_WRITE,
                                     offset_mapping_a);
    expect_status("OFFSET_ALLOC_A", status, RDMA_SC_OK);
    status = offset_adapter.allocate(function_h, 128, 256,
                                     RDMA_DMA_BIDIRECTIONAL,
                                     offset_mapping_b);
    expect_status("OFFSET_ALLOC_B", status, RDMA_SC_OK);
    if (offset_mapping_a == null || offset_mapping_b == null)
      `uvm_fatal("OFFSET_ALLOC", "offset allocation returned null")
    if (offset_mapping_a.iova.value != 64'h0000_0000_4000_0000 ||
        offset_mapping_a.iova.value == offset_mapping_a.backing_addr.value)
      `uvm_error("OFFSET_BASE", "first offset IOVA is incorrect")
    if (offset_mapping_b.iova.value != 64'h0000_0000_4000_0100 ||
        offset_mapping_b.iova.value <
          offset_mapping_a.iova.value + offset_mapping_a.size)
      `uvm_error("OFFSET_NON_OVERLAP", "offset IOVA ranges overlap")
    if (offset_mapping_a.permissions.device_read ||
        !offset_mapping_a.permissions.device_write ||
        offset_mapping_a.permissions.atomic)
      `uvm_error("WRITE_PERMISSIONS", "device-write permissions are wrong")
    status = offset_adapter.\release (offset_mapping_a);
    expect_status("OFFSET_RELEASE_A", status, RDMA_SC_OK);
    status = offset_adapter.\release (offset_mapping_b);
    expect_status("OFFSET_RELEASE_B", status, RDMA_SC_OK);
    status = offset_adapter.check_leaks(leak_count);
    expect_status("OFFSET_LEAKS", status, RDMA_SC_OK);
    if (leak_count != 0)
      `uvm_error("OFFSET_LEAKS", "offset adapter ledger is not empty")

    // IOVA arithmetic failure rolls back the real backing allocation and
    // does not advance the cursor.  The same base is reusable immediately.
    overflow_hm = host_mem_manager::type_id::create("overflow_hm");
    overflow_hm.init_region(64'h0000_0003_0000_0000,
                            64'h0000_0003_00ff_ffff);
    overflow_adapter = rdma_host_mem_adapter::type_id::create(
      "overflow_adapter"
    );
    overflow_adapter.mem = overflow_hm;
    overflow_adapter.iova_base = 64'hffff_ffff_ffff_fff0;
    status = overflow_adapter.allocate(function_h, 32, 16,
                                       RDMA_DMA_BIDIRECTIONAL,
                                       overflow_mapping);
    expect_status("IOVA_END_OVERFLOW", status,
                  RDMA_SC_RESOURCE_EXHAUSTED);
    if (overflow_mapping != null)
      `uvm_error("IOVA_END_OVERFLOW", "failed allocation returned mapping")
    status = overflow_adapter.allocate(function_h, 16, 16,
                                       RDMA_DMA_BIDIRECTIONAL,
                                       overflow_mapping);
    expect_status("IOVA_CURSOR_ROLLBACK", status, RDMA_SC_OK);
    if (overflow_mapping == null ||
        overflow_mapping.backing_addr.value !=
          64'h0000_0003_0000_0000 ||
        overflow_mapping.iova.value != 64'hffff_ffff_ffff_fff0)
      `uvm_error("IOVA_CURSOR_ROLLBACK",
                 "failed allocation advanced backing or IOVA state")
    status = overflow_adapter.\release (overflow_mapping);
    expect_status("OVERFLOW_RELEASE", status, RDMA_SC_OK);
    status = overflow_adapter.check_leaks(leak_count);
    expect_status("OVERFLOW_LEAKS", status, RDMA_SC_OK);

    // Equal numeric addresses from independent managers/adapters remain
    // distinct because allocation identity and adapter ownership are opaque.
    equal_hm_a = host_mem_manager::type_id::create("equal_hm_a");
    equal_hm_b = host_mem_manager::type_id::create("equal_hm_b");
    equal_hm_a.init_region(64'h0000_0005_0000_0000,
                           64'h0000_0005_000f_ffff);
    equal_hm_b.init_region(64'h0000_0005_0000_0000,
                           64'h0000_0005_000f_ffff);
    equal_adapter_a = rdma_host_mem_adapter::type_id::create(
      "equal_adapter_a"
    );
    equal_adapter_b = rdma_host_mem_adapter::type_id::create(
      "equal_adapter_b"
    );
    equal_adapter_a.mem = equal_hm_a;
    equal_adapter_b.mem = equal_hm_b;
    status = equal_adapter_a.allocate(function_h, 64, 64,
                                      RDMA_DMA_BIDIRECTIONAL,
                                      equal_mapping_a);
    expect_status("EQUAL_ALLOC_A", status, RDMA_SC_OK);
    status = equal_adapter_b.allocate(function_h, 64, 64,
                                      RDMA_DMA_BIDIRECTIONAL,
                                      equal_mapping_b);
    expect_status("EQUAL_ALLOC_B", status, RDMA_SC_OK);
    if (equal_mapping_a.backing_addr != equal_mapping_b.backing_addr ||
        equal_mapping_a.iova != equal_mapping_b.iova)
      `uvm_error("EQUAL_NUMERIC_VALUES", "test setup did not alias values")
    status = equal_adapter_a.write(equal_mapping_b, 0, one_byte);
    expect_status("WRONG_ADAPTER", status, RDMA_SC_DMA_TRANSLATION);
    status = equal_adapter_a.\release (equal_mapping_b);
    expect_status("WRONG_ADAPTER_RELEASE", status,
                  RDMA_SC_DMA_TRANSLATION);
    status = equal_adapter_a.\release (equal_mapping_a);
    expect_status("EQUAL_RELEASE_A", status, RDMA_SC_OK);
    status = equal_adapter_b.\release (equal_mapping_b);
    expect_status("EQUAL_RELEASE_B", status, RDMA_SC_OK);
    status = equal_adapter_a.check_leaks(leak_count);
    expect_status("EQUAL_LEAKS_A", status, RDMA_SC_OK);
    status = equal_adapter_b.check_leaks(leak_count);
    expect_status("EQUAL_LEAKS_B", status, RDMA_SC_OK);

    phase.drop_objection(this);
  endtask
endclass
