// 目录：测试层 unit/rdma_queue_model_test.sv。
// 职责：验证 rdma_queue_model_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_queue_model_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_queue_model_test extends uvm_test;
  `uvm_component_utils(rdma_queue_model_test)

  // 功能：构造 rdma_queue_model_test，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_model_test 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(
    string name = "rdma_queue_model_test",
    uvm_component parent = null
  );
    super.new(name, parent);
  endfunction

  // 功能：make_handle 创建独立的 rdma_handle；根据 name、kind、object_id 设置字段 handle、handle.kind、handle.function_uid、handle.object_id、handle.generation，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、kind（输入）、object_id（输入）；make_handle 读取 name、kind、object_id 并使用字段 handle、handle.kind、handle.function_uid、handle.object_id、handle.generation；函数返回 rdma_handle，不取得调用方资源所有权。
  // 失败/边界：make_handle 的结果直接由 return handle 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
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

  // 功能：在 rdma_queue_model_test 中，expect_status 在测试中执行 expect_status 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、status（输入）、expected（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_status 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
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

  // 功能：在 rdma_queue_model_test 中，run_phase 驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：run_phase 的 setup/阶段驱动失败时停止新增事务，并按测试生命周期清理 objection 与临时引用。
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
