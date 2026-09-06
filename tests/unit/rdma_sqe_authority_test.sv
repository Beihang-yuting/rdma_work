// 目录：测试层 unit/rdma_sqe_authority_test.sv。
// 职责：验证发送 WQE 引用的 Function、generation、对象身份和 attached authority 边界。
// 依赖：rdma_model_pkg、rdma_codec_pkg 与 UVM；测试对象只拥有本地句柄快照。
// 所有权与生命周期：测试夹具不登记资源或接管队列；句柄仅模拟调用方提交的 authority。

// 中文说明：本测试先锁定 SQE authority 契约，再由数据面 engine 负责验证运行时 attach。
// 这样可区分纯请求模型拒绝（UID/generation/对象身份）与队列路由拒绝（attached QP）。
class rdma_sqe_authority_test extends uvm_test;
  `uvm_component_utils(rdma_sqe_authority_test)

  // 功能：构造 SQE authority focused 测试组件，建立 UVM 测试节点。
  // 输入/输出及副作用：name、parent 为输入；构造只注册本地测试组件，不创建或拥有外部资源。
  // 失败/边界：构造不执行 authority 校验；依赖缺失由 run_phase 中的断言暴露。
  function new(string name = "rdma_sqe_authority_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：创建具有指定 UID、对象 ID 和 generation 的 Function authority 快照，作为请求 owner。
  // 输入/输出及副作用：uid、object_id、generation 为输入；返回独立 function handle，不修改其他对象或资源账本。
  // 失败/边界：零 UID/generation 仍由被测请求或 engine helper 拒绝；本 helper 不伪造已登记 Function。
  function automatic rdma_function_handle make_function(
    longint unsigned uid = 64'h1122_3344,
    int unsigned object_id = 32'h100,
    int unsigned generation = 32'd7
  );
    rdma_function_handle result;
    result = rdma_function_handle::type_id::create("sqe_function");
    result.kind = RDMA_RESOURCE_FUNCTION;
    result.function_uid = uid;
    result.object_id = object_id;
    result.generation = generation;
    return result;
  endfunction

  // 功能：创建具有指定资源类型和完整 Function incarnation 的对象句柄，供 SQE authority 场景复用。
  // 输入/输出及副作用：kind、object_id、uid、generation 为输入；返回 detached rdma_handle，不登记 manager 或 runtime attach 表。
  // 失败/边界：句柄只表达值身份，不能单独证明对象已 attached；attached 语义由 queue-data engine 入口另行验证。
  function automatic rdma_handle make_handle(
    rdma_resource_kind_e kind,
    int unsigned object_id,
    longint unsigned uid = 64'h1122_3344,
    int unsigned generation = 32'd7
  );
    rdma_handle result;
    result = rdma_handle::type_id::create("sqe_handle");
    result.kind = kind;
    result.object_id = object_id;
    result.function_uid = uid;
    result.generation = generation;
    return result;
  endfunction

  // 功能：创建最小有效 URC SEND 请求，提供 completion QP 和一条合法 SGE 以隔离 authority 断言。
  // 输入/输出及副作用：owner、qp_h、completion_qp_h 为输入引用；返回请求只拥有复制后的语义引用，不触碰队列游标。
  // 失败/边界：调用方替换 completion_qp_h 的 UID/generation/kind 后，validate 必须拒绝且不得发布成功状态。
  function automatic rdma_post_send_req make_urc_send(
    rdma_function_handle owner,
    rdma_handle qp_h,
    rdma_handle completion_qp_h
  );
    rdma_post_send_req request;
    rdma_sge sge;
    request = rdma_post_send_req::type_id::create("urc_authority_request");
    request.owner = owner;
    request.qp_h = qp_h;
    request.transport = RDMA_TRANSPORT_URC;
    request.opcode = RDMA_WR_SEND;
    request.destination_qpn = 24'h55;
    request.completion_qp_h = completion_qp_h;
    sge = rdma_sge::type_id::create("urc_authority_sge");
    sge.iova.value = 64'h4000;
    sge.length = 16;
    sge.lkey = 32'h1234;
    request.sges.push_back(sge);
    return request;
  endfunction

  // 功能：创建无 payload 的 RC control WQE 请求，供 REG_MR、BIND_MW 和 FLUSH authority 分支复用。
  // 输入/输出及副作用：owner、qp_h、opcode、mr_h、mw_h、authority_h 为输入；返回本地请求对象，不提交 SQE。
  // 失败/边界：control WQE 的引用为空、kind 错误、UID/generation 失配或 FLUSH 对象身份错误时 validate 必须拒绝。
  function automatic rdma_post_send_req make_control(
    rdma_function_handle owner,
    rdma_handle qp_h,
    rdma_work_opcode_e opcode,
    rdma_handle mr_h = null,
    rdma_handle mw_h = null,
    rdma_handle authority_h = null
  );
    rdma_post_send_req request;
    request = rdma_post_send_req::type_id::create("control_authority_request");
    request.owner = owner;
    request.qp_h = qp_h;
    request.transport = RDMA_TRANSPORT_RC;
    request.opcode = opcode;
    request.mr_h = mr_h;
    request.mw_h = mw_h;
    request.authority_h = authority_h;
    return request;
  endfunction

  // 功能：断言 status 与预期 code 一致，统一检查 authority 失败分支且避免空 status 解引用。
  // 输入/输出及副作用：label、status、expected_code 为输入；失败时报告 UVM error，不修改请求或 authority。
  // 失败/边界：status 为空或 code 不一致均报告错误；成功 status 只能表示当前单个断言通过。
  function automatic void expect_code(
    string label, rdma_status status, rdma_status_code_e expected_code
  );
    if (status == null || status.code != expected_code)
      `uvm_error("SQE_AUTH",
                 $sformatf("%s expected=%s actual=%s", label,
                           expected_code.name(),
                           status == null ? "<null>" : status.code.name()))
  endfunction

  // 功能：运行 completion QP、MR/MW 和 FLUSH 的 Function/generation/对象身份拒绝契约。
  // 输入/输出及副作用：phase 为 UVM 阶段输入；任务只创建本地请求、调用 validate 并发布断言结果。
  // 失败/边界：任一错误 authority 被接受、错误 code 被返回或合法 authority 被拒绝时报告 UVM error。
  task run_phase(uvm_phase phase);
    rdma_function_handle owner;
    rdma_function_handle foreign_owner;
    rdma_handle qp_h;
    rdma_handle completion_qp_h;
    rdma_handle mr_h;
    rdma_handle mw_h;
    rdma_handle authority_h;
    rdma_post_send_req request;
    rdma_status status;

    phase.raise_objection(this);
    owner = make_function();
    foreign_owner = make_function(64'h5566_7788, owner.object_id,
                                  owner.generation);
    qp_h = make_handle(RDMA_RESOURCE_QP, 32'h201);
    completion_qp_h = make_handle(RDMA_RESOURCE_QP, 32'h202);
    request = make_urc_send(owner, qp_h, completion_qp_h);
    expect_code("URC completion QP same Function", request.validate(),
                RDMA_SC_OK);

    completion_qp_h.function_uid = foreign_owner.function_uid;
    status = request.validate();
    expect_code("URC completion QP foreign Function", status,
                RDMA_SC_INVALID_ARGUMENT);
    completion_qp_h.function_uid = owner.function_uid;
    completion_qp_h.generation = owner.generation + 1;
    status = request.validate();
    expect_code("URC completion QP stale generation", status,
                RDMA_SC_STALE_GENERATION);
    completion_qp_h.generation = owner.generation;
    completion_qp_h.kind = RDMA_RESOURCE_CQ;
    status = request.validate();
    expect_code("URC completion QP wrong kind", status,
                RDMA_SC_INVALID_ARGUMENT);

    mr_h = make_handle(RDMA_RESOURCE_MR, 32'h302);
    request = make_control(owner, qp_h, RDMA_WR_REG_MR, mr_h);
    expect_code("REG_MR same Function", request.validate(), RDMA_SC_OK);
    mr_h.function_uid = foreign_owner.function_uid;
    expect_code("REG_MR foreign Function", request.validate(),
                RDMA_SC_INVALID_ARGUMENT);
    mr_h.function_uid = owner.function_uid;
    mr_h.generation = owner.generation + 1;
    expect_code("REG_MR stale generation", request.validate(),
                RDMA_SC_STALE_GENERATION);

    mr_h = make_handle(RDMA_RESOURCE_MR, 32'h302);
    mw_h = make_handle(RDMA_RESOURCE_MW, 32'h403);
    request = make_control(owner, qp_h, RDMA_WR_BIND_MW, mr_h, mw_h);
    expect_code("BIND_MW same Function", request.validate(), RDMA_SC_OK);
    mw_h.function_uid = foreign_owner.function_uid;
    expect_code("BIND_MW foreign MW Function", request.validate(),
                RDMA_SC_INVALID_ARGUMENT);
    mw_h.function_uid = owner.function_uid;
    mw_h.generation = owner.generation + 1;
    expect_code("BIND_MW stale MW generation", request.validate(),
                RDMA_SC_STALE_GENERATION);

    authority_h = make_handle(RDMA_RESOURCE_QP, qp_h.object_id);
    request = make_control(owner, qp_h, RDMA_WR_FLUSH, null, null,
                           authority_h);
    expect_code("FLUSH same QP authority", request.validate(), RDMA_SC_OK);
    authority_h.function_uid = foreign_owner.function_uid;
    expect_code("FLUSH foreign Function", request.validate(),
                RDMA_SC_INVALID_ARGUMENT);
    authority_h.function_uid = owner.function_uid;
    authority_h.generation = owner.generation + 1;
    expect_code("FLUSH stale generation", request.validate(),
                RDMA_SC_STALE_GENERATION);
    authority_h.generation = owner.generation;
    authority_h.object_id++;
    expect_code("FLUSH detached object identity", request.validate(),
                RDMA_SC_INVALID_STATE);

    phase.drop_objection(this);
  endtask
endclass
