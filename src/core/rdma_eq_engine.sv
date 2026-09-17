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
  // 失败/边界：未配置/缺少 binding、binding 失活或校验失败返回 INVALID_STATE/原错误；
  //   UID、generation 或 reset epoch 漂移返回 STALE_GENERATION，调用方不得继续 doorbell。
  protected function rdma_status validate_live_authority(string label);
    rdma_status status;

    if (!configured || delegate == null || authority_binding == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               {label, " facade is not configured"});
    if (authority_binding.function_uid != authority_function_uid ||
        authority_binding.generation != authority_generation ||
        authority_binding.function_reset_epoch() != authority_reset_epoch)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               {label, " Function authority is stale"});
    if (authority_binding.state != RDMA_BIND_ACTIVE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               {label, " Function binding is not ACTIVE"});
    status = authority_binding.validate();
    if (status == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               {label, " binding validation returned null"});
    if (!status.ok())
      return status;
    return rdma_status::success();
  endfunction

  // 功能：绑定共享 queue-data engine，并校验 EQ facade 与 delegate 使用同一组
  //   Function/后端依赖。
  // 输入/输出及副作用：resource_manager、function_binding、memory、scheduler、
  //   codecs、timeout 和 shared_engine 为输入；调用方必须先完成输入对象的空值、
  //   authority 和 generation 校验；成功时更新本对象配置/状态并保存非拥有引用，
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
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "EQ Function binding validation returned null");
    if (!status.ok())
      return status;
    if (function_binding.state != RDMA_BIND_ACTIVE)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "EQ Function binding is not ACTIVE");
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

  // 功能：轮询 CEQ，将事件解码、CQ route 和 CI commit 交给共享 engine，并按
  //   超时策略等待条目出现。
  // 输入/输出及副作用：ceq_h（输入）、result/status（输出）；poll_ceqe 驱动
  //   下游事务，并写入 result/status；函数无直接返回值，不取得调用方资源所有权。
  // 失败/边界：CEQ 未登记、owner 不匹配、CI doorbell 失败或代际过期时不发布
  //   事件；delegate 返回 null status 时统一返回 INVALID_STATE，非空失败状态保留
  //   原 code/message；任一失败都清空 result。
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
    status = validate_live_authority("EQ CEQ poll");

    if (status == null) begin
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "EQ CEQ poll authority validation returned null");
      return;
    end

    if (!status.ok())
      return;

    delegate.poll_ceqe(ceq_h, operation_timeout, result, status);

    if (status == null) begin
      result = null;
      status = rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "EQ delegate poll_ceqe returned null status");
    end
    else if (!status.ok()) begin
      result = null;
    end
  endtask

  // 功能：轮询 AEQ，将异常事件解码、按 ecode class 解析 QP/SRQ/CQ/EQ/Function
  //   owner route 及 CI commit 交给共享 engine，并按超时策略等待条目出现。
  // 输入/输出及副作用：aeq_h（输入）、result/status（输出）；poll_aeqe 驱动
  //   下游事务，并写入 result/status；函数无直接返回值，不取得调用方资源所有权。
  // 失败/边界：AEQ 未登记、错误 handle kind、owner/identity 失配或 CI 提交失败
  //   时不发布结果；CQ-flush 的 CQ/QP 任一路命中可返回 partial result，
  //   零路由事件仍可被消费但 result 为 null；delegate 返回 null status 时统一返回
  //   INVALID_STATE，非空失败状态保留原 code/message，任一失败都清空 result。
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
    status = validate_live_authority("EQ AEQ poll");

    if (status == null) begin
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "EQ AEQ poll authority validation returned null");
      return;
    end

    if (!status.ok())
      return;

    delegate.poll_aeqe(aeq_h, operation_timeout, result, status);

    if (status == null) begin
      result = null;
      status = rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "EQ delegate poll_aeqe returned null status");
    end
    else if (!status.ok()) begin
      result = null;
    end
  endtask

  // 功能：publish_ceqe 将已经通过 CQ authority 校验的 CEQE 发布请求透明转交
  //   给共享 queue-data engine，保持 CEQ backing 与 producer runtime 单一所有者。
  // 输入/输出及副作用：ceq_h、model 为输入，result/status 为输出；facade 既不
  //   clone result/image，也不修改 CEQ/CQ runtime 或 backing，只传播 delegate 输出。
  // 失败/边界：未 configure 或 delegate 缺失返回 INVALID_STATE 且 result 为 null；
  //   CQ route、PI、polarity、full、codec/recovery 的非空失败状态原样保留；
  //   delegate 返回 null status 时统一返回 INVALID_STATE；任一失败都清空 result。
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
    status = validate_live_authority("EQ CEQE publish");

    if (status == null) begin
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "EQ CEQE publish authority validation returned null");
      return;
    end

    if (!status.ok())
      return;

    delegate.publish_ceqe(ceq_h, model, result, status);

    if (status == null) begin
      result = null;
      status = rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "EQ delegate publish_ceqe returned null status");
    end
    else if (!status.ok()) begin
      result = null;
    end
  endtask

  // 功能：publish_aeqe 保留无 secondary caller authority 的 legacy AEQE 入口，将按
  //   ecode class 绑定 QP/SRQ/CQ/EQ/Function primary owner 的普通请求透明转交共享
  //   engine，防止 facade 自行分类事件、构造 image、占用 ring 或改变
  //   target route。
  // 输入/输出及副作用：aeq_h、model 为输入，result/status 为输出；成功 result
  //   的 queue_h/image 仍归 delegate 创建，facade 只借用并返回同一 detached 对象。
  // 失败/边界：未 configure/delegate 空返回 INVALID_STATE；CQ-flush 因 legacy 入口
  //   缺少显式 QP secondary authority 而由 delegate 拒绝；primary owner route、
  //   generation、polarity、满环和编码的非空失败状态保留原 code/message；delegate
  //   返回 null status 时统一返回 INVALID_STATE，任一失败都清空 result。
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
    status = validate_live_authority("EQ AEQE publish");

    if (status == null) begin
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "EQ AEQE publish authority validation returned null");
      return;
    end

    if (!status.ok())
      return;

    delegate.publish_aeqe(aeq_h, model, result, status);

    if (status == null) begin
      result = null;
      status = rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "EQ delegate publish_aeqe returned null status");
    end
    else if (!status.ok()) begin
      result = null;
    end
  endtask

  // 功能：publish_aeqe_with_secondary 将 CQ-flush 的 CQ primary owner 与显式 QP
  //   secondary caller authority 透明转交共享 engine，不在 facade 重复事件分类或
  //   路由解析；发布要求两路完整 authority，区别于 poll 时允许的 partial
  //   route。
  // 输入/输出及副作用：aeq_h、model、secondary_target_h 为输入，result/status
  //   为输出；成功结果及 16B image 由 delegate 创建，facade 不预留槽位或写 backing。
  // 失败/边界：未配置、Function authority 失活/漂移或 delegate 返回 null status
  //   时返回 INVALID_STATE/STALE_GENERATION 并清空 result；显式非成功状态原样保留。
  task publish_aeqe_with_secondary(
    rdma_handle aeq_h,
    rdma_hw_aeqe_model model,
    rdma_handle secondary_target_h,
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
    status = validate_live_authority("EQ AEQE secondary publish");

    if (status == null) begin
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "EQ AEQE secondary publish authority validation returned null");
      return;
    end

    if (!status.ok())
      return;

    delegate.publish_aeqe_with_secondary(
      aeq_h, model, secondary_target_h, result, status);

    if (status == null) begin
      result = null;
      status = rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "EQ delegate publish_aeqe_with_secondary returned null status");
    end
    else if (!status.ok()) begin
      result = null;
    end
  endtask
endclass
