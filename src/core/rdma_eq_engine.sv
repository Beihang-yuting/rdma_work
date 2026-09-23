// 目录：核心执行层 core/rdma_eq_engine.sv，位于事件队列数据路径的 EQ facade。
// 职责：提供 CEQ/AEQ 消费与发布 facade，把事件解码、ecode-classified
//   multi-owner route、CI 提交及 CEQE/AEQE legacy/sibling 发布委托给共享
//   queue-data engine。
// 依赖：rdma_queue_data_engine、rdma_queue_event_result 及 CEQ/AEQ codec/adapter 契约。
// 所有权与生命周期：facade 借用共享 runtime 和 router；不拥有事件 ring、mapping 或外部后端。

class rdma_eq_engine extends uvm_object;
  `uvm_object_utils(rdma_eq_engine)

  protected rdma_queue_data_engine delegate;
  // Facade 借用 binding，并冻结配置时的 Function incarnation；不持有或释放
  // binding 的生命周期，轮询前只用它检测 reset/代际漂移。
  protected rdma_function_binding authority_binding;
  protected longint unsigned authority_function_uid;
  protected int unsigned authority_generation;
  protected rdma_reset_epoch_t authority_reset_epoch;
  protected time operation_timeout;
  protected bit configured;

  // 功能：创建未配置的 EQ facade，不分配 CEQ/AEQ ring 或中断资源。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回
  //   void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：configure 前调用任一 poll/publish 入口都返回 INVALID_STATE，
  //   且不消费或发布 event。
  function new(string name = "rdma_eq_engine");
    super.new(name);
    delegate = null;
    authority_binding = null;
    authority_function_uid = 0;
    authority_generation = 0;
    authority_reset_epoch = 0;
    operation_timeout = 0;
    configured = 1'b0;
  endfunction

  // 功能：validate_live_authority 检查 EQ facade 配置时冻结的 Function UID、generation
  //   和 reset epoch 仍与借用 binding 一致，阻止 reset 后继续消费或发布事件。
  // 输入/输出及副作用：label 仅用于诊断消息；函数只读 binding 与快照字段，不修改
  //   delegate、event runtime、cursor 或 backing，返回 rdma_status。
  // 失败/边界：未配置、delegate 或 binding 缺失、binding 失活或校验失败返回 INVALID_STATE/原错误；
  //   UID、generation 或 reset epoch 漂移返回 STALE_GENERATION，调用方不得继续 doorbell。
  protected function rdma_status validate_live_authority(string label);
    return rdma_validate_live_authority(
      configured,
      delegate != null,
      authority_binding,
      authority_function_uid,
      authority_generation,
      authority_reset_epoch,
      label);
  endfunction

  // 功能：绑定共享 queue-data engine，并校验 EQ facade 与 delegate 使用同一组
  //   Function/后端依赖。
  // 输入/输出及副作用：resource_manager、function_binding、memory、scheduler、
  //   codecs、timeout 和 shared_engine 为输入；函数先通过共用 admission helper
  //   完成依赖、authority 和 ACTIVE 校验，成功时更新本对象配置/状态并保存非拥有引用，
  //   返回 rdma_status。
  // 失败/边界：空依赖、重复登记、状态或 generation/authority 校验失败时返回错误；
  //   失败时保留旧配置。
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
    status = rdma_validate_queue_facade_configuration(
      resource_manager,
      function_binding,
      memory,
      scheduler,
      codecs,
      timeout,
      shared_engine,
      "EQ");
    if (status == null || !status.ok())
      return status;
    // 中文设计：配置是 one-shot。完整依赖与 authority 校验必须先于该门禁，
    // 这样非法重配保留具体错误，合法重配也不会覆盖正在使用的 delegate/timeout。
    if (configured)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "EQ facade is already configured");
    delegate = shared_engine;
    authority_binding = function_binding;
    authority_function_uid = function_binding.function_uid;
    authority_generation = function_binding.generation;
    authority_reset_epoch = function_binding.function_reset_epoch();
    operation_timeout = timeout;
    configured = 1'b1;
    return rdma_status::success();
  endfunction

  // 设计说明：五个 EQ facade 入口的 delegate 签名和业务副作用不同，但共享同一
  // 配置/Function authority 拒绝顺序以及 null-status 边界。这里仅提取两个无 I/O
  // helper；public task 仍显式调用各自 delegate，使 CEQ/AEQ consumer、legacy
  // producer 和 secondary-authority producer 的差异在入口处直接可见。

  // 功能：validate_operation_authority 按 EQ facade 原有顺序执行配置门禁和 live
  //   Function authority 校验，并保证调用方总能获得非 null status。
  // 输入/输出及副作用：label 为当前 poll/publish 入口的诊断前缀；函数只读
  //   configured、delegate 与冻结 authority，不修改 runtime、backing、cursor 或结果。
  // 失败/边界：未配置或 delegate 缺失返回固定 INVALID_STATE；binding 缺失/非 ACTIVE
  //   返回 INVALID_STATE，UID、generation 或 reset epoch 漂移返回 STALE_GENERATION，
  //   binding.validate() 的非空失败原样返回；authority 校验异常返回 null 时按 label
  //   归一化为 INVALID_STATE，其他非空成功/失败 status 对象原样返回。
  protected function rdma_status validate_operation_authority(string label);
    rdma_status status;

    if (!configured || delegate == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "EQ facade is not configured");

    status = validate_live_authority(label);
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {label, " authority validation returned null"});
    return status;
  endfunction

  // 功能：normalize_delegate_status 将 EQ delegate 的 null status 转换为带入口名的
  //   INVALID_STATE，同时保留所有非 null 成功或失败对象。
  // 输入/输出及副作用：candidate 是 delegate 输出 status，operation_name 是固定的
  //   delegate task 名；函数返回归一化 status，不修改 result、delegate 或队列状态。
  // 失败/边界：candidate 为 null 时新建 INVALID_STATE；非 null 时保持对象、code 和
  //   message 不变。result 是否清空由 typed public wrapper 根据返回状态显式决定。
  protected function rdma_status normalize_delegate_status(
    rdma_status candidate,
    string operation_name
  );
    if (candidate == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {"EQ delegate ", operation_name, " returned null status"});
    return candidate;
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
