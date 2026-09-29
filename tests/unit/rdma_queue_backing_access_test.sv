// 目录：测试层 unit/rdma_queue_backing_access_test.sv。
// 职责：验证 queue/QP backing 的绑定、分段解析、完整权限预检与失败时的 I/O 前缀。
// 依赖：依赖 rdma_queue_backing_access、UVM、rdma_mock_host_mem 和 DMA mapping fixture。
// 所有权与生命周期：本测试创建 mock、mapping 与 backing；access 只借用它们，run_phase 结束后由 UVM 回收本地对象。

// 设计说明：预检失败必须零 I/O；后端失败可以留下已写前缀但不能继续后续 span，
// 读取失败必须清空输出。这三种契约不能混称为整个 Host-memory 事务可回滚。

// 只在 armed 的访问窗口记录实际 span 调用；故障发生在指定 span，已有成功写入不撤销。
class rdma_backing_span_fault_mem extends rdma_mock_host_mem;
  bit armed;
  bit fired;
  int unsigned mode;
  int unsigned fail_at;
  rdma_status failure;
  rdma_dma_mapping seen_mapping[$];
  longint unsigned seen_offset[$];
  int unsigned seen_length[$];

  // 功能：构造未启用的分段后端，预建带硬件码的错误供透传引用断言。
  // 输入/输出及副作用：name 传给 mock；本对象拥有 mock 内存，mapping 由 case 显式释放。
  // 失败/边界：armed 默认关闭，setup/cleanup 不注入；失败 status 不通过 factory 重建。
  function new(string name = "rdma_backing_span_fault_mem");
    super.new(name);
    armed = 1'b0;
    fired = 1'b0;
    failure = rdma_status::make_direct(RDMA_SC_DMA_TRANSLATION, "injected span failure");
    failure.hardware_code_valid = 1'b1;
    failure.hardware_code = 32'h12345678;
  endfunction

  // 功能：记录一个 backend span 的 mapping/offset/length，并判断是否抵达故障序号。
  // 输入/输出及副作用：mapping/offset/length 输入；armed 时追加借用引用和标量，命中置 fired。
  // 失败/边界：关闭注入不记录且返回 0；fail_at=0 不命中；不访问或释放 mapping。
  function bit visit(rdma_dma_mapping mapping, longint unsigned offset, int unsigned length);
    if (!armed)
      return 1'b0;
    seen_mapping.push_back(mapping);
    seen_offset.push_back(offset);
    seen_length.push_back(length);
    if (seen_mapping.size() != fail_at)
      return 1'b0;
    fired = 1'b1;
    return 1'b1;
  endfunction

  // 功能：在 write 的指定 span 注入 null/原始错误，其他 span 委托真实 mock 写入。
  // 输入/输出及副作用：mapping/offset/data 输入；成功前缀实际保留在内存中，返回原 status。
  // 失败/边界：mode=2/3 返回 null，4/5/6 返回 failure；这些失败 span 自身不写入，
  //   测试不得把这个注入器行为推断为所有真实后端都具备失败原子性。
  virtual function rdma_status write(
    rdma_dma_mapping mapping, longint unsigned offset, byte data[]
  );
    if (visit(mapping, offset, data.size())) begin
      if (mode inside {2, 3})
        return null;
      if (mode inside {4, 5, 6})
        return failure;
    end
    return super.write(mapping, offset, data);
  endfunction

  // 功能：在 read 指定 span 注入 null/原始错误，或返回成功但长度短/长的 payload。
  // 输入/输出及副作用：mapping/offset/size 输入，data 输出；正常读取实际 mock bytes。
  // 失败/边界：mode=2/3/4/5/6 的 data 故意预填垃圾以检查 caller 清空，7/8 修改
  //   实际读取长度；未 armed 的 setup/验证读取不记录，也不改变故障命中数。
  virtual function rdma_status read(
    rdma_dma_mapping mapping, longint unsigned offset, int unsigned size, output byte data[]
  );
    bit hit;
    rdma_status status;

    hit = visit(mapping, offset, size);
    if (hit && mode inside {2, 3, 4, 5, 6}) begin
      data = new[3];
      foreach (data[i]) data[i] = 8'hee;
      return mode inside {2, 3} ? null : failure;
    end
    status = super.read(mapping, offset, size, data);
    if (hit && status != null && status.ok()) begin
      if (mode == 7) data = new[size - 1](data);
      if (mode == 8) data = new[size + 1](data);
    end
    return status;
  endfunction
