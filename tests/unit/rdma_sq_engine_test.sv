// 目录：测试层 unit/rdma_sq_engine_test.sv，覆盖 SQ facade 的转发契约。
// 职责：验证 SQ facade 只调用共享 queue-data runtime，并在 Function 身份失配时拒绝请求。
// 依赖：rdma_core_pkg、现有 queue-data fixture、mock Host-memory/PCIe 后端。
// 所有权与生命周期：测试只拥有本地 fixture；facade 和 delegate 的生命周期由本测试管理，
// 外部后端引用不由 facade 接管。

// 功能：构造一个让 request.validate() 返回 null 的 SQ 测试请求，注入 delegate
//   返回值缺失故障以验证 facade 的 fail-closed 归一化。
// 输入/输出及副作用：name 为输入；new 建立空测试对象，不修改共享 engine 或
//   外部资源；validate 无输出对象，仅返回 null 状态。
// 失败/边界：该 fixture 只用于验证空 status 边界，不能作为可提交的业务请求；
//   除非测试显式调用 validate，否则不会主动报告故障。
class rdma_sq_null_validate_request extends rdma_post_send_req;
  `uvm_object_utils(rdma_sq_null_validate_request)

  // 功能：构造 null-validation 测试请求并调用父类建立 UVM 对象。
  // 输入/输出及副作用：name 为输入；new 返回 void，仅初始化本地 fixture。
  // 失败/边界：构造不代表请求合法，validate 将按故障注入契约返回 null。
  function new(string name = "rdma_sq_null_validate_request");
    super.new(name);
  endfunction

  // 功能：模拟扩展请求验证器缺失返回值的故障。
  // 输入/输出及副作用：无输入；返回 null rdma_status，不修改请求或外部资源。
  // 失败/边界：仅用于 facade 负向测试，业务调用不得依赖该请求提交成功。
  virtual function rdma_status validate();
    return null;
  endfunction
endclass

// 功能：提供一个只用于边界测试的 queue-data delegate，模拟 post_send 未返回状态。
// 输入/输出及副作用：post_send 接收真实 delegate 的 request/result/status 端口，
//   故意发布一个未认证 result 并保持 status=null，不推进 SQ cursor、不写 SQE
//   或发送 doorbell。
// 失败/边界：该对象只注入 null-status 故障；SQ facade 必须将其转换为
//   INVALID_STATE，并丢弃没有成功状态支撑的 result。
class rdma_sq_null_status_delegate extends rdma_queue_data_engine;
  `uvm_object_utils(rdma_sq_null_status_delegate)

  bit inject_failure_status;
  int unsigned post_send_calls;

  // 功能：构造 null-status SQ delegate，并初始化父类的本地索引与锁。
  // 输入/输出及副作用：name 为输入；new 不分配 Host-memory、runtime 或外部资源。
  // 失败/边界：delegate 未配置为可提交 engine，只能用于 facade 边界测试。
  function new(string name = "rdma_sq_null_status_delegate");
    super.new(name);
    inject_failure_status = 1'b0;
    post_send_calls = 0;
  endfunction

  // 功能：模拟 SQ delegate 在 post_send 入口返回 null 或显式失败状态，同时
  //   夹带一个未认证结果。
  // 输入/输出及副作用：request 为只读输入；result 被设置为未认证测试对象，
  //   status 清空为 null，不修改任何 queue-data 状态或外部生命周期对象。
  // 失败/边界：inject_failure_status=0 返回 null，facade 必须归一化为
  //   INVALID_STATE；置 1 时返回 UNKNOWN_HW_ERROR，facade 必须保留该状态；
  //   两种模式都必须清空 result。
  virtual task post_send(
    rdma_post_send_req request,
    output rdma_queue_post_result result,
    output rdma_status status
  );
    result = rdma_queue_post_result::type_id::create(
      "sq_untrusted_delegate_result");
    post_send_calls++;
    status = inject_failure_status ?
      rdma_status::make(RDMA_SC_UNKNOWN_HW_ERROR,
                        "injected SQ delegate failure") : null;
  endtask
endclass

