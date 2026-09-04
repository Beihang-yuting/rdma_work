// 目录：测试层 unit/rdma_sq_payload_writer_test.sv。
// 职责：验证 rdma_sq_payload_writer_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_sq_payload_writer_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_sq_payload_writer_test extends uvm_test;
  `uvm_component_utils(rdma_sq_payload_writer_test)

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_sq_payload_writer_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：依据输入请求创建对应的值对象或资源计划，并校验依赖、所有权和生命周期后返回结果。
  // 输入/输出及副作用：输入请求、容量和依赖用于构造/预留资源；返回独立对象或状态，不暴露内部可变集合。
  //   参数越界、容量不足或构造中途失败时回滚已登记的局部状态。
  // 失败/边界：依赖为空、参数越界、容量不足或构造步骤失败时清理局部结果并返回明确错误。
  function automatic rdma_function_binding make_binding(string name);
    rdma_function_binding result;
    result = rdma_function_binding::type_id::create(name);
    result.function_uid = 64'h0123_4567_89ab_cdef;
    result.generation = 7;
    result.global_function_id = 32'h9000_0101;
    result.pcie.bdf = '{segment:16'h1001, bus:8'h20, device:5'h03,
                        function_num:3'h5};
    if (!result.configure_identity_from_legacy_mirrors(
          16'h0, 32'h1, RDMA_FUNCTION_PF).ok())
      `uvm_error("BINDING", "legacy binding identity configuration failed")
    result.queue_dma.requester_bdf = result.pcie.bdf;
    result.queue_dma.pasid_valid = 1'b1;
    result.queue_dma.pasid = 20'habcde;
    result.queue_dma.dma_domain_valid = 1'b1;
    result.queue_dma.dma_domain_id = 32'h1122_3344;
    result.state = RDMA_BIND_ACTIVE;
    return result;
  endfunction

  // 功能：依据输入请求创建对应的值对象或资源计划，并校验依赖、所有权和生命周期后返回结果。
  // 输入/输出及副作用：输入请求、容量和依赖用于构造/预留资源；返回独立对象或状态，不暴露内部可变集合。
  //   参数越界、容量不足或构造中途失败时回滚已登记的局部状态。
  // 失败/边界：依赖为空、参数越界、容量不足或构造步骤失败时清理局部结果并返回明确错误。
  function automatic rdma_dma_request_context make_context(
    rdma_function_binding binding,
    string name = "writer_context"
  );
    rdma_dma_request_context result;
    result = rdma_dma_request_context::type_id::create(name);
    result.function_h = binding.make_handle();
    result.requester_bdf = binding.queue_dma.requester_bdf;
    result.pasid_valid = binding.queue_dma.pasid_valid;
    result.pasid = binding.queue_dma.pasid;
    result.dma_domain_valid = binding.queue_dma.dma_domain_valid;
    result.dma_domain_id = binding.queue_dma.dma_domain_id;
    return result;
  endfunction

  // 功能：依据输入请求创建对应的值对象或资源计划，并校验依赖、所有权和生命周期后返回结果。
  // 输入/输出及副作用：输入请求、容量和依赖用于构造/预留资源；返回独立对象或状态，不暴露内部可变集合。
  //   参数越界、容量不足或构造中途失败时回滚已登记的局部状态。
  // 失败/边界：依赖为空、参数越界、容量不足或构造步骤失败时清理局部结果并返回明确错误。
  function automatic rdma_sge make_sge(string name,
                                        longint unsigned iova,
                                        longint unsigned length);
    rdma_sge result;
    result = rdma_sge::type_id::create(name);
    result.iova.value = iova;
    result.length = length;
    return result;
  endfunction

  // 功能：判断 count_calls 对应的状态、能力或账本条件，并返回确定的布尔/计数结果，不修改状态。
  // 输入/输出及副作用：参数 memory, method_name 用于执行 count_calls；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：count_calls 只读取现有账本；输入未初始化时返回保守结果，不得借助默认 Function/root 猜测。
  function automatic int count_calls(rdma_mock_host_mem memory,
                                      string method_name);
    int result;
    result = 0;
    foreach (memory.calls[i])
      if (memory.calls[i].method_name == method_name)
        result++;
    return result;
  endfunction

  // 功能：在测试中检查调用结果、状态码和副作用是否符合契约；失败时报告可定位的验证信息。
  // 输入/输出及副作用：参数 label, status, expected 用于执行 expect_code；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：测试前置对象缺失时应报告断言错误并停止依赖该对象的后续检查。
  function automatic void expect_code(string label, rdma_status status,
                                       rdma_status_code_e expected);
    if (status == null || status.code != expected)
      `uvm_error(label, $sformatf("expected %s, got %s", expected.name(),
                                  status == null ? "null" :
                                  status.convert2string()))
  endfunction

  // 功能：在测试中检查调用结果、状态码和副作用是否符合契约；失败时报告可定位的验证信息。
  // 输入/输出及副作用：参数 label, status 用于执行 expect_ok；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：测试前置对象缺失时应报告断言错误并停止依赖该对象的后续检查。
  function automatic void expect_ok(string label, rdma_status status);
    if (status == null || !status.ok())
      `uvm_error(label, status == null ? "null status" :
                 status.convert2string())
  endfunction

  // 功能：驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase 控制 UVM 调度；task 驱动事务、断言和 objection，测试 fixture 由本层负责清理。
  //   阶段提前结束或前置 setup 失败时必须释放 objection 并停止后续访问。
  // 失败/边界：setup 失败或阶段被终止时停止新增事务，确保 objection、临时对象和外部引用按测试生命周期收尾。
  task run_phase(uvm_phase phase);
    rdma_function_binding binding;
    rdma_dma_request_context request_context;
    rdma_host_mem_sq_payload_writer writer;
    rdma_mock_host_mem memory;
    rdma_dma_mapping mapping;
    rdma_dma_mapping second_mapping;
    rdma_sge sge;
    rdma_sge sges[$];
    rdma_sq_payload_write_receipt receipt;
    rdma_sq_payload_write_receipt detached;
    byte unsigned payload[$];
    rdma_status status;
    longint unsigned registration_id;
    longint unsigned second_id;
    longint unsigned rejected_id;
    longint unsigned second_iova;
    int unsigned second_size;
    int writes_before;
    int reads_before;

    phase.raise_objection(this);
    binding = make_binding("binding");
    request_context = make_context(binding);
    memory = rdma_mock_host_mem::type_id::create("memory");
    writer = rdma_host_mem_sq_payload_writer::type_id::create("writer");
    expect_ok("CONFIGURE", writer.configure(memory, binding, 0));

    // Allocate a real mock host-memory region with matching identity and
    // device-read permission, then scatter two SGEs and verify readback.
    expect_ok("ALLOCATE", memory.allocate(request_context, 64, 16,
                                           RDMA_DMA_DEVICE_READ, mapping));
    expect_ok("REGISTER", writer.register_mapping(mapping, registration_id));
    sges.push_back(make_sge("sge0", mapping.iova.value + 8, 3));
    sges.push_back(make_sge("sge1", mapping.iova.value + 32, 2));
    payload = '{8'h11, 8'h22, 8'h33, 8'h44, 8'h55};
    status = writer.stage_and_verify(request_context, sges, payload, receipt);
    expect_ok("STAGE_SUCCESS", status);
    if (receipt == null || !receipt.verified || receipt.payload.size() != 5 ||
        receipt.registration_ids.size() != 1)
      `uvm_error("STAGE_SUCCESS", "receipt is incomplete");
    if (memory.calls.size() != 5 || count_calls(memory, "write") != 2 ||
        count_calls(memory, "read") != 2)
      `uvm_error("SCATTER_TRACE", "expected one write/read pair per SGE");

    // Receipt is a detached deep snapshot of request data and mapping data.
    payload[2] = 8'haa;
    sges[0].iova.value = mapping.iova.value + 40;
    if (receipt.payload[2] !== 8'h33 ||
        receipt.sges[0].iova.value != mapping.iova.value + 8)
      `uvm_error("DETACHED", "receipt aliases mutable caller data");
    detached = rdma_sq_payload_write_receipt::type_id::create("detached");
    detached.copy(receipt);
    receipt.payload[0] = 8'hff;
    if (detached.payload[0] !== 8'h11)
      `uvm_error("DEEP_COPY", "receipt copy is not detached");
    expect_code("UNREGISTER_BUSY", writer.unregister_mapping(registration_id),
                RDMA_SC_RESOURCE_BUSY);
    expect_ok("RELEASE", writer.release_receipt(receipt));
    expect_ok("RELEASE_IDEMPOTENT", writer.release_receipt(receipt));
    expect_ok("UNREGISTER", writer.unregister_mapping(registration_id));

    // Missing registration and payload mismatch must be side-effect free.
    memory.reset();
    writer.regs.delete();
    request_context = make_context(binding, "context_missing");
    sges.delete();
    sges.push_back(make_sge("unregistered", 64'h4000, 4));
    payload = '{1, 2, 3, 4};
    writes_before = count_calls(memory, "write");
    status = writer.stage_and_verify(request_context, sges, payload, receipt);
    expect_code("MISSING_REG", status, RDMA_SC_DMA_TRANSLATION);
    if (receipt != null || count_calls(memory, "write") != writes_before)
      `uvm_error("MISSING_REG", "failed preflight performed a write");

    expect_ok("ALLOCATE2", memory.allocate(request_context, 32, 16,
                                            RDMA_DMA_DEVICE_READ, second_mapping));
    second_iova = second_mapping.iova.value;
    second_size = second_mapping.size;
    expect_ok("REGISTER2", writer.register_mapping(second_mapping, second_id));
    sges[0].iova.value = second_mapping.iova.value;
    payload = '{1, 2};
    writes_before = count_calls(memory, "write");
    status = writer.stage_and_verify(request_context, sges, payload, receipt);
    expect_code("PAYLOAD_MISMATCH", status, RDMA_SC_INVALID_ARGUMENT);
    if (receipt != null || count_calls(memory, "write") != writes_before)
      `uvm_error("PAYLOAD_MISMATCH", "length preflight performed a write");

    // Function generation, BDF, PASID and domain mismatches are rejected
    // before host-memory calls, as are inactive/missing-permission mappings.
    request_context.function_h.generation++;
    writes_before = count_calls(memory, "write");
    status = writer.stage_and_verify(request_context, sges, '{1, 2, 3, 4}, receipt);
    expect_code("GENERATION", status, RDMA_SC_STALE_GENERATION);
    if (count_calls(memory, "write") != writes_before)
      `uvm_error("GENERATION", "identity failure performed a write");
    request_context = make_context(binding, "context_bad_bdf");
    request_context.requester_bdf.bus++;
    status = writer.stage_and_verify(request_context, sges, '{1, 2, 3, 4}, receipt);
    expect_code("BDF", status, RDMA_SC_DMA_TRANSLATION);
    request_context = make_context(binding, "context_bad_pasid");
    request_context.pasid++;
    status = writer.stage_and_verify(request_context, sges, '{1, 2, 3, 4}, receipt);
    expect_code("PASID", status, RDMA_SC_DMA_TRANSLATION);
    request_context = make_context(binding, "context_bad_domain");
    request_context.dma_domain_id++;
    status = writer.stage_and_verify(request_context, sges, '{1, 2, 3, 4}, receipt);
    expect_code("DOMAIN", status, RDMA_SC_DMA_TRANSLATION);
    writer.regs[0].mapping.state = RDMA_MAPPING_FROZEN;
    request_context = make_context(binding, "context_inactive");
    status = writer.stage_and_verify(request_context, sges, '{1, 2, 3, 4}, receipt);
    expect_code("INACTIVE", status, RDMA_SC_INVALID_STATE);
    writer.regs[0].mapping.state = RDMA_MAPPING_ACTIVE;
    writer.regs[0].mapping.permissions.device_read = 1'b0;
    status = writer.stage_and_verify(request_context, sges, '{1, 2, 3, 4}, receipt);
    expect_code("PERMISSION", status, RDMA_SC_DMA_PERMISSION);

    // Checked range overflow and overlap are rejected at registration.
    writer.regs[0].mapping.permissions.device_read = 1'b1;
    second_mapping.iova.value = 64'hffff_ffff_ffff_fffe;
    second_mapping.size = 4;
    expect_code("REG_RANGE_OVERFLOW", writer.register_mapping(second_mapping,
                                                               rejected_id),
                RDMA_SC_DMA_TRANSLATION);
    second_mapping.iova.value = mapping.iova.value + 16;
    second_mapping.size = 8;
    expect_code("REG_OVERLAP", writer.register_mapping(second_mapping,
                                                         rejected_id),
                RDMA_SC_RESOURCE_BUSY);

    // Write failure and readback mismatch return null receipts and release
    // the temporary registration reference exactly once.
    expect_ok("UNREGISTER2", writer.unregister_mapping(second_id));
    second_mapping.iova.value = second_iova;
    second_mapping.size = second_size;
    expect_ok("REGISTER3", writer.register_mapping(second_mapping, second_id));
    sges.delete();
    sges.push_back(make_sge("failure_sge", second_mapping.iova.value, 4));
    payload = '{8'h90, 8'h91, 8'h92, 8'h93};
    expect_ok("FAIL_WRITE_SETUP", memory.fail_next("write",
      rdma_status::make(RDMA_SC_PCIE_COMPLETION, "injected write failure")));
    status = writer.stage_and_verify(request_context, sges, payload, receipt);
    if (status == null || status.ok() || receipt != null)
      `uvm_error("WRITE_FAILURE", "write failure was accepted");
    memory.corrupt_next_readback = 1'b1;
    reads_before = count_calls(memory, "read");
    status = writer.stage_and_verify(request_context, sges, payload, receipt);
    expect_code("READBACK_MISMATCH", status, RDMA_SC_DMA_TRANSLATION);
    if (receipt != null || count_calls(memory, "read") != reads_before + 1)
      `uvm_error("READBACK_MISMATCH", "mismatch published a receipt");
    expect_code("RELEASE_DETACHED_COPY", writer.release_receipt(detached),
                RDMA_SC_INVALID_ARGUMENT);
    expect_ok("UNREGISTER3", writer.unregister_mapping(second_id));
    phase.drop_objection(this);
  endtask
endclass