endclass

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

  // 功能：check_span_transfer_case 用三个非零 mapping offset 的 segment 检查四种访问
  //   入口的顺序、字节拼接、权限与部分失败，分别经 queue/QP backing 路径执行。
  // 输入/输出及副作用：qp_view/operation/mode 选择 backing、write/device-write/read/
  //   readback 与故障；每例新建三个 16-KiB mapping，记录后端调用，结束时显式 release。
  // 失败/边界：mode=0 成功，1 后段权限不足，2/3 首/末 null，4/5/6 首/中/末错误，
  //   7/8 中段短读/末段长读，9 未对齐，10 超 coverage；拒绝后不执行后续 span，
  //   read 输出清空、write 只保留成功前缀，device started 仅在进入后端时为 1。
  task automatic check_span_transfer_case(bit qp_view, int unsigned operation, int unsigned mode);
    rdma_backing_span_fault_mem mem;
    rdma_queue_backing_access access;
    rdma_dma_mapping mappings[3];
    rdma_queue_backing_ref backing;
    rdma_qp_backing_ref qp_backing;
    rdma_queue_backing_segment segment;
    rdma_status status;
    byte payload[], data[], seed[], observed[];
    int unsigned offsets[3] = '{8184, 8192, 12288};
    int unsigned lengths[3] = '{8, 4096, 8};
    int unsigned positions[3] = '{0, 8, 4104};
    int unsigned expected_calls, completed_writes;
    longint unsigned offset;
    bit started, is_read;
    string label;

    mem = new();
    access = new("span_matrix_access");
    backing = new("span_matrix_queue");
    qp_backing = new("span_matrix_qp");
    is_read = operation >= 2;
    payload = new[4112];
    foreach (payload[i]) payload[i] = byte'(8'h30 + i);
    foreach (mappings[i]) begin
      status = mem.allocate(ctx(), 16384, 4096, RDMA_DMA_BIDIRECTIONAL, mappings[i]);
      if (status == null || !status.ok() || mappings[i] == null)
        `uvm_fatal("SPAN_TRANSFER", "mapping fixture allocation failed")
      seed = new[16384];
      foreach (seed[j]) seed[j] = 8'ha5;
      if (is_read)
        for (int unsigned j = 0; j < lengths[i]; j++)
          seed[offsets[i] + j] = payload[positions[i] + j];
      status = mem.write(mappings[i], 0, seed);
      expect_code("SPAN_SEED", status, RDMA_SC_OK);
    end
    backing.role = RDMA_QUEUE_ROLE_CQ_RING;
    backing.mapping = mappings[0];
    backing.mapping_offset = 4096;
    backing.length = 4096;
    backing.ownership = RDMA_OWNERSHIP_BORROWED;
    qp_backing.role = RDMA_QUEUE_ROLE_QP_SQ_RING;
    qp_backing.mapping = mappings[0];
    qp_backing.mapping_offset = 4096;
    qp_backing.length = 4096;
    qp_backing.ownership = RDMA_OWNERSHIP_BORROWED;
    for (int unsigned i = 1; i < 3; i++) begin
      segment = new("span_matrix_segment");
      segment.role = qp_view ? qp_backing.role : backing.role;
      segment.mapping = mappings[i];
      segment.mapping_offset = offsets[i];
      segment.logical_queue_offset = i * 4096;
      segment.length = 4096;
      segment.ownership = RDMA_OWNERSHIP_BORROWED;
      if (qp_view) qp_backing.additional_segments.push_back(segment);
      else backing.additional_segments.push_back(segment);
    end
    status = access.configure(fn(), mem);
    expect_code("SPAN_CONFIG", status, RDMA_SC_OK);
    if (qp_view) status = access.attach_qp(qp_backing);
    else status = access.attach_queue(backing);
    if (status == null || !status.ok())
      `uvm_fatal("SPAN_TRANSFER", status == null ? "backing fixture attach returned null" :
                 {"backing fixture attach failed: ", status.convert2string()})

    // 只授予当前业务方向；对面权限始终关闭，避免误把 readback 当成 device write。
    foreach (mappings[i]) begin
      mappings[i].permissions.device_read = operation inside {0, 3};
      mappings[i].permissions.device_write = operation inside {1, 2};
    end
    if (mode == 1) begin
      mappings[2].permissions.device_read = 1'b0;
      mappings[2].permissions.device_write = 1'b0;
    end
    mem.mode = mode;
    case (mode)
      2, 4: mem.fail_at = 1;
      5, 7: mem.fail_at = 2;
      3, 6, 8: mem.fail_at = 3;
      default: mem.fail_at = 0;
    endcase
    expected_calls = mode inside {1, 9, 10} ? 0 :
                     mode == 0 ? 3 : mem.fail_at;
    offset = mode == 9 ? 4089 : mode == 10 ? 12280 : 4088;
    label = operation == 0 ? "write" : operation == 1 ? "device write" :
            operation == 2 ? "read" : "readback";
    data = new[5];
    started = 1'b1;
    mem.armed = 1'b1;
    case (operation)
      0: status = access.write(offset, payload);
      1: status = access.write_device(offset, payload, started);
      2: status = access.read(offset, payload.size(), data);
      3: status = access.readback(offset, payload.size(), data);
      default: `uvm_fatal("SPAN_TRANSFER", "unknown operation")
    endcase
    mem.armed = 1'b0;
    if (mem.seen_mapping.size() != expected_calls ||
        mem.fired != (mode >= 2 && mode <= 8))
      `uvm_error("SPAN_TRANSFER", "wrong backend prefix or fault did not fire")
    foreach (mem.seen_mapping[i]) begin
      if (i >= 3 || mem.seen_mapping[i] != mappings[i] ||
          mem.seen_offset[i] != offsets[i] || mem.seen_length[i] != lengths[i])
        `uvm_error("SPAN_TRANSFER", "mapping/offset/length order changed")
    end
    if (operation == 1 && started != (expected_calls != 0))
      `uvm_error("SPAN_TRANSFER", "device backend-started evidence changed")
    if (mode == 0) expect_code("SPAN_SUCCESS", status, RDMA_SC_OK);
    else if (mode == 1) expect_code("SPAN_PERMISSION", status, RDMA_SC_DMA_PERMISSION);
    else if (mode == 9) expect_code("SPAN_ALIGNMENT", status, RDMA_SC_INVALID_ARGUMENT);
    else if (mode == 10) expect_code("SPAN_COVERAGE", status, RDMA_SC_DMA_TRANSLATION);
    else if (mode inside {2, 3}) begin
      expect_code("SPAN_NULL", status, RDMA_SC_INVALID_STATE);
      if (status != null && status.message != {"host memory ", label, " returned null status"})
        `uvm_error("SPAN_TRANSFER", "null status diagnostic changed")
    end
    else if (mode inside {7, 8}) begin
      expect_code("SPAN_LENGTH", status, RDMA_SC_DMA_TRANSLATION);
      if (status != null && status.message != {"host memory ", label, " returned short data"})
        `uvm_error("SPAN_TRANSFER", "short/oversize read diagnostic changed")
    end
    else if (status != mem.failure || status.hardware_code != 32'h12345678)
      `uvm_error("SPAN_TRANSFER", "backend error was not passed through unchanged")
    if (is_read) begin
      if (mode != 0 && data.size() != 0)
        `uvm_error("SPAN_TRANSFER", "failed read exposed partial bytes")
      if (mode == 0) begin
        if (data.size() != payload.size())
          `uvm_error("SPAN_TRANSFER", "successful read length changed")
        else foreach (data[i])
          if (data[i] !== payload[i])
            `uvm_error("SPAN_TRANSFER", "cross-span read byte order changed")
      end
    end
    completed_writes = is_read ? 0 : mode == 0 ? 3 :
                       expected_calls == 0 ? 0 : expected_calls - 1;
    foreach (mappings[i]) begin
      status = mem.read(mappings[i], 0, 16384, observed);
      expect_code("SPAN_VERIFY_MEMORY", status, RDMA_SC_OK);
      foreach (observed[j]) begin
        if ((is_read || i < completed_writes) &&
            j >= offsets[i] && j < offsets[i] + lengths[i]) begin
          if (observed[j] !== payload[positions[i] + j - offsets[i]])
            `uvm_error("SPAN_TRANSFER", "successful prefix bytes changed")
        end
        else if (observed[j] !== 8'ha5)
          `uvm_error("SPAN_TRANSFER", "failed/unvisited span or guard byte was overwritten")
      end
    end
    access.clear();
    if (call_count(mem, "release") != 0)
      `uvm_error("SPAN_TRANSFER", "access released borrowed mapping")
    foreach (mappings[i]) begin
      status = mem.\release (mappings[i]);
      expect_code("SPAN_RELEASE", status, RDMA_SC_OK);
    end
    if (mem.live_allocations() != 0)
      `uvm_error("SPAN_TRANSFER", "fixture leaked mapping")
    `uvm_info("SPAN_TRANSFER", $sformatf("completed span transfer case qp=%0b op=%0d mode=%0d",
      qp_view, operation, mode), UVM_LOW)
  endtask

  // 功能：构造相邻 DMA segment，覆盖原绑定/解析契约及 80-case 分段访问矩阵。
  // 输入/输出及副作用：phase（输入）；raise/drop objection 包围所有检查；task 创建并修改本地 mock、mapping、backing 与 access，UVM error 是可观察失败输出。
  // 失败/边界：普通断言失败仍继续收集错误；新矩阵的 allocation/attach 失败以 fatal
  //   终止仿真，正常完成才 drop objection；矩阵每例显式释放自身 mapping。
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

    for (int unsigned qp = 0; qp < 2; qp++)
      for (int unsigned operation = 0; operation < 4; operation++)
        for (int unsigned mode = 0; mode < 11; mode++) begin
          if (operation < 2 && mode inside {7, 8}) continue;
          check_span_transfer_case(qp != 0, operation, mode);
        end
    `uvm_info("SPAN_TRANSFER", "completed 80 span transfer cases", UVM_LOW)

    phase.drop_objection(this);
  endtask
endclass
