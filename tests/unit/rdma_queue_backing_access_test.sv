// 目录：测试层 unit/rdma_queue_backing_access_test.sv。
// 职责：验证 rdma_queue_backing_access_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_queue_backing_access_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_queue_backing_access_test extends uvm_test;
  `uvm_component_utils(rdma_queue_backing_access_test)

  // 功能：构造 rdma_queue_backing_access_test，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_backing_access_test 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_backing_access_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：在 rdma_queue_backing_access_test 中，fn 从测试 fixture 返回预先构造的 Function/队列句柄或 DMA 上下文，保持调用方与 fixture 使用同一实例。
  // 输入/输出及副作用：无显式参数；fn 读取局部计算结果，并使用字段 f、f.function_uid、f.object_id、f.generation；函数返回 rdma_function_handle，不取得调用方资源所有权。
  // 失败/边界：fn 的结果直接由 return f 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_function_handle fn();
    rdma_function_handle f;
    f = rdma_function_handle::type_id::create("f");
    f.function_uid = 64'h1234;
    f.object_id = 1;
    f.generation = 2;
    return f;
  endfunction

  // 功能：在 rdma_queue_backing_access_test 中，ctx 从测试 fixture 返回预先构造的 Function/队列句柄或 DMA 上下文，保持调用方与 fixture 使用同一实例。
  // 输入/输出及副作用：无显式参数；ctx 读取局部计算结果，并使用字段 c、c.function_h、c.requester_bdf、c.pasid_valid、c.pasid、c.dma_domain_valid、c.dma_domain_id；函数返回 rdma_dma_request_context，不取得调用方资源所有权。
  // 失败/边界：ctx 的结果直接由 return c 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
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

  // 功能：call_count 只读当前账本/队列状态并计算 int unsigned 计数或可用容量，不推进任何事务游标。
  // 输入/输出及副作用：mem（输入）、method_name（输入）；call_count 读取 mem、method_name 并使用字段 count；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：call_count 先检查 mem.calls[i] != null && mem.calls[i].method_name == method_name，再返回 count；拒绝分支不提交部分状态，也不隐式重试。
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

  // 功能：在 rdma_queue_backing_access_test 中，expect_code 在测试中执行 expect_code 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、status（输入）、expected（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_code 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function automatic void expect_code(
    string label,
    rdma_status status,
    rdma_status_code_e expected
  );
    if (status == null || status.code != expected)
      `uvm_error(label, $sformatf("expected status %0d, got %s",
        expected, status == null ? "null" : status.convert2string()))
  endfunction

  // 功能：assert_device_write_contract 验证面向设备写入的方向权限与跨 span 原子预检契约。
  // 输入/输出及副作用：access、mem、m0、m1（输入）；task 调整两个 mapping 的权限，调用 write_device/write 并通过 UVM 报告状态、backend_write_started 及后端 write 调用次数；不转移 fixture 所有权。
  // 失败/边界：任一 span 的 device_write 权限缺失时必须在首个 backend write 前失败并保持调用次数不变；成功路径必须跨两个 span 写入并将 backend_write_started 置位，普通 write 在 device_read 缺失时必须返回 RDMA_SC_DMA_PERMISSION。
  task automatic assert_device_write_contract(
    rdma_queue_backing_access access,
    rdma_mock_host_mem mem,
    rdma_dma_mapping m0,
    rdma_dma_mapping m1
  );
    byte payload[] = new[16];
    rdma_status status;
    bit backend_write_started;
    int unsigned write_calls;

    foreach (payload[i]) payload[i] = byte'(i);
    m0.permissions.device_read = 1'b0;
    m1.permissions.device_read = 1'b0;
    write_calls = call_count(mem, "write");
    backend_write_started = 1'b1;
    status = access.write_device(4096 - 8, payload, backend_write_started);
    if (status == null || !status.ok())
      `uvm_error("DEVICE_WRITE", "DEVICE_WRITE mapping was rejected")
    if (!backend_write_started)
      `uvm_error("DEVICE_WRITE_STARTED", "successful write did not report backend entry")
    if (call_count(mem, "write") != write_calls + 2)
      `uvm_error("DEVICE_WRITE_SPANS", "device write did not visit both spans")
    status = access.write(4096 - 8, payload);
    expect_code("WRITE_DIRECTION", status, RDMA_SC_DMA_PERMISSION);
    m1.permissions.device_write = 1'b0;
    write_calls = call_count(mem, "write");
    backend_write_started = 1'b1;
    status = access.write_device(4096 - 8, payload, backend_write_started);
    expect_code("DEVICE_PREFLIGHT_PERMISSION", status, RDMA_SC_DMA_PERMISSION);
    if (backend_write_started)
      `uvm_error("DEVICE_PREFLIGHT_STARTED", "preflight failure entered backend")
    if (call_count(mem, "write") != write_calls)
      `uvm_error("DEVICE_PREFLIGHT", "failed span was written")
  endtask

  // 功能：在 rdma_queue_backing_access_test 中，run_phase 驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：run_phase 的 setup/阶段驱动失败时停止新增事务，并按测试生命周期清理 objection 与临时引用。
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

    assert_device_write_contract(access, mem, m0, m1);

    phase.drop_objection(this);
  endtask
endclass
