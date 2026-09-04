// 目录：测试层 unit/rdma_queue_host_mem_submitter_test.sv。
// 职责：验证 rdma_queue_host_mem_submitter_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_queue_host_mem_submitter_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_queue_host_mem_submitter_test extends uvm_test;
  `uvm_component_utils(rdma_queue_host_mem_submitter_test)

  // 功能：构造 rdma_queue_host_mem_submitter_test，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_host_mem_submitter_test 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_host_mem_submitter_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：在 rdma_queue_host_mem_submitter_test 中，function_handle 从测试 fixture 返回预先构造的 Function/队列句柄或 DMA 上下文，保持调用方与 fixture 使用同一实例。
  // 输入/输出及副作用：无显式参数；function_handle 读取局部计算结果，并使用字段 result、result.function_uid、result.object_id、result.generation；函数返回 rdma_function_handle，不取得调用方资源所有权。
  // 失败/边界：function_handle 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  function automatic rdma_function_handle function_handle();
    rdma_function_handle result;
    result = rdma_function_handle::type_id::create("function");
    result.function_uid = 64'h1122;
    result.object_id = 7;
    result.generation = 3;
    return result;
  endfunction

  // 功能：在 rdma_queue_host_mem_submitter_test 中，request_context 从测试 fixture 返回预先构造的 Function/队列句柄或 DMA 上下文，保持调用方与 fixture 使用同一实例。
  // 输入/输出及副作用：无显式参数；request_context 读取局部计算结果，并使用字段 result、result.function_h、result.requester_bdf、result.pasid_valid、result.pasid、result.dma_domain_valid、result.dma_domain_id；函数返回 rdma_dma_request_context，不取得调用方资源所有权。
  // 失败/边界：request_context 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  function automatic rdma_dma_request_context request_context();
    rdma_dma_request_context result;
    result = rdma_dma_request_context::type_id::create("request_context");
    result.function_h = function_handle();
    result.requester_bdf = 16'h0102;
    result.pasid_valid = 1'b1;
    result.pasid = 20'h12345;
    result.dma_domain_valid = 1'b1;
    result.dma_domain_id = 9;
    return result;
  endfunction

  // 功能：在 rdma_queue_host_mem_submitter_test 中，run_phase 驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：run_phase 的 setup/阶段驱动失败时停止新增事务，并按测试生命周期清理 objection 与临时引用。
  task run_phase(uvm_phase phase);
    rdma_mock_host_mem mem;
    rdma_codec_registry registry;
    rdma_queue_host_mem_submitter submitter;
    rdma_queue_host_mem_target target;
    rdma_dma_request_context context;
    rdma_status status;
    rdma_hw_sqe_model sqe;
    rdma_sqe_rc_ext rc;
    rdma_sge sge;
    rdma_hw_image image;
    rdma_hw_aeqe_model aeqe;
    byte unsigned aeqe_bytes[16];
    int unsigned release_calls;
    int unsigned release_calls_after;
    phase.raise_objection(this);

    mem = rdma_mock_host_mem::type_id::create("mem");
    registry = rdma_codec_registry::type_id::create("registry");
    void'(rdma_register_queue_codecs(registry));
    submitter = rdma_queue_host_mem_submitter::type_id::create(
      "submitter");
    submitter.host_mem = mem;
    submitter.registry = registry;
    context = request_context();

    // The submitter must return an opaque target after validating the
    // injected request context and retaining the allocation privately.
    status = submitter.allocate_target(context, 128, 64,
                                       RDMA_DMA_BIDIRECTIONAL, target);
    if (status == null || !status.ok() || target == null)
      `uvm_error("ALLOCATE", "queue host-memory target allocation failed")

    sqe = rdma_hw_sqe_model::type_id::create("sqe");
    sqe.transport = RDMA_TRANSPORT_RC;
    sqe.qp_h = rdma_handle::type_id::create("qp");
    sqe.qp_h.kind = RDMA_RESOURCE_QP;
    sqe.qp_h.function_uid = context.function_h.function_uid;
    sqe.qp_h.generation = context.function_h.generation;
    sqe.hw_opcode = 0;
    sqe.valid = 1'b1;
    rc = rdma_sqe_rc_ext::type_id::create("rc");
    sqe.transport_ext = rc;
    sge = rdma_sge::type_id::create("sge");
    sge.iova.value = 64'h2000;
    sge.length = 8;
    sqe.sges.push_back(sge);
    status = submitter.write_sqe(target, 0, sqe, image);
    if (status == null || !status.ok() || image == null)
      `uvm_error("WRITE", "queue SQE write transaction failed")

    // Seed a device-produced AEQE in the second slot.  Both CEQE and AEQE
    // are 16 bytes; the submitter must preserve the explicitly selected
    // image kind rather than inferring it from length.
    aeqe_bytes = '{8'hd0, 8'h00, 8'h00, 8'h81, 8'hff, 8'h02, 8'haa,
                   8'haa, 8'h00, 8'he5, 8'h43, 8'h21, 8'h00, 8'h00,
                   8'h00, 8'h00};
    foreach (aeqe_bytes[i])
      mem.regions[0].data[64 + i] = aeqe_bytes[i];
    aeqe = null;
    image = null;
    status = submitter.read_aeqe(target, 64, aeqe, image);
    if (status == null || !status.ok() || aeqe == null || image == null ||
        image.image_kind != RDMA_IMAGE_AEQE)
      `uvm_error("READ_AEQE", "AEQE read selected the wrong 16-byte image kind")

    status = submitter.release_target(target);
    if (status == null || !status.ok())
      `uvm_error("RELEASE", "queue target release failed")
    release_calls = 0;
    foreach (mem.calls[i])
      if (mem.calls[i].method_name == "release")
        release_calls++;
    // Exactly-once release: a duplicate release is rejected without another
    // adapter call.
    status = submitter.release_target(target);
    if (status == null || status.ok())
      `uvm_error("DUP_RELEASE", "duplicate target release was accepted")
    release_calls_after = 0;
    foreach (mem.calls[i])
      if (mem.calls[i].method_name == "release")
        release_calls_after++;
    if (release_calls != 1 || release_calls_after != release_calls)
      `uvm_error("DUP_RELEASE_CALL", "duplicate release invoked adapter")
    phase.drop_objection(this);
  endtask
endclass