class rdma_sq_engine_test extends uvm_test;
  `uvm_component_utils(rdma_sq_engine_test)

  // 功能：创建 UVM 测试组件并保留父组件关系，不初始化任何外部队列资源。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：参数为空时仍交由 UVM 处理，真正的依赖校验在 run_phase 中完成。
  function new(string name = "rdma_sq_engine_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：配置 SQ facade，验证配置生命周期为 one-shot、post_send 转发到唯一
  //   queue-data engine，并检查跨 Function 请求被隔离。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：第二次 configure 必须返回 INVALID_STATE 且保留首个 delegate；
  //   共享 delegate 未配置、请求为空或 Function UID/generation 不一致时不得发布结果。
  task run_phase(uvm_phase phase);
    rdma_queue_data_engine_fixture fixture;
    rdma_sq_engine facade;
    rdma_queue_post_result result;
    rdma_post_send_req foreign_request;
    rdma_sq_null_validate_request null_validate_request;
    rdma_sq_null_status_delegate null_status_delegate;
    rdma_sq_engine valid_facade;
    rdma_sq_engine inactive_facade;
    rdma_status status;
    rdma_status stale_status;
    longint unsigned saved_function_uid;
    rdma_reset_epoch_t saved_reset_epoch;
    int unsigned calls_before_stale;

    phase.raise_objection(this);
    fixture = rdma_queue_data_engine_fixture::type_id::create("sq_fixture");
    fixture.setup(status);
    if (status == null || !status.ok()) begin
      `uvm_error("SQ_FIXTURE", "queue-data fixture setup failed")
      phase.drop_objection(this);
      return;
    end

    // RED：validate() 对非 ACTIVE binding 仍可能返回 OK；facade configure
    // 必须把 state 门禁单独归一化为 INVALID_STATE，不能保存不可用 authority。
    inactive_facade = rdma_sq_engine::type_id::create("sq_inactive_facade");
    fixture.binding.state = RDMA_BIND_DISCOVERED;
    status = inactive_facade.configure(fixture.manager, fixture.binding,
                                        fixture.mem, fixture.scheduler,
                                        fixture.registry, 2us, fixture.engine);
    if (status == null || status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("SQ_CONFIGURE_ACTIVE_GATE",
                 "SQ facade accepted a non-ACTIVE Function binding")
    fixture.binding.state = RDMA_BIND_ACTIVE;

    facade = rdma_sq_engine::type_id::create("sq_facade");
    status = facade.configure(fixture.manager, fixture.binding, fixture.mem,
                              fixture.scheduler, fixture.registry, 2us,
                              fixture.engine);
    if (status == null || !status.ok()) begin
      `uvm_error("SQ_CONFIGURE", "SQ facade configuration failed")
      phase.drop_objection(this);
      return;
    end

    status = facade.configure(fixture.manager, fixture.binding, fixture.mem,
                              fixture.scheduler, fixture.registry, 2us,
                              fixture.engine);
    if (status == null || status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("SQ_CONFIGURE_GATE", "configured SQ facade accepted reconfiguration")

    facade.post_send(fixture.make_send(64'h1010), result, status);
    if (status == null || !status.ok() || result == null || result.index != 0 ||
        result.image == null)
      `uvm_error("SQ_FORWARD", "SQ facade did not publish delegate post result")
    valid_facade = facade;

    // RED：冻结 authority 坐标漂移时，stale-generation 必须优先于
    // binding.validate() 的镜像不一致错误，保证所有 facade 的错误分类一致。
    saved_function_uid = fixture.binding.function_uid;
    fixture.binding.function_uid = saved_function_uid ^ 64'h1;
    result = null;
    valid_facade.post_send(fixture.make_send(64'h1818), result, stale_status);
    if (stale_status == null || stale_status.code != RDMA_SC_STALE_GENERATION ||
        result != null)
      `uvm_error("SQ_STALE_ORDER",
                 "SQ facade did not report stale authority before validation")
    fixture.binding.function_uid = saved_function_uid;

    // RED：已配置 facade 也必须在 binding 失活后停止提交，不能只依赖
    // generation/reset epoch 坐标保持不变这一偶然条件。
    fixture.binding.state = RDMA_BIND_DISCOVERED;
    result = null;
    valid_facade.post_send(fixture.make_send(64'h1919), result, stale_status);
    if (stale_status == null || stale_status.code != RDMA_SC_INVALID_STATE ||
        result != null)
      `uvm_error("SQ_LIVE_ACTIVE_GATE",
                 "SQ facade continued after Function binding became inactive")
    fixture.binding.state = RDMA_BIND_ACTIVE;

    // RED：request.validate() 可能因扩展请求实现缺失而返回 null；facade
    // 必须归一化为 INVALID_STATE，而不能把 null status 传播给调用方。
    null_validate_request = rdma_sq_null_validate_request::type_id::create(
      "sq_null_validate_request");
    null_validate_request.qp_h = fixture.qp.handle;
    null_validate_request.transport = RDMA_TRANSPORT_RC;
    result = null;
    facade.post_send(null_validate_request, result, status);
    if (status == null || status.code != RDMA_SC_INVALID_STATE || result != null)
      `uvm_error("SQ_NULL_VALIDATE",
                 "SQ facade propagated null request validation status")

    // Same local QP number is not sufficient authority: a foreign Function UID
    // must be rejected before the shared runtime can reserve another slot.
    foreign_request = fixture.make_send(64'h2020);
    foreign_request.qp_h.function_uid = fixture.binding.function_uid ^ 64'h1;
    result = null;
    facade.post_send(foreign_request, result, status);
    if (status == null || status.ok() || result != null)
      `uvm_error("SQ_ISOLATION", "SQ facade accepted a foreign Function handle")

    // RED/GREEN：delegate 可能在 post_send 边界丢失 status；SQ facade 必须
    //   fail-closed 归一化为 INVALID_STATE，并且不伪造 post result。
    null_status_delegate = rdma_sq_null_status_delegate::type_id::create(
      "sq_null_status_delegate");
    null_status_delegate.manager = fixture.manager;
    null_status_delegate.binding = fixture.binding;
    null_status_delegate.host_mem = fixture.mem;
    null_status_delegate.doorbells = fixture.scheduler;
    null_status_delegate.registry = fixture.registry;
    facade = rdma_sq_engine::type_id::create("sq_null_status_facade");
    status = facade.configure(fixture.manager, fixture.binding, fixture.mem,
                              fixture.scheduler, fixture.registry, 2us,
                              null_status_delegate);
    if (status == null || !status.ok()) begin
      `uvm_error("SQ_NULL_DELEGATE_CONFIG",
                 "SQ null-status delegate configuration failed")
    end
    else begin
      result = null;
      facade.post_send(fixture.make_send(64'h6060), result, status);
      if (status == null || status.code != RDMA_SC_INVALID_STATE || result != null)
        `uvm_error("SQ_NULL_DELEGATE",
                   "SQ facade propagated null delegate status")

      // RED：非 null 的真实失败状态必须原样传播，但失败结果没有成功状态支撑，
      // facade 不得把 delegate 夹带的 result 暴露给调用方。
      null_status_delegate.inject_failure_status = 1'b1;
      result = null;
      facade.post_send(fixture.make_send(64'h6161), result, status);
      if (status == null || status.code != RDMA_SC_UNKNOWN_HW_ERROR ||
          status.message != "injected SQ delegate failure" || result != null)
        `uvm_error("SQ_FAILURE_RESULT_DELEGATE",
                   "SQ facade retained a result from failed delegate")

      // RED：reset epoch 漂移必须在调用 delegate 前被拒绝；call counter 证明
      // hostile post_send 没有被执行，result 仍为空。
      calls_before_stale = null_status_delegate.post_send_calls;
      saved_reset_epoch = fixture.binding.function_reset_epoch();
      status = fixture.advance_binding_reset_epoch(saved_reset_epoch + 1);
      if (status == null || !status.ok())
        `uvm_error("SQ_RESET_EPOCH_SETUP",
                   "SQ reset epoch drift setup failed")
      else begin
        result = null;
        facade.post_send(fixture.make_send(64'h6262), result, status);
        if (status == null || status.code != RDMA_SC_STALE_GENERATION ||
            result != null ||
            null_status_delegate.post_send_calls != calls_before_stale)
          `uvm_error("SQ_RESET_EPOCH_GATE",
                     "SQ facade called delegate after reset epoch drift")
      end
    end

    phase.drop_objection(this);
  endtask
endclass
