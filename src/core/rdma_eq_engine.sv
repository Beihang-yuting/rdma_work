// 目录：核心执行层 core/rdma_eq_engine.sv，事件队列数据路径的 EQ facade。
// 职责：提供 CEQ/AEQ 消费与发布 facade，把事件解码、ecode 分类的多 owner route、CI 提交与
//  CEQE/AEQE 发布委托给共享 queue-data engine。
// 依赖：rdma_queue_data_engine、rdma_queue_event_result 及 CEQ/AEQ codec/adapter 契约。
// 所有权与生命周期：facade 借用共享 runtime 与 router；不拥有事件 ring、mapping 或外部后端。

class rdma_eq_engine extends rdma_queue_facade;
  `rdma_object_utils(rdma_eq_engine)

  // 功能：创建未配置的 EQ facade，不分配 ring 或中断资源。
  // 输入/输出及副作用：name 传给基类（类型名 EQ）。
  // 失败/边界：configure 前调用任一 poll/publish 入口返回 INVALID_STATE。
  function new(string name = "rdma_eq_engine");
    super.new(name, "EQ");
  endfunction

  // 功能：轮询 CEQ，把事件解码、CQ route 与 CI commit 交给共享 engine，按超时策略等待条目。
  // 输入/输出及副作用：ceq_h 输入；result/status 输出；把 handle 与 operation_timeout 交给 delegate。
  // 失败/边界：未配置、authority 失活/漂移、CEQ 未登记、owner 不符、超时或 CI doorbell 失败时不发布事件；
  //  合法 CQ route miss 可成功消费且 result=null；delegate null status 归一为 INVALID_STATE。
  task poll_ceqe(
    rdma_handle ceq_h,
    output rdma_queue_event_result result,
    output rdma_status status
  );
    result = null;
    status = validate_operation_authority("EQ CEQ poll");
    if (!status.ok())
      return;

    delegate.poll_ceqe(ceq_h, operation_timeout, result, status);
    status = normalize_delegate_status(status, "poll_ceqe");
    if (!status.ok())
      result = null;
  endtask

  // 功能：轮询 AEQ，把异常事件解码、按 ecode class 解析 owner route 与 CI commit 交给共享 engine。
  // 输入/输出及副作用：aeq_h 输入；result/status 输出；把 handle 与 operation_timeout 交给 delegate。
  // 失败/边界：未配置、authority 失活/漂移、AEQ 未登记、handle kind 错误、owner/identity 失配、超时或 CI
  //  提交失败时不发布结果；CQ-flush 任一路命中可返回 partial result，零路由事件可成功消费且
  //  result=null；delegate null status 归一为 INVALID_STATE。
  task poll_aeqe(
    rdma_handle aeq_h,
    output rdma_queue_event_result result,
    output rdma_status status
  );
    result = null;
    status = validate_operation_authority("EQ AEQ poll");
    if (!status.ok())
      return;

    delegate.poll_aeqe(aeq_h, operation_timeout, result, status);
    status = normalize_delegate_status(status, "poll_aeqe");
    if (!status.ok())
      result = null;
  endtask

  // 功能：把已通过 CQ authority 校验的 CEQE 发布请求转交共享 engine，保持 CEQ backing 与 producer
  //  runtime 单一所有者。
  // 输入/输出及副作用：ceq_h、model 输入；result/status 输出；facade 不 clone、不改 runtime/backing。
  // 失败/边界：未配置、binding 缺失/非 ACTIVE 返回 INVALID_STATE；UID/generation/epoch 漂移返回
  //  STALE_GENERATION；其余 delegate 失败原样保留，null status 归一为 INVALID_STATE；失败清空 result。
  task publish_ceqe(
    rdma_handle ceq_h,
    rdma_hw_ceqe_model model,
    output rdma_queue_device_publish_result result,
    output rdma_status status
  );
    result = null;
    status = validate_operation_authority("EQ CEQE publish");
    if (!status.ok())
      return;

    delegate.publish_ceqe(ceq_h, model, result, status);
    status = normalize_delegate_status(status, "publish_ceqe");
    if (!status.ok())
      result = null;
  endtask

  // 功能：legacy AEQE 发布入口（无 secondary authority），把按 ecode class 绑定 primary owner 的普通
  //  请求转交共享 engine，facade 不自行分类、构造 image、占 ring 或改 route。
  // 输入/输出及副作用：aeq_h、model 输入；result/status 输出；result 的 queue_h/image 由 delegate 创建。
  // 失败/边界：未配置、binding 缺失/非 ACTIVE 返回 INVALID_STATE；漂移返回 STALE_GENERATION；CQ-flush 因缺
  //  QP secondary authority 由 delegate 拒绝；其余失败原样保留；null status 归一为 INVALID_STATE；失败清空 result。
  task publish_aeqe(
    rdma_handle aeq_h,
    rdma_hw_aeqe_model model,
    output rdma_queue_device_publish_result result,
    output rdma_status status
  );
    result = null;
    status = validate_operation_authority("EQ AEQE publish");
    if (!status.ok())
      return;

    delegate.publish_aeqe(aeq_h, model, result, status);
    status = normalize_delegate_status(status, "publish_aeqe");
    if (!status.ok())
      result = null;
  endtask

  // 功能：把 CQ-flush 的 CQ primary owner 与显式 QP secondary authority 转交共享 engine；发布要求
  //  两路完整 authority，区别于 poll 时允许的 partial route。
  // 输入/输出及副作用：aeq_h、model、secondary_target_h 输入；result/status 输出；16B image 由 delegate 创建。
  // 失败/边界：未配置、binding 缺失/非 ACTIVE 返回 INVALID_STATE；漂移返回 STALE_GENERATION；authority 不完整
  //  及其他 delegate 失败原样保留，null status 归一为 INVALID_STATE；失败清空 result。
  task publish_aeqe_with_secondary(
    rdma_handle aeq_h,
    rdma_hw_aeqe_model model,
    rdma_handle secondary_target_h,
    output rdma_queue_device_publish_result result,
    output rdma_status status
  );
    result = null;
    status = validate_operation_authority("EQ AEQE secondary publish");
    if (!status.ok())
      return;

    delegate.publish_aeqe_with_secondary(
      aeq_h, model, secondary_target_h, result, status);
    status = normalize_delegate_status(
      status, "publish_aeqe_with_secondary");
    if (!status.ok())
      result = null;
  endtask
endclass
