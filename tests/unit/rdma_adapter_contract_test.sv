// 目录：测试层 unit/rdma_adapter_contract_test.sv。
// 职责：验证 rdma_adapter_contract_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_adapter_contract_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_adapter_test_observer extends rdma_net_observer;
  `uvm_object_utils(rdma_adapter_test_observer)

  int unsigned notification_count;
  rdma_packet last_packet;

  // 功能：构造 rdma_adapter_test_observer，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：notification_count=0；last_packet=null。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_adapter_test_observer 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_adapter_test_observer");
    super.new(name);
    notification_count = 0;
    last_packet = null;
  endfunction

  // 功能：在 rdma_adapter_test_observer 中，write 把请求数据写入指定后端并保留返回状态；只有写入成功才允许本地游标继续推进。
  // 输入/输出及副作用：packet（输入）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过 output 返回结果。
  // 失败/边界：write 遇到后端拒绝、范围溢出或 DMA 权限不足时保留失败证据，不推进本地游标。
  virtual function void write(rdma_packet packet);
    uvm_object cloned_object;

    notification_count++;
    if (packet == null) begin
      last_packet = null;
      return;
    end
    cloned_object = packet.clone();
    if (cloned_object == null || !$cast(last_packet, cloned_object))
      `uvm_fatal("OBSERVER_COPY", "packet clone type mismatch")
  endfunction
endclass

