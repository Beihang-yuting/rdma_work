// 目录：测试层 unit/rdma_sq_payload_writer_test.sv。
// 职责：验证 rdma_sq_payload_writer_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_sq_payload_writer_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

// 设计说明：该 mapping 在注册阶段允许正常 clone，在 stage_and_verify 的
// receipt 快照阶段可切换为 null clone，验证 late clone 失败不会先写 Host-memory。
class rdma_late_clone_failure_mapping extends rdma_mock_dma_mapping;
  `uvm_object_utils(rdma_late_clone_failure_mapping)

  static bit fail_clone;

  // 功能：构造 late-clone 故障映射，沿用 mock DMA mapping 的 opaque allocation authority，并把 fail_clone 默认设为关闭。
  // 输入/输出及副作用：name（输入）；new 只初始化本地故障开关，不复制或接管 Host-memory region、token 或 writer 引用。
  // 失败/边界：构造本身不注入故障；只有 fail_clone 被置位后，后续 clone 才返回 null。
  function new(string name = "rdma_late_clone_failure_mapping");
    super.new(name);
    fail_clone = 1'b0;
  endfunction

  // 功能：设置 late-clone 映射的全局 clone 故障开关，供注册前后切换同一 mapping 的行为。
  // 输入/输出及副作用：value（输入）；只更新本测试夹具的静态 fail_clone，不修改 mapping geometry、token 或后端 region。
  // 失败/边界：重复设置幂等；打开后所有该类型 mapping 的 clone 都返回 null，关闭后恢复父类 detached clone。
  static function void set_fail_clone(bit value);
    fail_clone = value;
  endfunction

  // 功能：在 receipt mapping 快照阶段注入 null clone，或在故障关闭时返回父类建立的 detached mapping snapshot。
  // 输入/输出及副作用：无显式输入；fail_clone 打开时返回 null，关闭时调用父类 clone，不改变源 mapping 的字段或 Host-memory 数据。
  // 失败/边界：null 返回值是刻意测试故障；调用方必须在任何 Host-memory 写入和 refs++ 前拒绝该结果。
  virtual function uvm_object clone();
    if (fail_clone)
      return null;
    return super.clone();
  endfunction
endclass

// 功能：构造可控返回 null rdma_status 的 Host-memory mock，覆盖 payload writer 的外部 API 边界。
// 输入/输出及副作用：name（输入）；构造函数沿用正常 mock 的区域账本；write/read 在对应开关打开时返回 null，不改写后端数据。
// 失败/边界：该夹具只用于验证 writer 将外部 null 状态归一化为确定失败；未打开开关时沿用基类的正常分配、写入和读取行为。
class rdma_null_status_sq_host_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_null_status_sq_host_mem)

  bit return_null_write;
  bit return_null_read;

  // 功能：创建 null-status Host-memory 故障夹具并初始化两个注入开关。
  // 输入/输出及副作用：name（输入）；new 只初始化本地开关，不接管 mapping、region 或 writer 所有权。
  // 失败/边界：开关默认为关闭，夹具默认行为与 rdma_mock_host_mem 相同。
  function new(string name = "rdma_null_status_sq_host_mem");
    super.new(name);
    return_null_write = 1'b0;
    return_null_read = 1'b0;
  endfunction

  // 功能：模拟 Host-memory write 丢失状态，验证 stage_and_verify 在发布 registration 引用后仍能 fail closed 并回滚。
  // 输入/输出及副作用：mapping、offset、data（输入）；注入开启时返回 null 且不写区域，关闭时调用基类实现。
  // 失败/边界：null 返回值是刻意故障；调用方不得调用 status.ok()，也不得留下 live receipt 或 registration 引用。
  virtual function rdma_status write(
    rdma_dma_mapping mapping,
    longint unsigned offset,
    byte data[]
  );
    if (return_null_write)
      return null;
    return super.write(mapping, offset, data);
  endfunction

  // 功能：模拟 Host-memory read 丢失状态，验证 payload readback 阶段将 null 归一化为确定失败。
  // 输入/输出及副作用：mapping、offset、size（输入）、data（输出）；注入开启时清空 data 并返回 null，关闭时调用基类实现。
  // 失败/边界：null 返回值不得被当作成功或继续解引用；关闭注入时保留基类的 detached readback 语义。
  virtual function rdma_status read(
    rdma_dma_mapping mapping,
    longint unsigned offset,
    int unsigned size,
    output byte data[]
  );
    if (return_null_read) begin
      data = new[0];
      return null;
    end
    return super.read(mapping, offset, size, data);
  endfunction
endclass

class rdma_sq_payload_writer_test extends uvm_test;
  `uvm_component_utils(rdma_sq_payload_writer_test)

  // 功能：构造 rdma_sq_payload_writer_test，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_sq_payload_writer_test 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_sq_payload_writer_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：make_binding 创建独立的 rdma_function_binding；根据 name 设置字段 result、result.function_uid、result.generation、result.global_function_id、pcie.bdf、queue_dma.requester_bdf、queue_dma.pasid_valid、queue_dma.pasid、queue_dma.dma_domain_valid、queue_dma.dma_domain_id，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）；make_binding 读取 name 并使用字段 result、result.function_uid、result.generation、result.global_function_id、pcie.bdf、queue_dma.requester_bdf、queue_dma.pasid_valid、queue_dma.pasid；函数返回 rdma_function_binding，不取得调用方资源所有权。
  // 失败/边界：make_binding 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
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

  // 功能：make_context 创建独立的 rdma_dma_request_context；根据 binding、name 设置字段 result、result.function_h、result.requester_bdf、result.pasid_valid、result.pasid、result.dma_domain_valid、result.dma_domain_id，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：binding（输入）、writer_context（输入）；make_context 读取 binding、name 并使用字段 result、result.function_h、result.requester_bdf、result.pasid_valid、result.pasid、result.dma_domain_valid、result.dma_domain_id；函数返回 rdma_dma_request_context，不取得调用方资源所有权。
  // 失败/边界：make_context 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
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

  // 功能：make_sge 创建独立的 rdma_sge；根据 name、iova、length 设置字段 result、iova.value、result.length，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、iova（输入）、length（输入）；make_sge 读取 name、iova、length 并使用字段 result、iova.value、result.length；函数返回 rdma_sge，不取得调用方资源所有权。
  // 失败/边界：make_sge 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
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
  // 输入/输出及副作用：memory（输入）、method_name（输入）；count_calls 读取 memory、method_name 并使用字段 result；函数返回 int，不取得调用方资源所有权。
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

  // 功能：在 rdma_sq_payload_writer_test 中，expect_code 在测试中执行 expect_code 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、status（输入）、expected（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_code 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function automatic void expect_code(string label, rdma_status status,
                                       rdma_status_code_e expected);
    if (status == null || status.code != expected)
      `uvm_error(label, $sformatf("expected %s, got %s", expected.name(),
                                  status == null ? "null" :
                                  status.convert2string()))
  endfunction

  // 功能：在 rdma_sq_payload_writer_test 中，expect_ok 在测试中执行 expect_ok 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、status（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_ok 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function automatic void expect_ok(string label, rdma_status status);
    if (status == null || !status.ok())
      `uvm_error(label, status == null ? "null status" :
                 status.convert2string())
  endfunction

  // 功能：在 rdma_sq_payload_writer_test 中，run_phase 驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：run_phase 的 setup/阶段驱动失败时停止新增事务，并按测试生命周期清理 objection 与临时引用。
  task run_phase(uvm_phase phase);
    rdma_function_binding binding;
    rdma_dma_request_context request_context;
    rdma_host_mem_sq_payload_writer writer;
    rdma_mock_host_mem memory;
    rdma_null_status_sq_host_mem null_memory;
    rdma_host_mem_sq_payload_writer null_writer;
    rdma_dma_mapping mapping;
    rdma_dma_mapping second_mapping;
    rdma_dma_mapping null_mapping;
    rdma_dma_mapping atomic_mapping;
    rdma_late_clone_failure_mapping late_clone_mapping;
    rdma_sge sge;
    rdma_sge sges[$];
    rdma_sq_payload_write_receipt receipt;
    rdma_sq_payload_write_receipt detached;
    byte unsigned payload[$];
    rdma_status status;
    longint unsigned registration_id;
    longint unsigned second_id;
    longint unsigned null_registration_id;
    longint unsigned atomic_id;
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

    // Receipt snapshot construction is a commit prerequisite.  A mapping
    // clone that fails after registration must not cause refs++ or Host-memory
    // writes before the failure is reported.
    expect_ok("LATE_CLONE_ALLOCATE",
               memory.allocate(request_context, 16, 16,
                               RDMA_DMA_DEVICE_READ, atomic_mapping));
    late_clone_mapping = rdma_late_clone_failure_mapping::type_id::create(
      "late_clone_mapping"
    );
    if (late_clone_mapping == null) begin
      `uvm_error("LATE_CLONE_SETUP", "late clone mapping allocation failed");
    end
    else begin
      late_clone_mapping.copy(atomic_mapping);
      expect_ok("LATE_CLONE_REGISTER",
                 writer.register_mapping(late_clone_mapping, atomic_id));
      // Keep the registered value's dynamic type explicit even if a factory
      // clone returns a base-compatible subtype.
      writer.regs[0].mapping = late_clone_mapping;
      rdma_late_clone_failure_mapping::set_fail_clone(1'b1);
      sges.delete();
      sges.push_back(make_sge("late_clone_sge", atomic_mapping.iova.value, 4));
      payload = '{8'h61, 8'h62, 8'h63, 8'h64};
      writes_before = count_calls(memory, "write");
      reads_before = count_calls(memory, "read");
      receipt = null;
      status = writer.stage_and_verify(request_context, sges, payload, receipt);
      expect_code("LATE_CLONE_FAILURE", status, RDMA_SC_INVALID_STATE);
      if (receipt != null || writer.regs[0].refs != 0 ||
          count_calls(memory, "write") != writes_before ||
          count_calls(memory, "read") != reads_before)
        `uvm_error("LATE_CLONE_ATOMICITY",
                   "late clone failure published refs or Host-memory I/O");
      rdma_late_clone_failure_mapping::set_fail_clone(1'b0);
      expect_ok("LATE_CLONE_UNREGISTER",
                 writer.unregister_mapping(atomic_id));
    end

    // External Host-memory APIs are virtual seams.  A null status from write
    // or read must be converted to INVALID_STATE and must not leave a live
    // registration reference or a published receipt.
    null_memory = rdma_null_status_sq_host_mem::type_id::create(
      "null_status_memory"
    );
    null_writer = rdma_host_mem_sq_payload_writer::type_id::create(
      "null_status_writer"
    );
    request_context = make_context(binding, "null_status_context");
    expect_ok("NULL_STATUS_CONFIGURE",
               null_writer.configure(null_memory, binding, 0));
    expect_ok("NULL_STATUS_ALLOCATE",
               null_memory.allocate(request_context, 16, 16,
                                    RDMA_DMA_DEVICE_READ, null_mapping));
    expect_ok("NULL_STATUS_REGISTER",
               null_writer.register_mapping(null_mapping,
                                             null_registration_id));
    sges.delete();
    sges.push_back(make_sge("null_status_sge", null_mapping.iova.value, 4));
    payload = '{8'h31, 8'h32, 8'h33, 8'h34};

    null_memory.return_null_write = 1'b1;
    receipt = null;
    status = null_writer.stage_and_verify(request_context, sges, payload,
                                          receipt);
    expect_code("NULL_STATUS_WRITE", status, RDMA_SC_INVALID_STATE);
    if (receipt != null || null_writer.regs[0].refs != 0)
      `uvm_error("NULL_STATUS_WRITE", "null write left a live receipt/reference");

    null_memory.return_null_write = 1'b0;
    null_memory.return_null_read = 1'b1;
    receipt = null;
    status = null_writer.stage_and_verify(request_context, sges, payload,
                                          receipt);
    expect_code("NULL_STATUS_READ", status, RDMA_SC_INVALID_STATE);
    if (receipt != null || null_writer.regs[0].refs != 0)
      `uvm_error("NULL_STATUS_READ", "null read left a live receipt/reference");

    expect_ok("NULL_STATUS_UNREGISTER",
               null_writer.unregister_mapping(null_registration_id));
    phase.drop_objection(this);
  endtask
endclass
