// 目录：测试层 unit/rdma_queue_backing_access_test.sv。
// 职责：验证 queue backing/QP backing 的绑定、分段解析及 Host-memory 访问原子性。
// 依赖：依赖 rdma_queue_backing_access、UVM、rdma_mock_host_mem 和 DMA mapping fixture。
// 所有权与生命周期：本测试创建 mock、mapping 与 backing；access 只借用它们，run_phase 结束后由 UVM 回收本地对象。

// 设计说明：把 null-status、权限和跨段失败放在同一 fixture 中，直接检查失败不会发布半绑定引用或触发部分后端 I/O。

// 功能：构造故障注入用 queue backing reference，模拟扩展校验器返回空状态句柄。
// 输入/输出及副作用：name（输入）；new 只初始化基类字段，不取得 mapping 或 Host-memory 所有权。
// 失败/边界：该对象的 validate() 故意返回 null；attach_queue 必须将其转换为确定的 INVALID_STATE。
class rdma_null_queue_backing_validate extends rdma_queue_backing_ref;
  // 功能：创建 queue backing 故障注入对象，并复用基类的默认 role/ownership/geometry。
  // 输入/输出及副作用：name（输入）；new 不修改外部 mapping，也不触发后端访问。
  // 失败/边界：对象仅用于验证 null-status 防御，不能作为真实 queue backing 提交给设备。
  function new(string name = "rdma_null_queue_backing_validate");
    super.new(name);
  endfunction

  // 功能：模拟 queue backing 的可覆写校验器返回空状态，覆盖 attach_queue 的扩展边界。
  // 输入/输出及副作用：无显式输入；函数不修改 backing 字段，返回 null rdma_status 句柄。
  // 失败/边界：返回 null 是故障注入结果；调用方不得继续调用 status.ok() 或写入 queue_ref。
  virtual function rdma_status validate();
    return null;
  endfunction
endclass

// 功能：构造故障注入用 QP backing reference，模拟扩展校验器返回空状态句柄。
// 输入/输出及副作用：name（输入）；new 只初始化基类字段，不取得 mapping 或 Host-memory 所有权。
// 失败/边界：该对象的 validate() 故意返回 null；attach_qp 必须将其转换为确定的 INVALID_STATE。
class rdma_null_qp_backing_validate extends rdma_qp_backing_ref;
  // 功能：创建 QP backing 故障注入对象，并复用基类默认 role/ownership/geometry。
  // 输入/输出及副作用：name（输入）；new 不修改外部 mapping，也不触发后端访问。
  // 失败/边界：对象仅用于验证 null-status 防御，不能作为真实 QP backing 提交给设备。
  function new(string name = "rdma_null_qp_backing_validate");
    super.new(name);
  endfunction

  // 功能：模拟 QP backing 的可覆写校验器返回空状态，覆盖 attach_qp 的扩展边界。
  // 输入/输出及副作用：无显式输入；函数不修改 backing 字段，返回 null rdma_status 句柄。
  // 失败/边界：返回 null 是故障注入结果；调用方不得继续调用 status.ok() 或写入 qp_ref。
  virtual function rdma_status validate();
    return null;
  endfunction
endclass