class rdma_adapter_contract_test extends uvm_test;
  `uvm_component_utils(rdma_adapter_contract_test)

  // 功能：构造 rdma_adapter_contract_test，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_adapter_contract_test 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_adapter_contract_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：make_function_handle 创建独立的 rdma_function_handle；根据 name 设置字段 function_h、function_h.function_uid、function_h.object_id、function_h.generation，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）；make_function_handle 读取 name 并使用字段 function_h、function_h.function_uid、function_h.object_id、function_h.generation；函数返回 rdma_function_handle，不取得调用方资源所有权。
  // 失败/边界：make_function_handle 的结果直接由 return function_h 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_function_handle make_function_handle(string name);
    rdma_function_handle function_h;

    function_h = rdma_function_handle::type_id::create(name);
    function_h.function_uid = 64'h1234_5678_9abc_def0;
    function_h.object_id = 32'h1020_3040;
    function_h.generation = 32'd17;
    return function_h;
  endfunction

  // 功能：make_dma_context 创建独立的 rdma_dma_request_context；根据 name、function_h、requester_bdf、pasid_valid、pasid、owner_h 设置字段 result、result.function_h、result.requester_bdf、result.pasid_valid、result.pasid、result.owner_h，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、function_h（输入）、requester_bdf（输入）、pasid_valid（输入）、pasid（输入）、owner_h（输入）；输入字段被复制到返回值或
  //   output；生成结果与输入隔离，不隐式修改调用方对象。
  // 失败/边界：make_dma_context 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  function automatic rdma_dma_request_context make_dma_context(
    string name,
    rdma_function_handle function_h,
    rdma_bdf_t requester_bdf,
    bit pasid_valid = 1'b0,
    bit [19:0] pasid = '0,
    rdma_handle owner_h = null
  );
    rdma_dma_request_context result;
    result = rdma_dma_request_context::type_id::create(name);
    result.function_h = rdma_mock_clone_function_handle(function_h);
    result.requester_bdf = requester_bdf;
    result.pasid_valid = pasid_valid;
    result.pasid = pasid;
    result.owner_h = (owner_h == null) ? null :
                     rdma_clone_handle_value(owner_h, "DMA context owner");
    return result;
  endfunction

  // 功能：make_binding 创建独立的 rdma_function_binding；根据 name 设置字段 binding、binding.function_uid、binding.global_function_id、binding.generation、pcie.bdf、base.value、size、enabled、binding.notify_bar_id、notify_base.value，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）；make_binding 读取 name 并使用字段 binding、binding.function_uid、binding.global_function_id、binding.generation、pcie.bdf、base.value、size、enabled；函数返回 rdma_function_binding，不取得调用方资源所有权。
  // 失败/边界：make_binding 的结果直接由 return binding 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_function_binding make_binding(string name);
    rdma_function_binding binding;
    rdma_interrupt_vector_binding vector;

    binding = rdma_function_binding::type_id::create(name);
    binding.function_uid = 64'h1234_5678_9abc_def0;
    binding.global_function_id = 32'h1020_3040;
    binding.generation = 32'd17;
    binding.pcie.bdf = '{segment:16'h1, bus:8'h22, device:5'h3,
                         function_num:3'h4};
    if (!binding.configure_identity_from_legacy_mirrors(
          16'h0, 32'h1, RDMA_FUNCTION_PF).ok())
      `uvm_error("BINDING", "legacy binding identity configuration failed")
    binding.pcie.bar[0].base.value = 64'h8000_0000;
    binding.pcie.bar[0].size = 64'h4000;
    binding.pcie.bar[0].enabled = 1'b1;
    binding.notify_bar_id = 0;
    binding.notify_base.value = 64'h8000_2000;
    binding.notify_size = 64'h2000;
    binding.queue_dma.requester_bdf = binding.pcie.bdf;
    binding.queue_dma.pasid_valid = 1'b1;
    binding.queue_dma.pasid = 20'h34567;
    binding.queue_dma.dma_domain_valid = 1'b1;
    binding.queue_dma.dma_domain_id = 32'h1122_3344;
    binding.queue_caps.min_cq_depth = 16;
    binding.queue_caps.max_cq_depth = 32768;
    binding.queue_caps.min_srq_depth = 16;
    binding.queue_caps.max_srq_depth = 32768;
    binding.queue_caps.max_ceq_depth = 4096;
    binding.queue_caps.max_aeq_depth = 4096;
    binding.queue_caps.max_wq_sge = 8;
    binding.queue_caps.max_queue_ring_bytes = 32'h0020_0000;
    binding.queue_caps.max_sgb_bytes = 32'h0040_0000;
    vector = '{default:'0};
    vector.function_local_vector = 3;
    vector.hardware_eq_vector = 17;
    vector.msix_table_index = 5;
    vector.enabled = 1'b1;
    binding.interrupt_vectors.push_back(vector);
    return binding;
  endfunction

  // 功能：make_packet 根据 name、value 生成或检查硬件镜像字段，保持布局、端序和保留位约束一致。
  // 输入/输出及副作用：name（输入）、value（输入）；make_packet 读取 name、value 并使用字段 packet、packet.transport、packet.opcode、packet.destination_qpn、packet.source_qpn、packet.psn；函数返回 rdma_packet，不取得调用方资源所有权。
  // 失败/边界：make_packet 的结果直接由 return packet 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_packet make_packet(string name, byte value);
    rdma_packet packet;

    packet = rdma_packet::type_id::create(name);
    packet.transport = RDMA_TRANSPORT_RC;
    packet.opcode = RDMA_NET_SEND;
    packet.destination_qpn = 24'h102030;
    packet.source_qpn = 24'h405060;
    packet.psn = 24'h708090;
    packet.payload.push_back(value);
    packet.payload.push_back(value + 1'b1);
    return packet;
  endfunction

  // 功能：在 rdma_adapter_contract_test 中，expect_status 在测试中执行 expect_status 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：check_name（输入）、status（输入）、expected_code（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT
  //   转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_status 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
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
                 $sformatf("expected %s, got %s", expected_code.name(),
                           status.code.name()))
  endfunction

  // 功能：在 rdma_adapter_contract_test 中，run_phase 驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：run_phase 的 setup/阶段驱动失败时停止新增事务，并按测试生命周期清理 objection 与临时引用。
  task run_phase(uvm_phase phase);
    rdma_mock_host_mem mem;
    rdma_host_mem_api mem_api;
    rdma_mock_host_mem authoritative_mem;
    rdma_host_mem_api authoritative_mem_api;
    rdma_mock_host_mem overflow_mem;
    rdma_host_mem_api overflow_mem_api;
    rdma_mock_host_mem identity_mem;
    rdma_host_mem_api identity_mem_api;
    rdma_mock_pcie pcie;
    rdma_pcie_api pcie_api;
    rdma_mock_function_table table;
    rdma_function_table_api table_api;
    rdma_mock_net net;
    rdma_net_api net_api;
    rdma_adapter_test_observer observer;
    rdma_function_handle function_h;
    rdma_dma_request_context request_context;
    rdma_dma_request_context context_snapshot;
    rdma_dma_request_context invalid_context;
    rdma_mock_host_mem validation_mem;
    rdma_host_mem_api validation_mem_api;
    rdma_handle owner_h;
    rdma_handle cross_owner_h;
    rdma_dma_mapping mapping;
    rdma_dma_mapping failed_mapping;
    rdma_dma_mapping second_mapping;
    rdma_dma_mapping authoritative_mapping;
    rdma_dma_mapping stale_active_mapping;
    rdma_dma_mapping overflow_mapping;
    rdma_dma_mapping identity_mapping_a;
    rdma_dma_mapping identity_mapping_a_snapshot;
    rdma_dma_mapping identity_mapping_b;
    rdma_dma_mapping forged_mapping;
    rdma_mock_dma_mapping identity_mock_mapping;
    rdma_mock_dma_mapping identity_mock_mapping_b;
    rdma_mock_dma_mapping identity_mock_mapping_snapshot;
    rdma_mock_dma_mapping third_mock_mapping;
    rdma_mock_release_seal third_mock_release_seal;
    rdma_function_binding binding;
    rdma_dma_permission_t read_permission;
    rdma_packet tx_packet;
    rdma_packet observer_seed;
    rdma_packet rx_source;
    rdma_packet rx_packet;
    rdma_net_response_policy policy;
    rdma_net_fault fault;
    rdma_pcie_function_info info;
    rdma_pcie_function_info info_result;
    rdma_bar_decode decode;
    rdma_bar_decode decode_result;
    rdma_status status;
    rdma_status normalized_status;
    rdma_status injected;
    uvm_object cloned_object;
    rdma_bdf_t bdf;
    rdma_cfg_offset_t cfg_offset;
    rdma_bar_addr_t bar_address;
    longint unsigned next_address_before;
    int unsigned region_count_before;
    bit [31:0] cfg_data;
    byte write_data[] = '{8'h11, 8'h22, 8'h33, 8'h44};
    byte read_data[];
    byte overflow_data[] = '{8'haa, 8'hbb};
    byte crossing_data[] = '{8'hde, 8'had};
    byte identity_a_data[] = '{8'ha1, 8'ha2};
    byte identity_b_data[] = '{8'hb1, 8'hb2};
    byte identity_read_data[];

    phase.raise_objection(this);

    normalized_status = rdma_adapter_status_policy::normalize(
      null, "test adapter", "status probe"
    );
    if (normalized_status == null ||
        normalized_status.code != RDMA_SC_INVALID_STATE ||
        normalized_status.message !=
          "test adapter status probe returned null status")
      `uvm_error("ADAPTER_STATUS_POLICY",
                 "null backend status was not normalized fail-closed")
    normalized_status = rdma_status::make(
      RDMA_SC_TIMEOUT, "backend timeout"
    );
    if (rdma_adapter_status_policy::normalize(
          normalized_status, "test adapter", "status probe") !=
        normalized_status)
      `uvm_error("ADAPTER_STATUS_POLICY",
                 "non-null backend status was not preserved")

    function_h = make_function_handle("function_h");
    bdf = '{segment:16'h1, bus:8'h22, device:5'h3, function_num:3'h4};
    owner_h = rdma_handle::type_id::create("dma_owner");
    owner_h.kind = RDMA_RESOURCE_CMQ;
    owner_h.function_uid = function_h.function_uid;
    owner_h.object_id = 32'h4455_6677;
    owner_h.generation = function_h.generation;
    request_context = make_dma_context(
      "request_context", function_h, bdf, 1'b1, 20'h34567, owner_h
    );
    request_context.dma_domain_valid = 1'b1;
    request_context.dma_domain_id = 32'h1122_3344;
    cfg_offset.value = 12'habc;
    bar_address.value = 64'h9000_0040;

    cloned_object = request_context.clone();
    if (cloned_object == null || !$cast(context_snapshot, cloned_object))
      `uvm_fatal("DMA_CONTEXT_CLONE", "DMA context clone type mismatch")
    if (context_snapshot == request_context ||
        context_snapshot.function_h == request_context.function_h ||
        context_snapshot.owner_h == request_context.owner_h ||
        !context_snapshot.function_h.same_instance(
          request_context.function_h
        ) || !context_snapshot.owner_h.same_instance(request_context.owner_h))
      `uvm_error("DMA_CONTEXT_CLONE",
                 "DMA context clone did not detach authority handles")

    validation_mem = rdma_mock_host_mem::type_id::create("validation_mem");
    validation_mem_api = validation_mem;
    status = validation_mem_api.allocate(
      null, 64, 64, RDMA_DMA_BIDIRECTIONAL, failed_mapping
    );
    expect_status("HOST_CONTEXT_NULL", status, RDMA_SC_INVALID_ARGUMENT);
    invalid_context = make_dma_context(
      "null_function_context", null, bdf
    );
    status = validation_mem_api.allocate(
      invalid_context, 64, 64, RDMA_DMA_BIDIRECTIONAL, failed_mapping
    );
    expect_status("HOST_CONTEXT_FUNCTION_NULL", status,
                  RDMA_SC_INVALID_ARGUMENT);
    invalid_context = make_dma_context(
      "wrong_kind_context", function_h, bdf
    );
    invalid_context.function_h.kind = RDMA_RESOURCE_PD;
    status = validation_mem_api.allocate(
      invalid_context, 64, 64, RDMA_DMA_BIDIRECTIONAL, failed_mapping
    );
    expect_status("HOST_CONTEXT_FUNCTION_KIND", status,
                  RDMA_SC_INVALID_ARGUMENT);
    invalid_context = make_dma_context(
      "zero_generation_context", function_h, bdf
    );
    invalid_context.function_h.generation = 0;
    status = validation_mem_api.allocate(
      invalid_context, 64, 64, RDMA_DMA_BIDIRECTIONAL, failed_mapping
    );
    expect_status("HOST_CONTEXT_FUNCTION_GENERATION", status,
                  RDMA_SC_STALE_GENERATION);
    invalid_context = make_dma_context(
      "invalid_pasid_context", function_h, bdf, 1'b0, 20'h1
    );
    status = validation_mem_api.allocate(
      invalid_context, 64, 64, RDMA_DMA_BIDIRECTIONAL, failed_mapping
    );
    expect_status("HOST_CONTEXT_PASID", status, RDMA_SC_INVALID_ARGUMENT);
    cross_owner_h = rdma_clone_handle_value(owner_h, "cross Function owner");
    cross_owner_h.function_uid++;
    invalid_context = make_dma_context(
      "cross_function_owner_context", function_h, bdf, 1'b0, '0,
      cross_owner_h
    );
    status = validation_mem_api.allocate(
      invalid_context, 64, 64, RDMA_DMA_BIDIRECTIONAL, failed_mapping
    );
    expect_status("HOST_CONTEXT_OWNER_FUNCTION", status,
                  RDMA_SC_INVALID_ARGUMENT);
    cross_owner_h = rdma_clone_handle_value(owner_h, "stale owner");
    cross_owner_h.generation++;
    invalid_context = make_dma_context(
      "stale_owner_context", function_h, bdf, 1'b0, '0, cross_owner_h
    );
    status = validation_mem_api.allocate(
      invalid_context, 64, 64, RDMA_DMA_BIDIRECTIONAL, failed_mapping
    );
    expect_status("HOST_CONTEXT_OWNER_GENERATION", status,
                  RDMA_SC_STALE_GENERATION);
    if (validation_mem.regions.size() != 0 ||
        validation_mem.next_address != 64'h0000_0001_0000_0000)
      `uvm_error("HOST_CONTEXT_VALIDATION",
                 "invalid DMA context changed allocator state")

    mem = rdma_mock_host_mem::type_id::create("mem");
    mem_api = mem;
    status = mem.fail_next(
      "allocatte", rdma_status::make(RDMA_SC_TIMEOUT, "typo")
    );
    expect_status("HOST_FAIL_KEY", status, RDMA_SC_INVALID_ARGUMENT);
    status = mem.fail_next("read", null);
    expect_status("HOST_FAIL_NULL", status, RDMA_SC_INVALID_ARGUMENT);
    if (mem.failures.exists("allocatte") || mem.failures.exists("read"))
      `uvm_error("HOST_FAIL_CONFIG",
                 "invalid host failure configuration was retained")
    status = mem_api.allocate(request_context, 4096, 4096,
                              RDMA_DMA_BIDIRECTIONAL, mapping);
    expect_status("HOST_ALLOCATE", status, RDMA_SC_OK);
    if (mapping == null || mapping.size != 4096 ||
        mapping.function_h == null ||
        mapping.function_h.generation != function_h.generation ||
        mapping.requester_bdf != bdf || !mapping.pasid_valid ||
        mapping.pasid != 20'h34567 || !mapping.dma_domain_valid ||
        mapping.dma_domain_id != 32'h1122_3344 ||
        mapping.owner_h == null ||
        mapping.owner_h == request_context.owner_h ||
        !mapping.owner_h.same_instance(request_context.owner_h))
      `uvm_error("HOST_ALLOCATE", "host adapter contract failed")
    if (mem.calls.size() != 1 || mem.calls[0].call_sequence != 1 ||
        mem.calls[0].method_name != "allocate" ||
        mem.calls[0].request_context == request_context ||
        mem.calls[0].request_context == null ||
        mem.calls[0].request_context.function_h ==
          request_context.function_h ||
        mem.calls[0].request_context.owner_h == request_context.owner_h ||
        mem.calls[0].request_context.function_h.generation != 17 ||
        mem.calls[0].request_context.requester_bdf != bdf ||
        !mem.calls[0].request_context.pasid_valid ||
        mem.calls[0].request_context.pasid != 20'h34567 ||
        !mem.calls[0].request_context.dma_domain_valid ||
        mem.calls[0].request_context.dma_domain_id != 32'h1122_3344 ||
        mem.calls[0].request_context.owner_h == null ||
        mem.calls[0].request_context.owner_h.object_id != 32'h4455_6677 ||
        mem.calls[0].size != 4096 || mem.calls[0].alignment != 4096)
      `uvm_error("HOST_RECORD", "allocate call was not recorded by value")

    binding = make_binding("queue_binding");
    expect_status("QUEUE_BINDING", binding.validate(), RDMA_SC_OK);
    read_permission = '{device_read:1'b1, device_write:1'b0, atomic:1'b0};
    expect_status("DOMAIN_MATCH", mapping.check_access(
      binding.make_handle(), binding.queue_dma.requester_bdf,
      binding.queue_dma.pasid_valid, binding.queue_dma.pasid,
      binding.queue_dma.dma_domain_valid, binding.queue_dma.dma_domain_id,
      mapping.iova, 4096, RDMA_DMA_DEVICE_READ, read_permission), RDMA_SC_OK);
    expect_status("DOMAIN_MISMATCH", mapping.check_access(
      binding.make_handle(), binding.queue_dma.requester_bdf,
      1'b1, 20'h34567, 1'b1, 32'h1122_3345,
      mapping.iova, 4096, RDMA_DMA_DEVICE_READ, read_permission),
      RDMA_SC_DMA_TRANSLATION);
    request_context.function_h.generation = 32'd99;
    request_context.requester_bdf.bus = 8'hff;
    request_context.pasid_valid = 1'b0;
    request_context.pasid = 20'h12345;
    request_context.dma_domain_valid = 1'b0;
    request_context.dma_domain_id = 32'hffff_ffff;
    request_context.owner_h.object_id = 32'hffff_ffff;
    if (mapping.function_h.generation != 17 ||
        mapping.requester_bdf != bdf || !mapping.pasid_valid ||
        mapping.pasid != 20'h34567 || !mapping.dma_domain_valid ||
        mapping.dma_domain_id != 32'h1122_3344 ||
        mapping.owner_h == null ||
        mapping.owner_h.object_id != 32'h4455_6677 ||
        mem.calls[0].request_context.function_h.generation != 17 ||
        mem.calls[0].request_context.requester_bdf != bdf ||
        !mem.calls[0].request_context.pasid_valid ||
        mem.calls[0].request_context.pasid != 20'h34567 ||
        !mem.calls[0].request_context.dma_domain_valid ||
        mem.calls[0].request_context.dma_domain_id != 32'h1122_3344 ||
        mem.calls[0].request_context.owner_h.object_id != 32'h4455_6677 ||
        mem.regions.size() != 1 || mem.regions[0].mapping == null ||
        mem.regions[0].mapping.function_h.generation != 17 ||
        mem.regions[0].mapping.requester_bdf != bdf ||
        !mem.regions[0].mapping.pasid_valid ||
        mem.regions[0].mapping.pasid != 20'h34567 ||
        !mem.regions[0].mapping.dma_domain_valid ||
        mem.regions[0].mapping.dma_domain_id != 32'h1122_3344 ||
        mem.regions[0].mapping.owner_h == null ||
        mem.regions[0].mapping.owner_h.object_id != 32'h4455_6677)
      `uvm_error("HOST_CONTEXT_SNAPSHOT",
                 "caller DMA context mutation changed saved authority")
    request_context.copy(context_snapshot);

    status = mem_api.write(mapping, 8, write_data);
    expect_status("HOST_WRITE", status, RDMA_SC_OK);
    write_data[0] = 8'hff;
    if (mem.calls.size() != 2 || mem.calls[1].call_sequence != 2 ||
        mem.calls[1].method_name != "write" ||
        mem.calls[1].mapping == mapping || mem.calls[1].offset != 8 ||
        mem.calls[1].data.size() != 4 || mem.calls[1].data[0] != 8'h11)
      `uvm_error("HOST_WRITE_RECORD", "write history aliases caller data")

    status = mem_api.read(mapping, 8, 4, read_data);
    expect_status("HOST_READ", status, RDMA_SC_OK);
    if (read_data.size() != 4 || read_data[0] != 8'h11 ||
        read_data[3] != 8'h44 || mem.calls[2].call_sequence != 3 ||
        mem.calls[2].method_name != "read")
      `uvm_error("HOST_READ", "host read did not preserve payload/order")

    status = mem_api.write(mapping, 4095, overflow_data);
    expect_status("HOST_BOUNDS", status, RDMA_SC_DMA_TRANSLATION);
    status = mem_api.\release (mapping);
    expect_status("HOST_RELEASE", status, RDMA_SC_OK);
    status = mem_api.read(mapping, 0, 1, read_data);
    expect_status("HOST_RELEASED_READ", status, RDMA_SC_INVALID_STATE);

    injected = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED, "one shot");
    status = mem.fail_next("allocate", injected);
    expect_status("HOST_FAIL_VALID", status, RDMA_SC_OK);
    injected.message = "caller mutation";
    status = mem_api.allocate(request_context, 64, 64,
                              RDMA_DMA_DEVICE_READ,
                              failed_mapping);
    expect_status("HOST_INJECTED", status, RDMA_SC_RESOURCE_EXHAUSTED);
    if (status.message != "one shot" || failed_mapping != null)
      `uvm_error("HOST_INJECTED", "injected failure was not copied")
    status = mem_api.allocate(request_context, 64, 64,
                              RDMA_DMA_DEVICE_READ,
                              second_mapping);
    expect_status("HOST_ONE_SHOT", status, RDMA_SC_OK);

    authoritative_mem = rdma_mock_host_mem::type_id::create(
      "authoritative_mem"
    );
    authoritative_mem_api = authoritative_mem;
    status = authoritative_mem_api.allocate(
      request_context, 64, 64, RDMA_DMA_BIDIRECTIONAL,
      authoritative_mapping
    );
    expect_status("HOST_AUTH_ALLOCATE", status, RDMA_SC_OK);
    cloned_object = authoritative_mapping.clone();
    if (cloned_object == null ||
        !$cast(stale_active_mapping, cloned_object))
      `uvm_fatal("HOST_AUTH_CLONE", "mapping clone type mismatch")

    authoritative_mapping.size = 128;
    status = authoritative_mem_api.write(authoritative_mapping, 63,
                                         crossing_data);
    expect_status("HOST_AUTH_WRITE_BOUNDS", status, RDMA_SC_DMA_TRANSLATION);
    status = authoritative_mem_api.read(authoritative_mapping, 63, 2,
                                        read_data);
    expect_status("HOST_AUTH_READ_BOUNDS", status, RDMA_SC_DMA_TRANSLATION);
    if (authoritative_mem.regions.size() != 1 ||
        authoritative_mem.regions[0].data.size() != 64 ||
        authoritative_mem.regions[0].data[63] != 0 || read_data.size() != 0)
      `uvm_error("HOST_AUTH_BOUNDS",
                 "caller size mutation reached authoritative storage")

    status = authoritative_mem_api.\release (authoritative_mapping);
    expect_status("HOST_AUTH_RELEASE", status, RDMA_SC_OK);
    status = authoritative_mem_api.read(stale_active_mapping, 0, 1,
                                        read_data);
    expect_status("HOST_AUTH_STALE_READ", status, RDMA_SC_INVALID_STATE);
    status = authoritative_mem_api.write(stale_active_mapping, 0,
                                         crossing_data);
    expect_status("HOST_AUTH_STALE_WRITE", status, RDMA_SC_INVALID_STATE);
    status = authoritative_mem_api.\release (stale_active_mapping);
    expect_status("HOST_AUTH_STALE_RELEASE", status, RDMA_SC_INVALID_STATE);
    status = authoritative_mem_api.\release (authoritative_mapping);
    expect_status("HOST_AUTH_REPEAT_RELEASE", status, RDMA_SC_INVALID_STATE);
    if (authoritative_mem.calls.size() != 8)
      `uvm_error("HOST_AUTH_ORDER", "authoritative call history is incomplete")
    foreach (authoritative_mem.calls[i]) begin
      if (authoritative_mem.calls[i].call_sequence != i + 1)
        `uvm_error("HOST_AUTH_ORDER",
                   "authoritative call sequence is not monotonic")
    end

    overflow_mem = rdma_mock_host_mem::type_id::create("overflow_mem");
    overflow_mem_api = overflow_mem;
    overflow_mem.next_address = 64'hffff_ffff_ffff_fff8;
    next_address_before = overflow_mem.next_address;
    region_count_before = overflow_mem.regions.size();
    status = overflow_mem_api.allocate(
      request_context, 16, 16, RDMA_DMA_BIDIRECTIONAL, overflow_mapping
    );
    expect_status("HOST_ALIGN_OVERFLOW", status,
                  RDMA_SC_RESOURCE_EXHAUSTED);
    if (overflow_mapping != null ||
        overflow_mem.regions.size() != region_count_before ||
        overflow_mem.next_address != next_address_before)
      `uvm_error("HOST_ALIGN_OVERFLOW",
                 "alignment overflow mutated allocator state")

    overflow_mem.next_address = 64'hffff_ffff_ffff_ffc0;
    next_address_before = overflow_mem.next_address;
    region_count_before = overflow_mem.regions.size();
    status = overflow_mem_api.allocate(
      request_context, 128, 64, RDMA_DMA_BIDIRECTIONAL, overflow_mapping
    );
    expect_status("HOST_END_OVERFLOW", status,
                  RDMA_SC_RESOURCE_EXHAUSTED);
    if (overflow_mapping != null ||
        overflow_mem.regions.size() != region_count_before ||
        overflow_mem.next_address != next_address_before)
      `uvm_error("HOST_END_OVERFLOW",
                 "allocation end overflow mutated allocator state")

    identity_mem = rdma_mock_host_mem::type_id::create("identity_mem");
    identity_mem_api = identity_mem;
    status = identity_mem_api.allocate(
      request_context, 64, 64, RDMA_DMA_BIDIRECTIONAL, identity_mapping_a
    );
    expect_status("HOST_IDENTITY_ALLOC_A", status, RDMA_SC_OK);
    if (!$cast(identity_mock_mapping, identity_mapping_a))
      `uvm_fatal("HOST_IDENTITY_TYPE",
                 "allocated mapping does not carry mock identity")
    status = identity_mock_mapping.initialize_allocation_token(null);
    expect_status("HOST_IDENTITY_REINITIALIZE", status,
                  RDMA_SC_INVALID_STATE);
    status = identity_mem_api.allocate(
      request_context, 64, 64, RDMA_DMA_BIDIRECTIONAL, identity_mapping_b
    );
    expect_status("HOST_IDENTITY_ALLOC_B", status, RDMA_SC_OK);
    if (!$cast(identity_mock_mapping_b, identity_mapping_b))
      `uvm_fatal("HOST_IDENTITY_TYPE",
                 "second allocated mapping does not carry mock identity")
    third_mock_mapping = rdma_mock_dma_mapping::type_id::create(
      "third_mock_mapping"
    );
    third_mock_release_seal = new("third_mock_release_seal");
    status = third_mock_mapping.initialize_allocation_token(
      third_mock_release_seal
    );
    expect_status("HOST_IDENTITY_THIRD_INIT", status, RDMA_SC_OK);
    if (identity_mock_mapping.same_allocation(identity_mock_mapping_b) ||
        third_mock_mapping.same_allocation(identity_mock_mapping) ||
        third_mock_mapping.same_allocation(identity_mock_mapping_b))
      `uvm_error("HOST_IDENTITY_UNIQUE",
                 "independent mappings share allocation identity")
    cloned_object = identity_mapping_a.clone();
    if (cloned_object == null ||
        !$cast(identity_mapping_a_snapshot, cloned_object))
      `uvm_fatal("HOST_IDENTITY_CLONE", "mapping clone type mismatch")
    if (!$cast(identity_mock_mapping_snapshot, identity_mapping_a_snapshot) ||
        !identity_mock_mapping.same_allocation(
          identity_mock_mapping_snapshot
        ))
      `uvm_error("HOST_IDENTITY_CLONE",
                 "mapping clone did not preserve allocation identity")
    status = identity_mem_api.write(identity_mapping_b, 0, identity_b_data);
    expect_status("HOST_IDENTITY_SEED_B", status, RDMA_SC_OK);

    identity_mapping_a.copy(identity_mapping_b);
    if (!identity_mock_mapping.same_allocation(
          identity_mock_mapping_snapshot
        ) || identity_mock_mapping.same_allocation(identity_mock_mapping_b))
      `uvm_error("HOST_IDENTITY_COPY",
                 "copy operation replaced allocation identity")
    status = identity_mem_api.write(identity_mapping_a, 0, identity_a_data);
    expect_status("HOST_IDENTITY_WRITE_A", status, RDMA_SC_OK);
    status = identity_mem_api.read(identity_mapping_b, 0, 2,
                                   identity_read_data);
    expect_status("HOST_IDENTITY_READ_B", status, RDMA_SC_OK);
    if (identity_read_data.size() != 2 ||
        identity_read_data[0] != identity_b_data[0] ||
        identity_read_data[1] != identity_b_data[1])
      `uvm_error("HOST_IDENTITY_REDIRECT",
                 "mutated mapping A redirected write into allocation B")
    status = identity_mem_api.read(identity_mapping_a_snapshot, 0, 2,
                                   identity_read_data);
    expect_status("HOST_IDENTITY_READ_A", status, RDMA_SC_OK);
    if (identity_read_data.size() != 2 ||
        identity_read_data[0] != identity_a_data[0] ||
        identity_read_data[1] != identity_a_data[1])
      `uvm_error("HOST_IDENTITY_TARGET",
                 "mutated mapping A did not retain allocation identity")

    status = identity_mem_api.\release (identity_mapping_a);
    expect_status("HOST_IDENTITY_RELEASE_A", status, RDMA_SC_OK);
    status = identity_mem_api.read(identity_mapping_b, 0, 2,
                                   identity_read_data);
    expect_status("HOST_IDENTITY_B_ACTIVE", status, RDMA_SC_OK);
    if (identity_read_data.size() != 2 ||
        identity_read_data[0] != identity_b_data[0] ||
        identity_read_data[1] != identity_b_data[1])
      `uvm_error("HOST_IDENTITY_RELEASE_REDIRECT",
                 "releasing mapping A changed allocation B")
    status = identity_mem_api.read(identity_mapping_a_snapshot, 0, 1,
                                   identity_read_data);
    expect_status("HOST_IDENTITY_A_RELEASED", status,
                  RDMA_SC_INVALID_STATE);

    forged_mapping = rdma_dma_mapping::type_id::create("forged_mapping");
    forged_mapping.function_h = rdma_mock_clone_function_handle(function_h);
    forged_mapping.backing_addr = identity_mapping_b.backing_addr;
    forged_mapping.iova = identity_mapping_b.iova;
    forged_mapping.size = identity_mapping_b.size;
    forged_mapping.state = RDMA_MAPPING_ACTIVE;
    status = identity_mem_api.read(forged_mapping, 0, 1,
                                   identity_read_data);
    expect_status("HOST_FORGED_READ", status, RDMA_SC_DMA_TRANSLATION);
    status = identity_mem_api.write(forged_mapping, 0, identity_a_data);
    expect_status("HOST_FORGED_WRITE", status, RDMA_SC_DMA_TRANSLATION);
    status = identity_mem_api.\release (forged_mapping);
    expect_status("HOST_FORGED_RELEASE", status, RDMA_SC_DMA_TRANSLATION);

    pcie = rdma_mock_pcie::type_id::create("pcie");
    pcie_api = pcie;
    status = pcie.fail_next(
      "cfg_read", rdma_status::make(RDMA_SC_TIMEOUT, "typo")
    );
    expect_status("PCIE_FAIL_KEY", status, RDMA_SC_INVALID_ARGUMENT);
    status = pcie.fail_next("cfg_read32", null);
    expect_status("PCIE_FAIL_NULL", status, RDMA_SC_INVALID_ARGUMENT);
    if (pcie.failures.exists("cfg_read") ||
        pcie.failures.exists("cfg_read32"))
      `uvm_error("PCIE_FAIL_CONFIG",
                 "invalid PCIe failure configuration was retained")
    pcie.cfg_read_value = 32'hdead_beef;
    pcie_api.cfg_read32(bdf, cfg_offset, cfg_data, status);
    expect_status("PCIE_CFG_READ", status, RDMA_SC_OK);
    if (cfg_data != 32'hdead_beef)
      `uvm_error("PCIE_CFG_READ", "configured read value was not returned")
    pcie_api.cfg_write32(bdf, cfg_offset, 32'h1234_5678, 4'b1010,
                         status);
    expect_status("PCIE_CFG_WRITE", status, RDMA_SC_OK);
    pcie_api.mmio_write(function_h, bar_address, overflow_data, status);
    expect_status("PCIE_MMIO", status, RDMA_SC_OK);
    overflow_data[0] = 8'h00;
    pcie_api.dma_visibility_barrier(function_h, status);
    expect_status("PCIE_DMA_BARRIER", status, RDMA_SC_OK);
    pcie_api.mmio_ordering_barrier(function_h, status);
    expect_status("PCIE_MMIO_BARRIER", status, RDMA_SC_OK);

    info = rdma_pcie_function_info::type_id::create("info");
    info.bdf = bdf;
    info.vf_index = 32'd9;
    pcie.function_info_response = info;
    status = pcie_api.get_function_info(bdf, info_result);
    expect_status("PCIE_INFO", status, RDMA_SC_OK);
    if (info_result == null || info_result == info ||
        info_result.vf_index != 9)
      `uvm_error("PCIE_INFO", "function info response was not copied")

    decode = rdma_bar_decode::type_id::create("decode");
    decode.target_bdf = bdf;
    decode.bar_id = 3'd2;
    decode.bar_offset = 64'h40;
    pcie.decode_response = decode;
    status = pcie_api.decode_bar(bar_address, decode_result);
    expect_status("PCIE_DECODE", status, RDMA_SC_OK);
    if (decode_result == null || decode_result == decode ||
        decode_result.bar_offset != 64'h40)
      `uvm_error("PCIE_DECODE", "BAR decode response was not copied")

    function_h.generation = 32'd99;
    if (pcie.calls.size() != 7 || pcie.calls[0].call_sequence != 1 ||
        pcie.calls[1].call_sequence != 2 ||
        pcie.calls[2].call_sequence != 3 ||
        pcie.calls[2].method_name != "mmio_write" ||
        pcie.calls[2].function_h == function_h ||
        pcie.calls[2].function_h.generation != 17 ||
        pcie.calls[2].address != bar_address ||
        pcie.calls[2].data.size() != 2 || pcie.calls[2].data[0] != 8'haa ||
        pcie.calls[6].method_name != "decode_bar")
      `uvm_error("PCIE_RECORD", "PCIe call order/data were not preserved")
    function_h.generation = 32'd17;
    status = pcie.fail_next(
      "cfg_read32", rdma_status::make(RDMA_SC_PCIE_COMPLETION, "one shot")
    );
    expect_status("PCIE_FAIL_VALID", status, RDMA_SC_OK);
    pcie_api.cfg_read32(bdf, cfg_offset, cfg_data, status);
    expect_status("PCIE_INJECTED", status, RDMA_SC_PCIE_COMPLETION);
    pcie_api.cfg_read32(bdf, cfg_offset, cfg_data, status);
    expect_status("PCIE_ONE_SHOT", status, RDMA_SC_OK);

    table = rdma_mock_function_table::type_id::create("table");
    table_api = table;
    status = table.fail_next(
      "program", rdma_status::make(RDMA_SC_TIMEOUT, "typo")
    );
    expect_status("TABLE_FAIL_KEY", status, RDMA_SC_INVALID_ARGUMENT);
    status = table.fail_next("program_notify", null);
    expect_status("TABLE_FAIL_NULL", status, RDMA_SC_INVALID_ARGUMENT);
    if (table.failures.exists("program") ||
        table.failures.exists("program_notify"))
      `uvm_error("TABLE_FAIL_CONFIG",
                 "invalid table failure configuration was retained")
    binding = make_binding("binding");
    table_api.program_notify(binding, status);
    expect_status("TABLE_PROGRAM_NOTIFY", status, RDMA_SC_OK);
    table_api.clear_notify(binding, status);
    expect_status("TABLE_CLEAR_NOTIFY", status, RDMA_SC_OK);
    table_api.program_dmi(binding, status);
    expect_status("TABLE_PROGRAM_DMI", status, RDMA_SC_OK);
    table_api.clear_dmi(binding, status);
    expect_status("TABLE_CLEAR_DMI", status, RDMA_SC_OK);
    table_api.program_vft(binding, status);
    expect_status("TABLE_PROGRAM_VFT", status, RDMA_SC_OK);
    table_api.clear_vft(binding, status);
    expect_status("TABLE_CLEAR_VFT", status, RDMA_SC_OK);
    binding.generation = 32'd33;
    if (table.calls.size() != 6 || table.calls[0].call_sequence != 1 ||
        table.calls[5].call_sequence != 6 ||
        table.calls[0].method_name != "program_notify" ||
        table.calls[5].method_name != "clear_vft" ||
        table.calls[0].binding == binding ||
        table.calls[0].binding.generation != 17)
      `uvm_error("TABLE_RECORD", "table call order/value was not preserved")
    binding.generation = 32'd17;
    status = table.fail_next(
      "program_notify", rdma_status::make(RDMA_SC_INVALID_STATE, "one shot")
    );
    expect_status("TABLE_FAIL_VALID", status, RDMA_SC_OK);
    table_api.program_notify(binding, status);
    expect_status("TABLE_INJECTED", status, RDMA_SC_INVALID_STATE);
    table_api.program_notify(binding, status);
    expect_status("TABLE_ONE_SHOT", status, RDMA_SC_OK);

    net = rdma_mock_net::type_id::create("net");
    net_api = net;
    status = net.fail_next(
      "register_observer", rdma_status::make(RDMA_SC_TIMEOUT, "void method")
    );
    expect_status("NET_FAIL_KEY", status, RDMA_SC_INVALID_ARGUMENT);
    status = net.fail_next("send_packet", null);
    expect_status("NET_FAIL_NULL", status, RDMA_SC_INVALID_ARGUMENT);
    if (net.failures.exists("register_observer") ||
        net.failures.exists("send_packet"))
      `uvm_error("NET_FAIL_CONFIG",
                 "invalid network failure configuration was retained")
    observer = rdma_adapter_test_observer::type_id::create("observer");
    observer_seed = make_packet("observer_seed", 8'h21);
    observer.write(observer_seed);
    net_api.register_observer(observer);
    if (!net.calls[0].observer_present ||
        net.calls[0].observer_type_name != observer.get_type_name() ||
        net.calls[0].observer_instance_name != observer.get_name())
      `uvm_error("NET_OBSERVER_METADATA",
                 "observer registration metadata was not recorded")
    tx_packet = make_packet("tx_packet", 8'h31);
    net_api.send_packet(tx_packet, status);
    expect_status("NET_SEND", status, RDMA_SC_OK);
    tx_packet.payload[0] = 8'hff;
    if (observer.notification_count != 2 || observer.last_packet == null ||
        observer.last_packet.payload[0] != 8'h31)
      `uvm_error("NET_OBSERVER", "observer was not notified by value")
    if (!net.calls[0].observer_present ||
        net.calls[0].observer_type_name != "rdma_adapter_test_observer" ||
        net.calls[0].observer_instance_name != "observer")
      `uvm_error("NET_OBSERVER_METADATA",
                 "observer changes altered registration metadata")

    rx_source = make_packet("rx_source", 8'h51);
    net.enqueue_receive(rx_source);
    rx_source.payload[0] = 8'h00;
    net_api.receive_packet(rx_packet, status);
    expect_status("NET_RECEIVE", status, RDMA_SC_OK);
    if (rx_packet == null || rx_packet.payload[0] != 8'h51)
      `uvm_error("NET_RECEIVE", "receive queue aliases its source")

    policy = rdma_net_response_policy::type_id::create("policy");
    policy.responder_mode = RDMA_RESPONDER_VIP;
    policy.drop_every_n = 7;
    status = net_api.configure_response_policy(policy);
    expect_status("NET_POLICY", status, RDMA_SC_OK);
    fault = rdma_net_fault::type_id::create("fault");
    fault.kind = RDMA_FAULT_PACKET_DROP;
    fault.drop_packet = 1'b1;
    status = net_api.inject_fault(fault);
    expect_status("NET_FAULT", status, RDMA_SC_OK);
    policy.drop_every_n = 99;
    fault.drop_packet = 1'b0;
    if (net.calls.size() != 5 || net.calls[0].call_sequence != 1 ||
        net.calls[4].call_sequence != 5 ||
        net.calls[0].method_name != "register_observer" ||
        net.calls[1].method_name != "send_packet" ||
        net.calls[1].packet == tx_packet ||
        net.calls[1].packet.payload[0] != 8'h31 ||
        net.calls[3].policy == policy || net.calls[3].policy.drop_every_n != 7 ||
        net.calls[4].fault == fault || !net.calls[4].fault.drop_packet)
      `uvm_error("NET_RECORD", "network call order/value was not preserved")

    status = net.fail_next(
      "send_packet", rdma_status::make(RDMA_SC_TIMEOUT, "one shot")
    );
    expect_status("NET_FAIL_VALID", status, RDMA_SC_OK);
    net_api.send_packet(tx_packet, status);
    expect_status("NET_INJECTED", status, RDMA_SC_TIMEOUT);
    net_api.send_packet(tx_packet, status);
    expect_status("NET_ONE_SHOT", status, RDMA_SC_OK);
    if (observer.notification_count != 3)
      `uvm_error("NET_OBSERVER", "failed send notified observer")

    if (mem.calls.size() != 8 ||
        mem.calls[3].method_name != "write" ||
        mem.calls[4].method_name != "release" ||
        mem.calls[5].method_name != "read" ||
        mem.calls[6].method_name != "allocate" ||
        mem.calls[7].method_name != "allocate")
      `uvm_error("HOST_ORDER", "host call history is incomplete")
    foreach (mem.calls[i]) begin
      if (mem.calls[i].call_sequence != i + 1)
        `uvm_error("HOST_ORDER", "host call sequence is not monotonic")
    end

    if (pcie.calls.size() != 9 ||
        pcie.calls[0].target != bdf ||
        pcie.calls[0].offset != cfg_offset ||
        pcie.calls[1].cfg_data != 32'h1234_5678 ||
        pcie.calls[1].byte_enable != 4'b1010 ||
        pcie.calls[3].method_name != "dma_visibility_barrier" ||
        pcie.calls[4].method_name != "mmio_ordering_barrier" ||
        pcie.calls[5].method_name != "get_function_info" ||
        pcie.calls[7].method_name != "cfg_read32" ||
        pcie.calls[8].method_name != "cfg_read32")
      `uvm_error("PCIE_ORDER", "PCIe call history is incomplete")
    foreach (pcie.calls[i]) begin
      if (pcie.calls[i].call_sequence != i + 1)
        `uvm_error("PCIE_ORDER", "PCIe call sequence is not monotonic")
    end

    if (table.calls.size() != 8 ||
        table.calls[1].method_name != "clear_notify" ||
        table.calls[2].method_name != "program_dmi" ||
        table.calls[3].method_name != "clear_dmi" ||
        table.calls[4].method_name != "program_vft" ||
        table.calls[6].method_name != "program_notify" ||
        table.calls[7].method_name != "program_notify")
      `uvm_error("TABLE_ORDER", "table call history is incomplete")
    foreach (table.calls[i]) begin
      if (table.calls[i].call_sequence != i + 1)
        `uvm_error("TABLE_ORDER", "table call sequence is not monotonic")
    end

    if (net.calls.size() != 7 || net.calls[2].packet == null ||
        net.calls[2].packet.payload[0] != 8'h51 ||
        net.calls[5].method_name != "send_packet" ||
        net.calls[6].method_name != "send_packet")
      `uvm_error("NET_ORDER", "network call history is incomplete")
    foreach (net.calls[i]) begin
      if (net.calls[i].call_sequence != i + 1)
        `uvm_error("NET_ORDER", "network call sequence is not monotonic")
    end

    phase.drop_objection(this);
  endtask
endclass
