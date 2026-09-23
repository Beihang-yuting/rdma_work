// 目录：测试层 unit/rdma_rq_engine_test.sv，覆盖 RQ facade 的转发契约。
// 职责：验证 RQ facade 复用共享 queue-data runtime，并隔离错误 Function 的接收请求。
// 依赖：rdma_core_pkg、现有 queue-data fixture、mock Host-memory/PCIe 后端。
// 所有权与生命周期：测试只拥有本地 fixture；facade 借用 delegate 和外部后端引用。

// 功能：提供一个只用于边界测试的 queue-data delegate，模拟 post_recv 未返回状态。
// 输入/输出及副作用：post_recv 接收与真实 delegate 相同的 request/result/status
//   端口，故意发布一个未认证 result 并保持 status=null，不触碰 runtime、
//   Host-memory 或门铃。
// 失败/边界：该 delegate 必须只注入 null-status 故障；其他 queue-data API 仍沿用
//   父类实现；facade 必须丢弃未认证 result，测试不得把它当作真实 engine。
class rdma_rq_null_status_delegate extends rdma_queue_data_engine;
  `uvm_object_utils(rdma_rq_null_status_delegate)

  bit inject_failure_status;
  int unsigned post_recv_calls;

  // 功能：构造 null-status delegate 并调用 queue-data engine 父类构造函数。
  // 输入/输出及副作用：name 为输入；new 只初始化本地 UVM 对象，不分配外部资源。
  // 失败/边界：delegate 未配置 runtime/backing；仅可作为 facade 边界故障注入对象。
  function new(string name = "rdma_rq_null_status_delegate");
    super.new(name);
    inject_failure_status = 1'b0;
    post_recv_calls = 0;
  endfunction

  // 功能：模拟 RQ delegate 在 post_recv 入口返回 null 或显式失败状态，同时
  //   夹带一个未认证结果。
  // 输入/输出及副作用：request 为只读输入；result 被设置为未认证测试对象，
  //   status 清空为 null，不推进 cursor、不写 RQE、不发送 doorbell，也不修改
  //   任何外部生命周期对象。
  // 失败/边界：inject_failure_status=0 返回 null，facade 必须归一化为
  //   INVALID_STATE；置 1 时返回 UNKNOWN_HW_ERROR，facade 必须保留该状态；
  //   两种模式都必须清空 result。
  virtual task post_recv(
    rdma_post_recv_req request,
    output rdma_queue_post_result result,
    output rdma_status status
  );
    result = rdma_queue_post_result::type_id::create(
      "rq_untrusted_delegate_result");
    post_recv_calls++;
    status = inject_failure_status ?
      rdma_status::make(RDMA_SC_UNKNOWN_HW_ERROR,
                        "injected RQ delegate failure") : null;
  endtask
endclass

class rdma_rq_engine_test extends uvm_test;
  `uvm_component_utils(rdma_rq_engine_test)

  // 功能：创建 UVM RQ 测试组件并保存父组件关系，不分配队列或后端资源。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_rq_engine_test 构造只建立本地初始状态；本地 semaphore/ledger 等按构造体显式分配，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_rq_engine_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：配置 RQ facade，验证配置生命周期为 one-shot，并检查 post_recv 的
  //   成功转发与 Function authority 校验。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：第二次 configure 必须返回 INVALID_STATE 且保留首个 delegate；
  //   RQ handle 类型错误、跨 Function UID 或 backend 失败时不得产生接收结果。
  task run_phase(uvm_phase phase);
    rdma_queue_data_engine_fixture fixture;
    rdma_rq_engine facade;
    rdma_queue_post_result result;
    rdma_post_recv_req foreign_request;
    rdma_rq_null_status_delegate null_status_delegate;
    rdma_rq_engine valid_facade;
    rdma_rq_engine inactive_facade;
    rdma_status status;
    rdma_status stale_status;
    longint unsigned saved_function_uid;
    rdma_reset_epoch_t saved_reset_epoch;
    int unsigned calls_before_stale;

    phase.raise_objection(this);
    fixture = rdma_queue_data_engine_fixture::type_id::create("rq_fixture");
    fixture.setup(status);
    if (status == null || !status.ok()) begin
      `uvm_error("RQ_FIXTURE", "queue-data fixture setup failed")
      phase.drop_objection(this);
      return;
    end

    // RED：非 ACTIVE binding 即使 validate() 返回 OK 也不能完成 facade 配置；
    // 该门禁必须返回 INVALID_STATE 且不保存 delegate/authority。
    inactive_facade = rdma_rq_engine::type_id::create("rq_inactive_facade");
    fixture.binding.state = RDMA_BIND_DISCOVERED;
    status = inactive_facade.configure(fixture.manager, fixture.binding,
                                        fixture.mem, fixture.scheduler,
                                        fixture.registry, 2us, fixture.engine);
    if (status == null || status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("RQ_CONFIGURE_ACTIVE_GATE",
                 "RQ facade accepted a non-ACTIVE Function binding")
    fixture.binding.state = RDMA_BIND_ACTIVE;

    facade = rdma_rq_engine::type_id::create("rq_facade");
    status = facade.configure(fixture.manager, fixture.binding, fixture.mem,
                              fixture.scheduler, fixture.registry, 2us,
                              fixture.engine);
    if (status == null || !status.ok()) begin
      `uvm_error("RQ_CONFIGURE", "RQ facade configuration failed")
      phase.drop_objection(this);
      return;
    end
    valid_facade = facade;

    status = facade.configure(fixture.manager, fixture.binding, fixture.mem,
                              fixture.scheduler, fixture.registry, 2us,
                              fixture.engine);
    if (status == null || status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("RQ_CONFIGURE_GATE", "configured RQ facade accepted reconfiguration")

    facade.post_recv(fixture.make_recv(64'h3030), result, status);
    if (status == null || !status.ok() || result == null || result.index != 0 ||
        result.image == null)
      `uvm_error("RQ_FORWARD", "RQ facade did not publish delegate post result")

    // RED：冻结的 Function 坐标漂移必须先分类为 STALE_GENERATION，不能被
    // binding.validate() 的 compatibility mirror 错误覆盖。
    saved_function_uid = fixture.binding.function_uid;
    fixture.binding.function_uid = saved_function_uid ^ 64'h1;
    result = null;
    valid_facade.post_recv(fixture.make_recv(64'h3838), result, stale_status);
    if (stale_status == null || stale_status.code != RDMA_SC_STALE_GENERATION ||
        result != null)
      `uvm_error("RQ_STALE_ORDER",
                 "RQ facade did not report stale authority before validation")
    fixture.binding.function_uid = saved_function_uid;

    // RED：已配置 RQ facade 发现 binding 失活后必须立即停止 post_recv，
    // 即便 UID、generation 和 reset epoch 尚未变化。
    fixture.binding.state = RDMA_BIND_DISCOVERED;
    result = null;
    valid_facade.post_recv(fixture.make_recv(64'h3939), result, stale_status);
    if (stale_status == null || stale_status.code != RDMA_SC_INVALID_STATE ||
        result != null)
      `uvm_error("RQ_LIVE_ACTIVE_GATE",
                 "RQ facade continued after Function binding became inactive")
    fixture.binding.state = RDMA_BIND_ACTIVE;

    foreign_request = fixture.make_recv(64'h4040);
    foreign_request.target_h.function_uid = fixture.binding.function_uid ^ 64'h1;
    result = null;
    valid_facade.post_recv(foreign_request, result, status);
    if (status == null || status.ok() || result != null)
      `uvm_error("RQ_ISOLATION", "RQ facade accepted a foreign Function handle")

    // RED/GREEN：delegate 自身也可能因扩展实现缺失而不返回 status；facade 的
    //   post_recv 边界必须把 null 规范化为 INVALID_STATE，并保持 result 为空。
    null_status_delegate = rdma_rq_null_status_delegate::type_id::create(
      "rq_null_status_delegate");
    null_status_delegate.manager = fixture.manager;
    null_status_delegate.binding = fixture.binding;
    null_status_delegate.host_mem = fixture.mem;
    null_status_delegate.doorbells = fixture.scheduler;
    null_status_delegate.registry = fixture.registry;
    facade = rdma_rq_engine::type_id::create("rq_null_status_facade");
    status = facade.configure(fixture.manager, fixture.binding, fixture.mem,
                              fixture.scheduler, fixture.registry, 2us,
                              null_status_delegate);
    if (status == null || !status.ok()) begin
      `uvm_error("RQ_NULL_DELEGATE_CONFIG",
                 "RQ null-status delegate configuration failed")
    end
    else begin
      result = null;
      facade.post_recv(fixture.make_recv(64'h5050), result, status);
      if (status == null || status.code != RDMA_SC_INVALID_STATE || result != null)
        `uvm_error("RQ_NULL_DELEGATE",
                   "RQ facade propagated null delegate status")

      // RED：delegate 返回非 null 失败状态时保留精确错误，但必须丢弃夹带结果。
      null_status_delegate.inject_failure_status = 1'b1;
      result = null;
      facade.post_recv(fixture.make_recv(64'h5151), result, status);
      if (status == null || status.code != RDMA_SC_UNKNOWN_HW_ERROR ||
          status.message != "injected RQ delegate failure" || result != null)
        `uvm_error("RQ_FAILURE_RESULT_DELEGATE",
                   "RQ facade retained a result from failed delegate")

      // RED：reset epoch 漂移必须在 delegate 调用前返回 STALE_GENERATION。
      calls_before_stale = null_status_delegate.post_recv_calls;
      saved_reset_epoch = fixture.binding.function_reset_epoch();
      status = fixture.advance_binding_reset_epoch(saved_reset_epoch + 1);
      if (status == null || !status.ok())
        `uvm_error("RQ_RESET_EPOCH_SETUP",
                   "RQ reset epoch drift setup failed")
      else begin
        result = null;
        facade.post_recv(fixture.make_recv(64'h5252), result, status);
        if (status == null || status.code != RDMA_SC_STALE_GENERATION ||
            result != null ||
            null_status_delegate.post_recv_calls != calls_before_stale)
          `uvm_error("RQ_RESET_EPOCH_GATE",
                     "RQ facade called delegate after reset epoch drift")
      end
    end

    phase.drop_objection(this);
  endtask
endclass
