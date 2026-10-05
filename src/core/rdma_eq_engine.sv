// 目录：核心执行层 core/rdma_eq_engine.sv，位于事件队列数据路径的 EQ facade。
// 职责：提供 CEQ/AEQ 消费与发布 facade，把事件解码、ecode-classified
//   multi-owner route、CI 提交及 CEQE/AEQE legacy/sibling 发布委托给共享
//   queue-data engine。
// 依赖：rdma_queue_data_engine、rdma_queue_event_result 及 CEQ/AEQ codec/adapter 契约。
// 所有权与生命周期：facade 借用共享 runtime 和 router；不拥有事件 ring、mapping 或外部后端。

class rdma_eq_engine extends rdma_queue_facade;
  `uvm_object_utils(rdma_eq_engine)

  // 功能：创建未配置的 EQ facade，不分配 CEQ/AEQ ring 或中断资源。
  // 输入/输出及副作用：name（输入）；默认字段由基类写入。
  // 失败/边界：configure 前调用任一 poll/publish 入口都返回 INVALID_STATE。
  function new(string name = "rdma_eq_engine");
    super.new(name, "EQ");
  endfunction

  // 功能：轮询 CEQ，将事件解码、CQ route 和 CI commit 交给共享 engine，并按
  //   超时策略等待条目出现。
  // 输入/输出及副作用：ceq_h（输入）、result/status（output）；task 把 handle 和
  //   operation_timeout 交给 delegate 驱动下游事务，不取得调用方资源所有权。
  // 失败/边界：未配置、Function authority 失活/漂移、CEQ 未登记、owner 不匹配、
  //   timeout 或 CI doorbell 失败时不发布事件；合法 CQ route miss 可成功消费并返回
  //   result=null；delegate null status 归一化为 INVALID_STATE，其他失败原样保留。
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

  // 功能：轮询 AEQ，将异常事件解码、按 ecode class 解析 QP/SRQ/CQ/EQ/Function
  //   owner route 及 CI commit 交给共享 engine，并按超时策略等待条目出现。
  // 输入/输出及副作用：aeq_h（输入）、result/status（output）；task 把 handle 和
  //   operation_timeout 交给 delegate 驱动下游事务，不取得调用方资源所有权。
  // 失败/边界：未配置、Function authority 失活/漂移、AEQ 未登记、错误 handle kind、
  //   owner/identity 失配、timeout 或 CI 提交失败时不发布结果；CQ-flush 任一路命中
  //   可返回 partial result，零路由事件可成功消费且 result=null；delegate null status
  //   归一化为 INVALID_STATE，其他失败原样保留。
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

  // 功能：publish_ceqe 将已经通过 CQ authority 校验的 CEQE 发布请求透明转交
  //   给共享 queue-data engine，保持 CEQ backing 与 producer runtime 单一所有者。
  // 输入/输出及副作用：ceq_h、model 为输入，result/status 为输出；facade 既不
  //   clone result/image，也不修改 CEQ/CQ runtime 或 backing，只传播 delegate 输出。
  // 失败/边界：未配置、binding 缺失/非 ACTIVE 返回 INVALID_STATE；Function UID、
  //   generation 或 reset epoch 漂移返回 STALE_GENERATION；CQ route、PI、polarity、
  //   full、codec/recovery 的非空失败原样保留；delegate 返回 null status 时统一返回
  //   INVALID_STATE，任一失败都清空 result。
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

  // 功能：publish_aeqe 保留无 secondary caller authority 的 legacy AEQE 入口，将按
  //   ecode class 绑定 QP/SRQ/CQ/EQ/Function primary owner 的普通请求透明转交共享
  //   engine，防止 facade 自行分类事件、构造 image、占用 ring 或改变
  //   target route。
  // 输入/输出及副作用：aeq_h、model 为输入，result/status 为输出；成功 result
  //   的 queue_h/image 仍归 delegate 创建，facade 只借用并返回同一 detached 对象。
  // 失败/边界：未配置、binding 缺失/非 ACTIVE 返回 INVALID_STATE；Function UID、
  //   generation 或 reset epoch 漂移返回 STALE_GENERATION；CQ-flush 因 legacy 入口
  //   缺少显式 QP secondary authority 而由 delegate 拒绝；primary owner route、
  //   polarity、满环和编码的非空失败原样保留；delegate null status 归一化为
  //   INVALID_STATE，任一失败都清空 result。
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

  // 功能：publish_aeqe_with_secondary 将 CQ-flush 的 CQ primary owner 与显式 QP
  //   secondary caller authority 透明转交共享 engine，不在 facade 重复事件分类或
  //   路由解析；发布要求两路完整 authority，区别于 poll 时允许的 partial
  //   route。
  // 输入/输出及副作用：aeq_h、model、secondary_target_h 为输入，result/status
  //   为输出；成功结果及 16B image 由 delegate 创建，facade 不预留槽位或写 backing。
  // 失败/边界：未配置、binding 缺失/非 ACTIVE 返回 INVALID_STATE；Function UID、
  //   generation 或 reset epoch 漂移返回 STALE_GENERATION；primary/secondary authority
  //   不完整及其他 delegate 非空失败原样保留，delegate null status 归一化为
  //   INVALID_STATE；任一失败都清空 result。
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
