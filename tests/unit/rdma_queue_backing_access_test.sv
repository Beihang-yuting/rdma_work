class rdma_queue_backing_access_test extends uvm_test;
  `uvm_component_utils(rdma_queue_backing_access_test)
  function new(string name = "rdma_queue_backing_access_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function automatic rdma_function_handle fn();
    rdma_function_handle f;
    f = rdma_function_handle::type_id::create("f");
    f.function_uid = 64'h1234;
    f.object_id = 1;
    f.generation = 2;
    return f;
  endfunction

  function automatic rdma_dma_request_context ctx();
    rdma_dma_request_context c;
    c = rdma_dma_request_context::type_id::create("ctx");
    c.function_h = fn();
    c.requester_bdf = 16'h0102;
    c.pasid_valid = 1'b1;
    c.pasid = 20'h12345;
    c.dma_domain_valid = 1'b1;
    c.dma_domain_id = 7;
    return c;
  endfunction

  function automatic int unsigned call_count(
    rdma_mock_host_mem mem,
    string method_name
  );
    int unsigned count;
    count = 0;
    foreach (mem.calls[i])
      if (mem.calls[i] != null && mem.calls[i].method_name == method_name)
        count++;
    return count;
  endfunction

  function automatic void expect_code(
    string label,
    rdma_status status,
    rdma_status_code_e expected
  );
    if (status == null || status.code != expected)
      `uvm_error(label, $sformatf("expected status %0d, got %s",
        expected, status == null ? "null" : status.convert2string()))
  endfunction

  task run_phase(uvm_phase phase);
    rdma_mock_host_mem mem;
    rdma_dma_mapping m0;
    rdma_dma_mapping m1;
    rdma_status status;
    rdma_queue_backing_ref backing;
    rdma_queue_backing_ref invalid_backing;
    rdma_queue_backing_segment segment;
    rdma_queue_backing_segment invalid_segment;
    rdma_qp_backing_ref qp_backing;
    rdma_queue_backing_access access;
    rdma_queue_backing_access invalid_access;
    rdma_queue_backing_span spans[$];
    byte data[];
    byte write_data[];
    int unsigned write_calls;
    int unsigned read_calls;

    phase.raise_objection(this);

    mem = rdma_mock_host_mem::type_id::create("mem");
    status = mem.allocate(ctx(), 4096, 4096, RDMA_DMA_BIDIRECTIONAL, m0);
    expect_code("ALLOC0", status, RDMA_SC_OK);
    status = mem.allocate(ctx(), 4096, 4096, RDMA_DMA_BIDIRECTIONAL, m1);
    expect_code("ALLOC1", status, RDMA_SC_OK);

    backing = rdma_queue_backing_ref::type_id::create("ref");
    backing.role = RDMA_QUEUE_ROLE_CQ_RING;
    backing.mapping = m0;
    backing.length = 4096;
    backing.mapping_offset = 0;
    backing.logical_queue_offset = 0;
    backing.ownership = RDMA_OWNERSHIP_BORROWED;
    segment = rdma_queue_backing_segment::type_id::create("seg");
    segment.role = backing.role;
    segment.mapping = m1;
    segment.length = 4096;
    segment.mapping_offset = 0;
    segment.logical_queue_offset = 4096;
    segment.ownership = backing.ownership;
    backing.additional_segments.push_back(segment);

    access = rdma_queue_backing_access::type_id::create("access");
    status = access.configure(fn(), mem);
    expect_code("CONFIG", status, RDMA_SC_OK);
    status = access.attach_queue(backing);
    expect_code("ATTACH", status, RDMA_SC_OK);

    status = access.attach_queue(backing);
    expect_code("DOUBLE_ATTACH", status, RDMA_SC_INVALID_STATE);
    qp_backing = rdma_qp_backing_ref::type_id::create("qp_backing");
    qp_backing.role = RDMA_QUEUE_ROLE_QP_SQ_RING;
    qp_backing.mapping = m0;
    qp_backing.length = 4096;
    qp_backing.mapping_offset = 0;
    qp_backing.ownership = RDMA_OWNERSHIP_BORROWED;
    status = access.attach_qp(qp_backing);
    expect_code("MIXED_ATTACH", status, RDMA_SC_INVALID_STATE);

    status = access.resolve(4096 - 8, 16, spans);
    if (status == null || !status.ok() || spans.size() != 2 ||
        spans[0].logical_offset != 4096 - 8 || spans[0].length != 8 ||
        spans[1].logical_offset != 4096 || spans[1].length != 8)
      `uvm_error("CROSS", "cross-segment resolve failed")
    status = access.resolve(1, 8, spans);
    expect_code("OFFSET_ALIGN", status, RDMA_SC_INVALID_ARGUMENT);
    status = access.resolve(0, 7, spans);
    expect_code("LENGTH_ALIGN", status, RDMA_SC_INVALID_ARGUMENT);
    status = access.resolve(8192 - 8, 16, spans);
    expect_code("COVERAGE", status, RDMA_SC_DMA_TRANSLATION);

    write_data = new[16];
    foreach (write_data[i])
      write_data[i] = byte'(i);
    status = access.write(4096 - 8, write_data);
    expect_code("WRITE", status, RDMA_SC_OK);
    data = new[0];
    status = access.read(4096 - 8, 16, data);
    expect_code("READ", status, RDMA_SC_OK);
    if (data.size() != write_data.size())
      `uvm_error("READ_SIZE", "multi-span read returned wrong size")
    else
      foreach (data[i])
        if (data[i] !== write_data[i])
          `uvm_error("READ_DATA", $sformatf("byte %0d mismatched", i))

    write_calls = call_count(mem, "write");
    m1.permissions.device_read = 1'b0;
    status = access.write(4096 - 8, write_data);
    expect_code("WRITE_PERMISSION", status, RDMA_SC_DMA_PERMISSION);
    if (call_count(mem, "write") != write_calls)
      `uvm_error("WRITE_ATOMIC", "permission failure partially wrote backing")
    m1.permissions.device_read = 1'b1;

    read_calls = call_count(mem, "read");
    m1.permissions.device_write = 1'b0;
    data = new[3];
    foreach (data[i])
      data[i] = 8'h5a;
    status = access.read(4096 - 8, 16, data);
    expect_code("READ_PERMISSION", status, RDMA_SC_DMA_PERMISSION);
    if (data.size() != 0)
      `uvm_error("READ_ATOMIC", "failed read published partial data")
    if (call_count(mem, "read") != read_calls)
      `uvm_error("READ_PREFLIGHT", "permission failure issued host reads")
    m1.permissions.device_write = 1'b1;

    invalid_backing = rdma_queue_backing_ref::type_id::create("invalid_ref");
    invalid_backing.role = RDMA_QUEUE_ROLE_CQ_RING;
    invalid_backing.mapping = m0;
    invalid_backing.length = 4096;
    invalid_backing.mapping_offset = 0;
    invalid_backing.logical_queue_offset = 0;
    invalid_backing.ownership = RDMA_OWNERSHIP_BORROWED;
    invalid_segment = rdma_queue_backing_segment::type_id::create("invalid_seg");
    invalid_segment.role = RDMA_QUEUE_ROLE_CEQ_RING;
    invalid_segment.mapping = m1;
    invalid_segment.length = 4096;
    invalid_segment.mapping_offset = 0;
    invalid_segment.logical_queue_offset = 4096;
    invalid_segment.ownership = RDMA_OWNERSHIP_BORROWED;
    invalid_backing.additional_segments.push_back(invalid_segment);
    invalid_access = rdma_queue_backing_access::type_id::create("invalid_access");
    status = invalid_access.configure(fn(), mem);
    expect_code("INVALID_CONFIG", status, RDMA_SC_OK);
    status = invalid_access.attach_queue(invalid_backing);
    expect_code("ROLE_MISMATCH", status, RDMA_SC_INVALID_ARGUMENT);

    invalid_backing.additional_segments.delete();
    m0.function_h.generation = 3;
    status = invalid_access.attach_queue(invalid_backing);
    expect_code("STALE_GENERATION", status, RDMA_SC_STALE_GENERATION);
    m0.function_h.generation = 2;

    if (call_count(mem, "release") != 0)
      `uvm_error("BORROWED_RELEASE", "access helper released borrowed backing")

    phase.drop_objection(this);
  endtask
endclass
