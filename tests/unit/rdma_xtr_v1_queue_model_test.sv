// 目录：测试层 unit/rdma_xtr_v1_queue_model_test.sv。
// 职责：验证 rdma_xtr_v1_queue_model_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_xtr_v1_queue_model_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_xtr_v1_queue_model_test extends uvm_test;
  `uvm_component_utils(rdma_xtr_v1_queue_model_test)

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function new(
    string name = "rdma_xtr_v1_queue_model_test",
    uvm_component parent = null
  );
    super.new(name, parent);
  endfunction

  // 功能：依据输入快照构造请求、资源或适配对象，并返回独立的结果载体（接口 make_handle）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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

  // 功能：执行接口 expect_status 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 expect_status）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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

  // 功能：执行 UVM 阶段任务，驱动测试场景并在结束时释放阶段 objection（接口 run_phase）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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
