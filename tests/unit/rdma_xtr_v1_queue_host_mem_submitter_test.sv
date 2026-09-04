// 目录：测试层 unit/rdma_xtr_v1_queue_host_mem_submitter_test.sv。
// 职责：验证 rdma_xtr_v1_queue_host_mem_submitter_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_xtr_v1_queue_host_mem_submitter_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_xtr_v1_queue_host_mem_submitter_test extends uvm_test;
  `uvm_component_utils(rdma_xtr_v1_queue_host_mem_submitter_test)

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_xtr_v1_queue_host_mem_submitter_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：处理 function_handle：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 result 用于执行 function_handle；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：function_handle 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function automatic rdma_function_handle function_handle();
    rdma_function_handle result;
    result = rdma_function_handle::type_id::create("function");
    result.function_uid = 64'h1122;
    result.object_id = 7;
    result.generation = 3;
    return result;
  endfunction

  // 功能：处理 request_context：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 result 用于执行 request_context；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：request_context 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
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

  // 功能：驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase 控制 UVM 调度；task 驱动事务、断言和 objection，测试 fixture 由本层负责清理。
  //   阶段提前结束或前置 setup 失败时必须释放 objection 并停止后续访问。
  // 失败/边界：setup 失败或阶段被终止时停止新增事务，确保 objection、临时对象和外部引用按测试生命周期收尾。
  task run_phase(uvm_phase phase);
    rdma_mock_host_mem mem;
    rdma_codec_registry registry;
    rdma_xtr_v1_queue_host_mem_submitter submitter;
    rdma_xtr_v1_queue_host_mem_target target;
    rdma_dma_request_context context;
    rdma_status status;
    rdma_xtr_v1_sqe_model sqe;
    rdma_sqe_rc_ext rc;
    rdma_sge sge;
    rdma_hw_image image;
    rdma_xtr_v1_aeqe_model aeqe;
    byte unsigned aeqe_bytes[16];
    int unsigned release_calls;
    int unsigned release_calls_after;
    phase.raise_objection(this);

    mem = rdma_mock_host_mem::type_id::create("mem");
    registry = rdma_codec_registry::type_id::create("registry");
    void'(rdma_xtr_v1_register_queue_codecs(registry));
    submitter = rdma_xtr_v1_queue_host_mem_submitter::type_id::create(
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

    sqe = rdma_xtr_v1_sqe_model::type_id::create("sqe");
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
