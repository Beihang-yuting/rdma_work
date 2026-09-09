// 目录：核心执行层 core/rdma_eq_engine.sv，位于事件队列数据路径的 EQ facade。
// 职责：提供 CEQ/AEQ 消费入口，把事件解码、route 和 CI 提交委托给共享 queue-data engine。
// 依赖：rdma_queue_data_engine、rdma_queue_event_result 及 CEQ/AEQ codec/adapter 契约。
// 所有权与生命周期：facade 借用共享 runtime 和 router；不拥有事件 ring、mapping 或外部后端。

class rdma_eq_engine extends uvm_object;
  `uvm_object_utils(rdma_eq_engine)

  protected rdma_queue_data_engine delegate;
  protected time operation_timeout;
  protected bit configured;

  // 功能：创建未配置的 EQ facade，不分配 CEQ/AEQ ring 或中断资源。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：configure 前调用任一 poll 入口都返回 INVALID_STATE 且不发布 event。
  function new(string name = "rdma_eq_engine");
    super.new(name);
    delegate = null;
    operation_timeout = 0;
    configured = 1'b0;
  endfunction

  // 功能：绑定共享 queue-data engine，并校验 EQ facade 与 delegate 使用同一组 Function/后端依赖。
  // 输入/输出及副作用：resource_manager（输入）、function_binding（输入）、memory（输入）、scheduler（输入）、codecs（输入）、timeout（输入）、shared_engine（输入）；调用方必须先完成输入对象的空值、authority 和 generation 校验；成功时更新本对象配置/状态并保存非拥有引用，返回
  //   rdma_status。
  // 失败/边界：实现中的空依赖、重复登记、状态或 generation/authority 校验失败时返回错误；失败时保留旧配置。
  function rdma_status configure(
    rdma_resource_manager resource_manager,
    rdma_function_binding function_binding,
    rdma_host_mem_api memory,
    rdma_doorbell_scheduler scheduler,
    rdma_codec_registry codecs,
    time timeout,
    rdma_queue_data_engine shared_engine = null
  );
    rdma_status status;
    if (resource_manager == null || function_binding == null || memory == null ||
        scheduler == null || codecs == null || timeout == 0 || shared_engine == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "EQ facade configuration dependency is null/zero");
    if (shared_engine.manager != resource_manager ||
        shared_engine.binding != function_binding ||
        shared_engine.host_mem != memory ||
        shared_engine.doorbells != scheduler ||
        shared_engine.registry != codecs)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "EQ facade dependencies do not match shared engine");
    status = function_binding.validate();
    if (status == null || !status.ok() || function_binding.state != RDMA_BIND_ACTIVE)
      return status == null ?
        rdma_status::make(RDMA_SC_INVALID_STATE, "EQ Function binding validation returned null") :
        status;
    delegate = shared_engine;
    operation_timeout = timeout;
    configured = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：轮询 CEQ，将事件解码、CQ route 和 CI commit 交给共享 engine，并按超时策略等待条目出现。
  // 输入/输出及副作用：ceq_h（输入）、result（输出）、status（输出）；poll_ceqe 驱动下游事务，并写入 result、status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：CEQ 未登记、owner 不匹配、CI doorbell 失败或代际过期时不发布事件。
  task poll_ceqe(
    rdma_handle ceq_h,
    output rdma_queue_event_result result,
    output rdma_status status
  );
    result = null;
    status = null;
    if (!configured || delegate == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "EQ facade is not configured");
      return;
    end
    delegate.poll_ceqe(ceq_h, operation_timeout, result, status);
  endtask

  // 功能：轮询 AEQ，将异常事件解码、QP route 和 CI commit 交给共享 engine，并按超时策略等待条目出现。
  // 输入/输出及副作用：aeq_h（输入）、result（输出）、status（输出）；poll_aeqe 驱动下游事务，并写入 result、status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：AEQ 未登记、错误 handle kind、owner/identity 失配或 CI 提交失败时不发布事件。
  task poll_aeqe(
    rdma_handle aeq_h,
    output rdma_queue_event_result result,
    output rdma_status status
  );
    result = null;
    status = null;
    if (!configured || delegate == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "EQ facade is not configured");
      return;
    end
    delegate.poll_aeqe(aeq_h, operation_timeout, result, status);
  endtask

  // 功能：publish_ceqe 将已经通过 CQ authority 校验的 CEQE 发布请求透明转交
  //   给共享 queue-data engine，保持 CEQ backing 与 producer runtime 单一所有者。
  // 输入/输出及副作用：ceq_h、model 为输入，result/status 为输出；facade 既不
  //   clone result/image，也不修改 CEQ/CQ runtime 或 backing，只传播 delegate 输出。
  // 失败边界：未 configure 或 delegate 缺失返回 INVALID_STATE 且 result 为 null；
  //   其余 CQ route、PI、polarity、full、codec/recovery 拒绝原样保留。
  task publish_ceqe(
    rdma_handle ceq_h,
    rdma_hw_ceqe_model model,
    output rdma_queue_device_publish_result result,
    output rdma_status status
  );
    result = null;
    status = null;
    if (!configured || delegate == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "EQ facade is not configured");
      return;
    end
    delegate.publish_ceqe(ceq_h, model, result, status);
  endtask

  // 功能：publish_aeqe 将已绑定 QP 的 AEQE 发布请求透明转交给共享 engine，
  //   防止 facade 自行构造 image、占用 ring 或改变 target route。
  // 输入/输出及副作用：aeq_h、model 为输入，result/status 为输出；成功 result
  //   的 queue_h/image 仍归 delegate 创建，facade 只借用并返回同一 detached 对象。
  // 失败边界：未 configure/delegate 空返回 INVALID_STATE；目标 QP、generation、
  //   polarity、满环和编码失败由 delegate 保持原错误码与空 result 传播。
  task publish_aeqe(
    rdma_handle aeq_h,
    rdma_hw_aeqe_model model,
    output rdma_queue_device_publish_result result,
    output rdma_status status
  );
    result = null;
    status = null;
    if (!configured || delegate == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "EQ facade is not configured");
      return;
    end
    delegate.publish_aeqe(aeq_h, model, result, status);
  endtask
endclass