class rdma_queue_backing_access_test extends uvm_test;
  `uvm_component_utils(rdma_queue_backing_access_test)

  // 功能：构造 rdma_queue_backing_access_test 的 UVM 节点，供 run_phase 创建独立的 mock 与 backing 场景。
  // 输入/输出及副作用：name、parent（输入）；仅传给 super.new 建立组件层级，不分配 mapping、Host-memory 或 access 对象。
  // 失败/边界：parent 可为 null；构造完成不表示任何测试 fixture 已就绪，所有资源均在 run_phase 的本地作用域创建并由其持有。
  function new(string name = "rdma_queue_backing_access_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：每次调用新建并返回固定 UID/object/generation 的 Function handle，作为本测试 DMA mapping 的 authority。
  // 输入/输出及副作用：无输入；分配新的 `f`，写入 function_uid=0x1234、object_id=1、generation=2，并把该对象句柄交给调用者。
  // 失败/边界：不缓存或复用先前 handle；本辅助函数假定 UVM factory 成功创建 f，若返回 null，随后的 f.function_uid 字段写入会立即发生空句柄失败，无法构造或返回可用对象。
  function automatic rdma_function_handle fn();
    rdma_function_handle f;
    f = rdma_function_handle::type_id::create("f");
    f.function_uid = 64'h1234;
    f.object_id = 1;
    f.generation = 2;
    return f;
  endfunction

  // 功能：每次调用新建 DMA request context，并填入本测试固定的 requester、PASID、DMA domain 与新建 Function handle。
  // 输入/输出及副作用：无输入；分配 `c`，调用 fn() 取得 c.function_h，写入 BDF 0x0102、有效 PASID 0x12345 和 domain 7，返回该新对象。
  // 失败/边界：返回值不是共享 fixture；本辅助函数假定 c 与 fn() 的 factory 创建成功，若任一为 null，后续字段写入会立即发生空句柄失败，ctx 无法构造或返回可用 context。
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

  // 功能：统计 mock Host-memory 已记录且方法名等于 method_name 的调用数，供原子性断言比较 I/O 前后状态。
  // 输入/输出及副作用：mem、method_name（输入）；只遍历 mem.calls 并返回局部 count，不修改 call log、mapping 或传入对象的所有权。
  // 失败/边界：null call entry 被跳过；本函数不防御 mem 为 null，调用者必须提供已创建的 mock，否则解引用失败而不会产生可用计数。
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

  // 功能：比较 status 的 code 与 expected，并以 label 产生可定位的 UVM error，统一本测试的状态断言格式。
  // 输入/输出及副作用：label、status、expected（输入）；只读取 status/code；不修改 DUT 或 fixture，失配时调用 `uvm_error` 记录一条错误。
  // 失败/边界：status 为 null 或 code 不匹配都会报错；函数不抛异常、不 drop objection，也不停止 run_phase，后续独立检查仍会执行。
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

  // 功能：构造两个相邻 DMA segment，依次覆盖 null 校验、重复/混合绑定、跨段读写、权限预检和 borrowed backing 不释放的契约。
  // 输入/输出及副作用：phase（输入）；raise/drop objection 包围所有检查；task 创建并修改本地 mock、mapping、backing 与 access，UVM error 是可观察失败输出。
  // 失败/边界：每个 expect_code/UVM 检查失配后仍继续执行剩余场景以收集错误；本 task 没有 configure/build/activate gate，唯一生命周期保证是结尾无条件 drop objection。
  task run_phase(uvm_phase phase);
    rdma_mock_host_mem mem;
    rdma_dma_mapping m0;
    rdma_dma_mapping m1;
    rdma_status status;
    rdma_queue_backing_ref backing;
    rdma_queue_backing_ref invalid_backing;
    rdma_null_queue_backing_validate null_queue_backing;
    rdma_queue_backing_segment segment;
    rdma_queue_backing_segment invalid_segment;
    rdma_qp_backing_ref qp_backing;
    rdma_null_qp_backing_validate null_qp_backing;
    rdma_queue_backing_access access;
    rdma_queue_backing_access invalid_access;
    rdma_queue_backing_access null_queue_access;
    rdma_queue_backing_access null_qp_access;
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

    // validate() 是可覆写边界；null status 必须在 attach 入口归一化，且
    // 失败后 backing slot 仍应可接受一次合法绑定。
    null_queue_access = rdma_queue_backing_access::type_id::create(
      "null_queue_access"
    );
    status = null_queue_access.configure(fn(), mem);
    expect_code("NULL_QUEUE_CONFIG", status, RDMA_SC_OK);
    null_queue_backing = new("null_queue_backing");
    write_calls = call_count(mem, "write");
    read_calls = call_count(mem, "read");
    status = null_queue_access.attach_queue(null_queue_backing);
    expect_code("NULL_QUEUE_VALIDATE", status, RDMA_SC_INVALID_STATE);
    if (call_count(mem, "write") != write_calls ||
        call_count(mem, "read") != read_calls)
      `uvm_error("NULL_QUEUE_BACKEND", "null queue validation touched Host memory")
    status = null_queue_access.attach_queue(backing);
    expect_code("NULL_QUEUE_RETRY", status, RDMA_SC_OK);

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

    // QP backing 也允许扩展校验器；null status 不能把 qp_ref 置为半有效引用。
    null_qp_access = rdma_queue_backing_access::type_id::create(
      "null_qp_access"
    );
    status = null_qp_access.configure(fn(), mem);
    expect_code("NULL_QP_CONFIG", status, RDMA_SC_OK);
    null_qp_backing = new("null_qp_backing");
    write_calls = call_count(mem, "write");
    read_calls = call_count(mem, "read");
    status = null_qp_access.attach_qp(null_qp_backing);
    expect_code("NULL_QP_VALIDATE", status, RDMA_SC_INVALID_STATE);
    if (call_count(mem, "write") != write_calls ||
        call_count(mem, "read") != read_calls)
      `uvm_error("NULL_QP_BACKEND", "null QP validation touched Host memory")
    status = null_qp_access.attach_qp(qp_backing);
    expect_code("NULL_QP_RETRY", status, RDMA_SC_OK);

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
