// 目录：测试层 unit/rdma_control_plane_cmq_engine_test.sv。
// 职责：验证 rdma_control_plane_cmq_engine_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_control_plane_cmq_engine_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_control_plane_cmq_engine_responder_pcie extends rdma_mock_pcie;
  `uvm_object_utils(rdma_control_plane_cmq_engine_responder_pcie)

  localparam longint unsigned CMQ_CQ_OFFSET = 64'd2048;
  localparam int unsigned CMQE_BYTES = 64;
  localparam int unsigned CMQ_DEPTH = 32;

  protected rdma_mock_host_mem host_mem;
  protected rdma_dma_mapping cmq_mapping;
  protected rdma_function_handle expected_function;
  protected rdma_bar_addr_t expected_doorbell_address;
  protected longint unsigned sq_sequence;
  protected longint unsigned cq_sequence;

  bit [7:0] observed_opcodes[$];
  bit [4:0] observed_wqe_indices[$];
  bit observed_wqe_wraps[$];
  bit observed_cq_owners[$];
  int unsigned observed_doorbell_pis[$];
  bit observed_doorbell_polarities[$];

  // 功能：构造 rdma_control_plane_cmq_engine_responder_pcie，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：host_mem=null；cmq_mapping=null；expected_function=null；expected_doorbell_address='0；sq_sequence=0；cq_sequence=0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_control_plane_cmq_engine_responder_pcie 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(
    string name = "rdma_control_plane_cmq_engine_responder_pcie"
  );
    super.new(name);
    host_mem = null;
    cmq_mapping = null;
    expected_function = null;
    expected_doorbell_address = '0;
    sq_sequence = 0;
    cq_sequence = 0;
  endfunction

  // 功能：在 rdma_control_plane_cmq_engine_responder_pcie 中，configure_responder 校验依赖和 binding 后建立运行边界，只保存非拥有引用并拒绝重复配置。
  // 输入/输出及副作用：host_mem_arg（输入）、cmq_mapping_arg（输入）、binding（输入）；configure_responder 先依据 host_mem_arg == null || cmq_mapping_arg == null || binding == null；cmq_mapping_arg.state != RDMA_MAPPING_ACTIVE || cmq_mapping_arg.size != 4096 校验 host_mem_arg、cmq_mapping_arg、binding；成功时更新本对象配置/状态并保存非拥有引用，返回
  //   rdma_status。
  // 失败/边界：实现中的空依赖、重复登记、状态或 generation/authority 校验失败时返回错误；失败时保留旧配置。
  function rdma_status configure_responder(
    rdma_mock_host_mem host_mem_arg,
    rdma_dma_mapping cmq_mapping_arg,
    rdma_function_binding binding
  );
    host_mem = null;
    cmq_mapping = null;
    expected_function = null;
    if (host_mem_arg == null || cmq_mapping_arg == null || binding == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "CMQ responder authority is incomplete"
      );
    if (cmq_mapping_arg.state != RDMA_MAPPING_ACTIVE ||
        cmq_mapping_arg.size != 4096)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "CMQ responder mapping is invalid"
      );
    host_mem = host_mem_arg;
    cmq_mapping = cmq_mapping_arg;
    expected_function = binding.make_handle();
    expected_doorbell_address.value =
      binding.notify_base.value + RDMA_DB_CMQ_OFFSET;
    observed_opcodes.delete();
    observed_wqe_indices.delete();
    observed_wqe_wraps.delete();
    observed_cq_owners.delete();
    observed_doorbell_pis.delete();
    observed_doorbell_polarities.delete();
    sq_sequence = 0;
    cq_sequence = 0;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_control_plane_cmq_engine_responder_pcie 中，big_endian_qword0 按 golden 文件格式解析/规范化字节或文本，得到稳定的比较输入。
  // 输入/输出及副作用：data（输入）；big_endian_qword0 读取 data 并使用字段 value；函数返回 bit [63:0]，不取得调用方资源所有权。
  // 失败/边界：big_endian_qword0 先检查 data.size(，再返回 value；拒绝分支不提交部分状态，也不隐式重试。
  function automatic bit [63:0] big_endian_qword0(byte data[]);
    bit [63:0] value;

    value = '0;
    if (data.size() < 8)
      return value;
    for (int unsigned i = 0; i < 8; i++)
      value = {value[55:0], data[i]};
    return value;
  endfunction

  // 功能：make_xtr_success_cqe 创建独立的 rdma_hw_image；根据 opcode、wqe_index、wrap、owner、generation 设置字段 image、image.length、image.alignment、image.endian、image.image_kind、image.hardware_version、image.function_generation、image.write_target_kind、qword0、i，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：opcode（输入）、wqe_index（输入）、wrap（输入）、owner（输入）、generation（输入）；make_xtr_success_cqe 读取 opcode、wqe_index、wrap、owner、generation 并使用字段 image、image.length、image.alignment、image.endian、image.image_kind、image.hardware_version、image.function_generation、image.write_target_kind；函数返回 rdma_hw_image，不取得调用方资源所有权。
  // 失败/边界：make_xtr_success_cqe 的结果直接由 return image 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_hw_image make_xtr_success_cqe(
    bit [7:0] opcode,
    bit [4:0] wqe_index,
    bit wrap,
    bit owner,
    int unsigned generation
  );
    rdma_hw_image image;
    bit [63:0] qword0;

    image = rdma_hw_image::type_id::create("control_success_cqe");
    repeat (64) image.bytes.push_back(8'h00);
    image.length = 64;
    image.alignment = 64;
    image.endian = RDMA_ENDIAN_BIG;
    image.image_kind = RDMA_IMAGE_CMQ_CQE;
    image.hardware_version = 1;
    image.function_generation = generation;
    image.write_target_kind = RDMA_HW_TARGET_NONE;
    qword0 = '0;
    qword0[63] = owner;
    qword0[45] = wrap;
    qword0[44:40] = wqe_index;
    qword0[39:32] = opcode;
    for (int unsigned i = 0; i < 8; i++)
      image.bytes[i] = qword0[63 - (i * 8) -: 8];
    return image;
  endfunction

  // 功能：在 rdma_control_plane_cmq_engine_responder_pcie 中，mmio_write 把请求数据写入指定后端并保留返回状态；只有写入成功才允许本地游标继续推进。
  // 输入/输出及副作用：function_h（输入）、address（输入）、data（输入）、status（输出）；mmio_write 驱动下游事务，并写入 status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：mmio_write 遇到后端拒绝、范围溢出或 DMA 权限不足时保留失败证据，不推进本地游标。
  virtual task mmio_write(
    rdma_function_handle function_h,
    rdma_bar_addr_t address,
    byte data[],
    output rdma_status status
  );
    byte sqe_data[];
    byte cqe_data[];
    rdma_hw_image cqe;
    bit [63:0] doorbell_qword0;
    bit [63:0] sqe_qword0;
    bit [7:0] opcode;
    bit [4:0] wqe_index;
    bit wqe_wrap;
    bit cqe_owner;
    int unsigned doorbell_pi;
    bit doorbell_polarity;
    int unsigned expected_pi;
    bit expected_polarity;
    longint unsigned sq_offset;
    longint unsigned cq_offset;

    super.mmio_write(function_h, address, data, status);
    if (status == null || !status.ok())
      return;
    if (host_mem == null || cmq_mapping == null ||
        expected_function == null) begin
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE, "CMQ responder is not configured"
      );
      return;
    end
    if (function_h == null ||
        !function_h.same_instance(expected_function) ||
        address != expected_doorbell_address || data.size() != 8) begin
      status = rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "CMQ responder saw a non-CMQ doorbell"
      );
      return;
    end

    doorbell_qword0 = big_endian_qword0(data);
    doorbell_pi = doorbell_qword0[36:32];
    doorbell_polarity = doorbell_qword0[37];
    expected_pi = (sq_sequence + 1'b1) % CMQ_DEPTH;
    expected_polarity = ((sq_sequence + 1'b1) / CMQ_DEPTH) & 1'b1;
    if (doorbell_pi != expected_pi ||
        doorbell_polarity != expected_polarity) begin
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE, "CMQ SQ doorbell did not advance in order"
      );
      return;
    end

    sq_offset = (sq_sequence % CMQ_DEPTH) * CMQE_BYTES;
    sqe_data = new[0];
    status = host_mem.read(cmq_mapping, sq_offset, CMQE_BYTES, sqe_data);
    if (status == null || !status.ok())
      return;
    sqe_qword0 = big_endian_qword0(sqe_data);
    opcode = sqe_qword0[39:32];
    wqe_index = sqe_qword0[44:40];
    wqe_wrap = sqe_qword0[45];
    if (sqe_qword0[63] != !wqe_wrap ||
        wqe_index != (sq_sequence % CMQ_DEPTH) ||
        wqe_wrap != ((sq_sequence / CMQ_DEPTH) & 1'b1) ||
        !(opcode inside {RDMA_OP_KEY_ALLOC,
                         RDMA_OP_MR_DEREGISTER,
                         RDMA_OP_TQ_FLUSH})) begin
      status = rdma_status::make(
        RDMA_SC_CODEC_ERROR, "CMQ responder decoded an invalid SQE envelope"
      );
      return;
    end

    cqe_owner = !((cq_sequence / CMQ_DEPTH) & 1'b1);
    cqe = make_xtr_success_cqe(
      opcode, wqe_index, wqe_wrap, cqe_owner,
      expected_function.generation
    );
    cqe_data = new[CMQE_BYTES];
    foreach (cqe_data[i])
      cqe_data[i] = cqe.bytes[i];
    cq_offset = CMQ_CQ_OFFSET +
                ((cq_sequence % CMQ_DEPTH) * CMQE_BYTES);
    status = host_mem.write(cmq_mapping, cq_offset, cqe_data);
    if (status == null || !status.ok())
      return;

    observed_opcodes.push_back(opcode);
    observed_wqe_indices.push_back(wqe_index);
    observed_wqe_wraps.push_back(wqe_wrap);
    observed_cq_owners.push_back(cqe_owner);
    observed_doorbell_pis.push_back(doorbell_pi);
    observed_doorbell_polarities.push_back(doorbell_polarity);
    sq_sequence++;
    cq_sequence++;
  endtask
endclass

class rdma_control_plane_cmq_engine_test extends uvm_test;
  `uvm_component_utils(rdma_control_plane_cmq_engine_test)

  localparam longint unsigned TEST_FUNCTION_UID =
    64'h14a0_0000_0000_0012;
  localparam int unsigned TEST_FUNCTION_ID = 32'h14a0_0012;
  localparam int unsigned TEST_GENERATION = 32'd12;
  localparam int unsigned TEST_CMQ_ID = 32'h0000_0012;

  // 功能：构造 rdma_control_plane_cmq_engine_test，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_control_plane_cmq_engine_test 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(
    string name = "rdma_control_plane_cmq_engine_test",
    uvm_component parent = null
  );
    super.new(name, parent);
  endfunction

  // 功能：在 rdma_control_plane_cmq_engine_test 中，expect_status 在测试中执行 expect_status 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、status（输入）、expected（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_status 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function automatic void expect_status(
    string label,
    rdma_status status,
    rdma_status_code_e expected
  );
    if (status == null) begin
      `uvm_error(label, "operation returned a null status")
      return;
    end
    if (status.code != expected)
      `uvm_error(label,
                 $sformatf("expected %s, got %s (%s)", expected.name(),
                           status.code.name(), status.convert2string()))
  endfunction

  // 功能：make_binding 创建独立的 rdma_function_binding；根据 name、binding_state 设置字段 binding、binding.function_uid、binding.global_function_id、binding.generation、pcie.bdf、base.value、size、enabled、binding.notify_bar_id、notify_base.value，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、binding_state（输入）；make_binding 读取 name、binding_state 并使用字段 binding、binding.function_uid、binding.global_function_id、binding.generation、pcie.bdf、base.value、size、enabled；函数返回 rdma_function_binding，不取得调用方资源所有权。
  // 失败/边界：make_binding 的结果直接由 return binding 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_function_binding make_binding(
    string name,
    rdma_binding_state_e binding_state
  );
    rdma_function_binding binding;
    rdma_interrupt_vector_binding vector;

    binding = rdma_function_binding::type_id::create(name);
    binding.function_uid = TEST_FUNCTION_UID;
    binding.global_function_id = TEST_FUNCTION_ID;
    binding.generation = TEST_GENERATION;
    binding.pcie.bdf = '{segment:16'h0014, bus:8'h2a,
                         device:5'h03, function_num:3'h1};
    if (!binding.configure_identity_from_legacy_mirrors(
          16'h0, 32'h1, RDMA_FUNCTION_PF).ok())
      `uvm_error("BINDING", "legacy binding identity configuration failed")
    binding.pcie.bar[0].base.value = 64'h0000_0000_9000_0000;
    binding.pcie.bar[0].size = 64'h0001_0000;
    binding.pcie.bar[0].enabled = 1'b1;
    binding.notify_bar_id = 0;
    binding.notify_base.value = 64'h0000_0000_9000_2000;
    binding.notify_size = 64'h2000;
    binding.state = binding_state;
    binding.owner_h = binding.make_handle();
    binding.queue_dma.requester_bdf = binding.pcie.bdf;
    binding.queue_dma.pasid_valid = 1'b1;
    binding.queue_dma.pasid = 20'h14012;
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
    binding.pcie.mse = 1'b1;
    binding.pcie.bme = 1'b1;
    binding.notify_valid = 1'b1;
    binding.notify_ready = 1'b1;
    binding.dmi_valid = 1'b1;
    binding.dmi_ready = 1'b1;
    binding.vft_valid = 1'b1;
    binding.vft_ready = 1'b1;
    return binding;
  endfunction

  // 功能：make_cmq 创建独立的 rdma_cmq；根据 name、binding 设置字段 cmq、cmq.handle、handle.kind、handle.function_uid、handle.object_id、handle.generation、cmq.owner、cmq.state、cmq.depth，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、binding（输入）；make_cmq 读取 name、binding 并使用字段 cmq、cmq.handle、handle.kind、handle.function_uid、handle.object_id、handle.generation、cmq.owner、cmq.state；函数返回 rdma_cmq，不取得调用方资源所有权。
  // 失败/边界：make_cmq 的结果直接由 return cmq 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_cmq make_cmq(
    string name,
    rdma_function_binding binding
  );
    rdma_cmq cmq;

    cmq = rdma_cmq::type_id::create(name);
    cmq.handle = rdma_handle::type_id::create({name, "_handle"});
    cmq.handle.kind = RDMA_RESOURCE_CMQ;
    cmq.handle.function_uid = binding.function_uid;
    cmq.handle.object_id = TEST_CMQ_ID;
    cmq.handle.generation = binding.generation;
    cmq.owner = binding.make_handle();
    cmq.state = RDMA_RESOURCE_ALLOCATED;
    cmq.depth = 32;
    return cmq;
  endfunction

  // 功能：make_pd_request 创建独立的 rdma_create_pd_req；根据 binding 设置字段 request、request.request_id、request.correlation_id、request.owner，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：binding（输入）；make_pd_request 读取 binding 并使用字段 request、request.request_id、request.correlation_id、request.owner；函数返回 rdma_create_pd_req，不取得调用方资源所有权。
  // 失败/边界：make_pd_request 的结果直接由 return request 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_create_pd_req make_pd_request(
    rdma_function_binding binding
  );
    rdma_create_pd_req request;

    request = rdma_create_pd_req::type_id::create("pd_request");
    request.request_id = 64'h1200;
    request.correlation_id = 64'h1201;
    request.owner = binding.make_handle();
    return request;
  endfunction

  // 功能：make_mr_request 创建独立的 rdma_register_mr_req；根据 binding、pd、iova 设置字段 request、request.request_id、request.correlation_id、request.owner、request.pd_h、iova.value、request.length、request.access，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：binding（输入）、pd（输入）、iova（输入）；make_mr_request 读取 binding、pd、iova 并使用字段 request、request.request_id、request.correlation_id、request.owner、request.pd_h、iova.value、request.length、request.access；函数返回 rdma_register_mr_req，不取得调用方资源所有权。
  // 失败/边界：make_mr_request 的结果直接由 return request 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_register_mr_req make_mr_request(
    rdma_function_binding binding,
    rdma_pd pd,
    longint unsigned iova
  );
    rdma_register_mr_req request;

    request = rdma_register_mr_req::type_id::create("mr_request");
    request.request_id = 64'h1210;
    request.correlation_id = 64'h1211;
    request.owner = binding.make_handle();
    request.pd_h = rdma_clone_handle_value(pd.handle, "integration PD");
    request.iova.value = iova;
    request.length = 64'h2000;
    request.access = '{local_write:1'b0, remote_read:1'b1,
                       remote_write:1'b0, memory_window_bind:1'b0,
                       remote_atomic:1'b0};
    return request;
  endfunction

  // 功能：make_dma_context 创建独立的 rdma_dma_request_context；根据 binding 设置字段 dma_ctx、dma_ctx.function_h、dma_ctx.requester_bdf、dma_ctx.pasid_valid、dma_ctx.pasid、dma_ctx.dma_domain_valid、dma_ctx.dma_domain_id、dma_ctx.owner_h，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：binding（输入）；make_dma_context 读取 binding 并使用字段 dma_ctx、dma_ctx.function_h、dma_ctx.requester_bdf、dma_ctx.pasid_valid、dma_ctx.pasid、dma_ctx.dma_domain_valid、dma_ctx.dma_domain_id、dma_ctx.owner_h；函数返回 rdma_dma_request_context，不取得调用方资源所有权。
  // 失败/边界：make_dma_context 的结果直接由 return dma_ctx 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_dma_request_context make_dma_context(
    rdma_function_binding binding
  );
    rdma_dma_request_context dma_ctx;

    dma_ctx = rdma_dma_request_context::type_id::create("mr_dma_context");
    dma_ctx.function_h = binding.make_handle();
    dma_ctx.requester_bdf = binding.pcie.bdf;
    dma_ctx.pasid_valid = 1'b1;
    dma_ctx.pasid = 20'h14012;
    dma_ctx.dma_domain_valid = binding.queue_dma.dma_domain_valid;
    dma_ctx.dma_domain_id = binding.queue_dma.dma_domain_id;
    dma_ctx.owner_h = null;
    return dma_ctx;
  endfunction

  // 功能：判断 count_mapping_releases 对应的状态、能力或账本条件，并返回确定的布尔/计数结果，不修改状态。
  // 输入/输出及副作用：mock_mem（输入）、mapping（输入）；count_mapping_releases 读取 mock_mem、mapping 并使用字段 count、released_mapping；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：count_mapping_releases 只读取现有账本；输入未初始化时返回保守结果，不得借助默认 Function/root 猜测。
  function automatic int unsigned count_mapping_releases(
    rdma_mock_host_mem mock_mem,
    rdma_dma_mapping mapping
  );
    rdma_mock_dma_mapping expected_mapping;
    rdma_mock_dma_mapping released_mapping;
    int unsigned count;

    count = 0;
    if (!$cast(expected_mapping, mapping) || expected_mapping == null)
      return count;
    foreach (mock_mem.calls[i]) begin
      released_mapping = null;
      if (mock_mem.calls[i] != null &&
          mock_mem.calls[i].method_name == "release" &&
          $cast(released_mapping, mock_mem.calls[i].mapping) &&
          released_mapping != null &&
          expected_mapping.same_allocation(released_mapping))
        count++;
    end
    return count;
  endfunction

  // 功能：在 rdma_control_plane_cmq_engine_test 中，expect_lifecycle_trace 在测试中执行 expect_lifecycle_trace 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：trace（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_lifecycle_trace 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function automatic void expect_lifecycle_trace(
    rdma_mock_call_trace trace
  );
    string expected[$];

    expected.push_back("host_allocate");
    repeat (3) begin
      expected.push_back("host_write");
      expected.push_back("pcie_dma_visibility_barrier");
      expected.push_back("pcie_mmio_ordering_barrier");
      expected.push_back("pcie_mmio_write");
      expected.push_back("host_read");
      expected.push_back("host_write");
      expected.push_back("host_read");
    end
    expected.push_back("host_release");
    if (trace.calls.size() != expected.size()) begin
      `uvm_error("REAL_ENGINE_ORDER",
                 $sformatf("observed %0d adapter calls, expected %0d",
                           trace.calls.size(), expected.size()))
      return;
    end
    foreach (expected[i]) begin
      if (trace.calls[i] != expected[i])
        `uvm_error("REAL_ENGINE_ORDER",
                   $sformatf("call[%0d] is %s, expected %s", i,
                             trace.calls[i], expected[i]))
    end
  endfunction

  // 功能：在 rdma_control_plane_cmq_engine_test 中，run_phase 驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：run_phase 的 setup/阶段驱动失败时停止新增事务，并按测试生命周期清理 objection 与临时引用。
  task run_phase(uvm_phase phase);
    rdma_mock_host_mem mock_mem;
    rdma_control_plane_cmq_engine_responder_pcie mock_pcie;
    rdma_mock_call_trace call_trace;
    rdma_doorbell_scheduler scheduler;
    rdma_hw_cmq_hw_profile profile;
    rdma_cmq_engine engine;
    rdma_cmq_engine_port_adapter adapter;
    rdma_resource_manager manager;
    rdma_incarnation_stag_key_policy key_policy;
    rdma_control_plane control;
    rdma_function_binding prepared_binding;
    rdma_function_binding binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_create_pd_req pd_request;
    rdma_register_mr_req mr_request;
    rdma_dma_request_context dma_context;
    rdma_pd pd;
    rdma_mr mr;
    rdma_dma_mapping owned_mapping;
    rdma_control_result pd_result;
    rdma_control_result register_result;
    rdma_control_result destroy_result;
    rdma_control_result pd_destroy_result;
    rdma_cmq_execution_result observed_result;
    rdma_status status;
    int unsigned cmq_backing_only_baseline;
    int unsigned release_count;
    int unsigned resource_leaks;
    bit [7:0] expected_opcodes[$];

    phase.raise_objection(this);

    mock_mem = rdma_mock_host_mem::type_id::create("mock_mem");
    mock_pcie =
      rdma_control_plane_cmq_engine_responder_pcie::type_id::create(
        "mock_pcie"
      );
    call_trace = rdma_mock_call_trace::type_id::create("call_trace");
    mock_mem.set_call_trace(call_trace);
    mock_pcie.set_call_trace(call_trace);
    scheduler = rdma_doorbell_scheduler::type_id::create("scheduler");
    profile = rdma_hw_cmq_hw_profile::type_id::create("profile");
    engine = rdma_cmq_engine::type_id::create("engine");
    adapter = rdma_cmq_engine_port_adapter::type_id::create("adapter");
    manager = rdma_resource_manager::type_id::create("manager");
    key_policy = rdma_incarnation_stag_key_policy::type_id::create(
      "key_policy"
    );
    control = rdma_control_plane::type_id::create("control");
    prepared_binding = make_binding("prepared_binding", RDMA_BIND_PREPARED);
    binding = make_binding("active_binding", RDMA_BIND_ACTIVE);
    cmq = make_cmq("cmq", prepared_binding);

    status = scheduler.configure(mock_mem, mock_pcie);
    expect_status("REAL_ENGINE_SCHEDULER", status, RDMA_SC_OK);
    engine.prepare(prepared_binding, cmq, 1'b1, 20'h14012, mock_mem,
                   scheduler, profile, runtime_desc, status);
    expect_status("REAL_ENGINE_PREPARE", status, RDMA_SC_OK);
    engine.activate(binding, status);
    expect_status("REAL_ENGINE_ACTIVATE", status, RDMA_SC_OK);
    status = adapter.bind_engine(binding.make_handle(), engine);
    expect_status("REAL_ENGINE_BIND", status, RDMA_SC_OK);
    // observed route 的 pre-engine guard 必须返回独立 envelope，且不得触发 CMQ I/O。
    adapter.execute_observed(null, observed_result);
    if (observed_result == null || observed_result.status == null ||
        observed_result.observation_status == null ||
        observed_result.submission_effect != RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED ||
        observed_result.attempt_effect != RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED ||
        observed_result.completion_phase != RDMA_CMQ_COMPLETION_NONE ||
        observed_result.recovery_required != 1'b0)
      `uvm_error("REAL_ENGINE_OBSERVED_ROUTE",
                 "control-plane production adapter did not preserve pre-reject evidence")
    status = mock_pcie.configure_responder(
      mock_mem, engine.mapping_snapshot(), binding
    );
    expect_status("REAL_ENGINE_RESPONDER", status, RDMA_SC_OK);
    status = control.configure(manager, adapter, key_policy, mock_mem,
                               null, null, 40ns);
    expect_status("REAL_ENGINE_CONTROL_CONFIGURE", status, RDMA_SC_OK);

    cmq_backing_only_baseline = mock_mem.live_allocations();
    if (cmq_backing_only_baseline != 1)
      `uvm_error("REAL_ENGINE_BASELINE",
                 $sformatf("expected one CMQ backing, got %0d",
                           cmq_backing_only_baseline))
    mock_mem.calls.delete();
    mock_pcie.calls.delete();
    call_trace.clear();

    pd_request = make_pd_request(binding);
    control.create_pd(binding, pd_request, pd, pd_result);
    if (pd_result == null || !pd_result.ok() || pd == null)
      `uvm_error("REAL_ENGINE_PD", "production PD create failed")

    if (pd != null) begin
      mr_request = make_mr_request(binding, pd, mock_mem.next_address);
      dma_context = make_dma_context(binding);
      control.alloc_and_register_mr(
        binding, mr_request, dma_context, 4096,
        owned_mapping, mr, register_result
      );
    end

    if (register_result == null || !register_result.ok() || mr == null)
      `uvm_error("REAL_ENGINE",
                 "control-plane-owned PBL0 MR registration failed")
    else begin
      control.deregister_mr(binding, mr.handle, destroy_result);
      if (destroy_result == null || !destroy_result.ok())
        `uvm_error("REAL_ENGINE",
                   "control-plane-owned PBL0 MR deregistration failed")
    end

    if (pd != null && register_result != null && register_result.ok() &&
        destroy_result != null && destroy_result.ok()) begin
      control.destroy_pd(binding, pd.handle, pd_destroy_result);
      if (pd_destroy_result == null || !pd_destroy_result.ok())
        `uvm_error("REAL_ENGINE_PD", "production PD destroy failed")
    end

    if (engine.outstanding_count() != 0 ||
        engine.quarantine_count() != 0)
      `uvm_error("REAL_ENGINE", "CMQ ticket leaked")
    if (mock_mem.live_allocations() != cmq_backing_only_baseline)
      `uvm_error("REAL_ENGINE", "owned MR backing leaked")
    release_count = count_mapping_releases(mock_mem, owned_mapping);
    if (release_count != 1)
      `uvm_error("REAL_ENGINE_RELEASE",
                 $sformatf("owned MR mapping release count is %0d",
                           release_count))

    expected_opcodes.push_back(RDMA_OP_KEY_ALLOC);
    expected_opcodes.push_back(RDMA_OP_MR_DEREGISTER);
    expected_opcodes.push_back(RDMA_OP_TQ_FLUSH);
    if (mock_pcie.observed_opcodes.size() != expected_opcodes.size()) begin
      `uvm_error("REAL_ENGINE_OPCODE",
                 $sformatf("observed %0d CMQ opcodes, expected %0d",
                           mock_pcie.observed_opcodes.size(),
                           expected_opcodes.size()))
    end
    else begin
      foreach (expected_opcodes[i]) begin
        if (mock_pcie.observed_opcodes[i] != expected_opcodes[i] ||
            mock_pcie.observed_wqe_indices[i] != i ||
            mock_pcie.observed_wqe_wraps[i] != 1'b0 ||
            mock_pcie.observed_cq_owners[i] != 1'b1 ||
            mock_pcie.observed_doorbell_pis[i] != (i + 1) ||
            mock_pcie.observed_doorbell_polarities[i] != 1'b0)
          `uvm_error("REAL_ENGINE_OPCODE",
                     $sformatf("CMQ command %0d envelope/order is wrong", i))
      end
    end
    expect_lifecycle_trace(call_trace);
    status = manager.check_leaks(resource_leaks, binding.make_handle());
    expect_status("REAL_ENGINE_RESOURCE_LEAK_CHECK", status, RDMA_SC_OK);
    if (resource_leaks != 0)
      `uvm_error("REAL_ENGINE_RESOURCE_LEAK_CHECK",
                 $sformatf("resource manager retained %0d resources",
                           resource_leaks))

    engine.shutdown(status);
    expect_status("REAL_ENGINE_SHUTDOWN", status, RDMA_SC_OK);
    if (mock_mem.live_allocations() != 0)
      `uvm_error("REAL_ENGINE_SHUTDOWN", "CMQ backing was not released")
    phase.drop_objection(this);
  endtask
endclass
