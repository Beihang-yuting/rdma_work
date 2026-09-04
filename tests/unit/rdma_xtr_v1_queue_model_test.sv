// 目录：测试层 unit/rdma_xtr_v1_queue_model_test.sv。
// 职责：验证 rdma_xtr_v1_queue_model_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_xtr_v1_queue_model_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_xtr_v1_queue_model_test extends uvm_test;
  `uvm_component_utils(rdma_xtr_v1_queue_model_test)

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(
    string name = "rdma_xtr_v1_queue_model_test",
    uvm_component parent = null
  );
    super.new(name, parent);
  endfunction

  // 功能：依据输入请求创建对应的值对象或资源计划，并校验依赖、所有权和生命周期后返回结果。
  // 输入/输出及副作用：输入请求、容量和依赖用于构造/预留资源；返回独立对象或状态，不暴露内部可变集合。
  //   参数越界、容量不足或构造中途失败时回滚已登记的局部状态。
  // 失败/边界：依赖为空、参数越界、容量不足或构造步骤失败时清理局部结果并返回明确错误。
  function automatic rdma_handle make_handle(
    string name,
    rdma_resource_kind_e kind,
    int unsigned object_id
  );
    rdma_handle handle;

    handle = rdma_handle::type_id::create(name);
    handle.kind = kind;
    handle.function_uid = 64'h0123_4567_89ab_cdef;
    handle.object_id = object_id;
    handle.generation = 32'd7;
    return handle;
  endfunction

  // 功能：在测试中检查调用结果、状态码和副作用是否符合契约；失败时报告可定位的验证信息。
  // 输入/输出及副作用：参数 label, status, expected 用于执行 expect_status；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：测试前置对象缺失时应报告断言错误并停止依赖该对象的后续检查。
  function automatic void expect_status(
    string label,
    rdma_status status,
    rdma_status_code_e expected
  );
    if (status == null || status.code != expected)
      `uvm_error(
        label,
        $sformatf(
          "expected %s, got %s (%s)",
          expected.name(),
          status == null ? "null" : status.code.name(),
          status == null ? "" : status.message
        )
      )
  endfunction

  // 功能：驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase 控制 UVM 调度；task 驱动事务、断言和 objection，测试 fixture 由本层负责清理。
  //   阶段提前结束或前置 setup 失败时必须释放 objection 并停止后续访问。
  // 失败/边界：setup 失败或阶段被终止时停止新增事务，确保 objection、临时对象和外部引用按测试生命周期收尾。
  task run_phase(uvm_phase phase);
    rdma_post_recv_req request;
    rdma_post_recv_req cloned_request;
    rdma_handle qp_h;
    rdma_handle srq_h;
    rdma_sge sge;
    uvm_object cloned_object;

    phase.raise_objection(this);

    qp_h = make_handle("qp_h", RDMA_RESOURCE_QP, 32'h100);
    srq_h = make_handle("srq_h", RDMA_RESOURCE_SRQ, 32'h200);
    sge = rdma_sge::type_id::create("sge");
    sge.iova.value = 64'h4000;
    sge.length = 64;
    sge.lkey = 32'h55aa;

    request = rdma_post_recv_req::type_id::create("request");
    request.wr_id = 64'h1122_3344_5566_7788;
    request.sges.push_back(sge);

    // A private RQ is identified by a QP target and has no completion QP.
    if (request.completion_qp_h != null)
      `uvm_error("POST_RECV_DEFAULT_COMPLETION_QP",
                 "completion_qp_h must default to null")
    request.target_h = qp_h;
    expect_status("POST_RECV_PRIVATE_QP", request.validate(), RDMA_SC_OK);

    // Supplying a completion QP for a private RQ is contradictory.
    request.completion_qp_h = qp_h;
    expect_status("POST_RECV_PRIVATE_COMPLETION_QP",
                  request.validate(), RDMA_SC_INVALID_ARGUMENT);

    // A shared SRQ must identify the QP which owns the receive completion.
    request.target_h = srq_h;
    request.completion_qp_h = null;
    expect_status("POST_RECV_SHARED_SRQ_MISSING_COMPLETION_QP",
                  request.validate(), RDMA_SC_INVALID_ARGUMENT);
    request.completion_qp_h = qp_h;
    expect_status("POST_RECV_SHARED_SRQ", request.validate(), RDMA_SC_OK);

    // The completion QP is itself a QP handle, not an arbitrary resource.
    request.completion_qp_h = srq_h;
    expect_status("POST_RECV_SHARED_SRQ_COMPLETION_KIND",
                  request.validate(), RDMA_SC_INVALID_ARGUMENT);

    // The new handle must be deep-cloned with the rest of the request.
    request.completion_qp_h = qp_h;
    cloned_object = request.clone();
    if (cloned_object == null || !$cast(cloned_request, cloned_object)) begin
      `uvm_error("POST_RECV_CLONE", "post-receive request clone failed")
    end
    else begin
      if (cloned_request.completion_qp_h == null ||
          cloned_request.completion_qp_h == request.completion_qp_h)
        `uvm_error("POST_RECV_CLONE_COMPLETION_QP",
                   "completion_qp_h was not deep-cloned")
      cloned_request.completion_qp_h.object_id = 32'hdead;
      if (request.completion_qp_h.object_id == 32'hdead)
        `uvm_error("POST_RECV_CLONE_ALIAS",
                   "completion_qp_h clone aliases the source")
    end

    phase.drop_objection(this);
  endtask
endclass
