// 目录：核心执行层 core/rdma_sq_engine.sv，位于队列数据路径的 SQ facade。
// 职责：提供面向发送队列的窄接口，把 post_send 委托给唯一的 rdma_queue_data_engine。
// 依赖：rdma_queue_data_engine 及其 resource/adapter/codec 契约。
// 所有权与生命周期：facade 不拥有 manager、binding、Host-memory、doorbell 或 runtime；
// 这些对象由 Function context/测试 fixture 创建并在上层释放。

// SQ facade 只做入口校验和转发。PI、CI、credit、slot ledger、pending journal
// 全部留在 delegate 中，避免 SQ/RQ/CQ/EQ 各自维护互相漂移的副本。
class rdma_sq_engine extends uvm_object;
  `uvm_object_utils(rdma_sq_engine)

  protected rdma_queue_data_engine delegate;
  // Facade 借用 binding，并冻结配置时的 Function incarnation；不拥有外部
  // binding，post_send 前只验证该 authority 未被 reset 或重绑。
  protected rdma_function_binding authority_binding;
  protected longint unsigned authority_function_uid;
  protected int unsigned authority_generation;
  protected rdma_reset_epoch_t authority_reset_epoch;
  protected time operation_timeout;
  protected bit configured;

  // 功能：创建未配置的 SQ facade，并清空共享 delegate 引用。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回
  //   void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：构造成功不代表可用，必须先通过 configure() 建立完整依赖边界。
  function new(string name = "rdma_sq_engine");
    super.new(name);
    delegate = null;
    authority_binding = null;
    authority_function_uid = 0;
    authority_generation = 0;
    authority_reset_epoch = 0;
    operation_timeout = 0;
    configured = 1'b0;
  endfunction

  // 功能：validate_live_authority 检查 SQ facade 配置时冻结的 Function UID、generation
  //   和 reset epoch 仍与借用 binding 一致，阻止 reset 后继续写 SQE。
  // 输入/输出及副作用：label 仅用于诊断消息；函数只读 binding 和快照字段，不修改
  //   delegate、runtime、cursor 或 backing，返回 rdma_status。
  // 失败/边界：未配置、delegate 或 binding 缺失、binding 失活或校验失败返回对应错误；UID、generation
  //   或 reset epoch 漂移返回 STALE_GENERATION，调用方不得继续提交 WQE。
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

  // 功能：把 SQ facade 绑定到已配置的共享 queue-data engine，并校验所有依赖
  //   是同一组引用。
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
      "SQ");
    if (status == null || !status.ok())
      return status;
    // 中文设计：配置是 one-shot。完整依赖与 authority 校验必须先于该门禁，
    // 这样非法重配保留具体错误，合法重配不会覆盖正在使用的 delegate/timeout。
    if (configured)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "SQ facade is already configured");
    delegate = shared_engine;
    authority_binding = function_binding;
    authority_function_uid = function_binding.function_uid;
    authority_generation = function_binding.generation;
    authority_reset_epoch = function_binding.function_reset_epoch();
    operation_timeout = timeout;
    configured = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：validate_transport 在发送入口验证请求 transport/opcode 与 facade 当前
  //   绑定状态，阻断 RC-only 字段串入 UD/URC。
  // 输入/输出及副作用：request（输入）；返回校验状态，不修改 request、队列游标或外部资源。
  // 失败/边界：未配置、空请求、unsupported transport 或请求自身字段不一致时返回
  //   明确错误；成功不代表已提交 WQE。
  function rdma_status validate_transport(rdma_post_send_req request);
    rdma_status status;
    if (!configured || delegate == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "SQ facade is not configured");
    if (request == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "SQ transport request is null");
    if (!(request.transport inside {
      RDMA_TRANSPORT_RC,
      RDMA_TRANSPORT_UD,
      RDMA_TRANSPORT_URC
    }))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "SQ transport is unsupported");
    status = request.validate();
    if (status == null)
      return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "SQ transport request validation returned null");
    return status;
  endfunction

  // 功能：将发送请求交给共享 engine 执行完整的预检、WQE 写入、doorbell 和
  //   提交流程。
  // 输入/输出及副作用：request（输入）、result/status（输出）；输入 request/image/
  //   cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，
  //   并通过 output 返回结果。
  // 失败/边界：未配置、空请求、跨 Function handle、队列耗尽或 ambiguous MMIO
  //   时原样返回具体错误；authority/request/delegate 返回 null status 时统一返回
  //   INVALID_STATE；delegate 返回非空失败状态时保留其 code/message。任一失败都
  //   清空 result，调用方不会观察到没有成功状态支撑的提交结果。
  task post_send(
    rdma_post_send_req request,
    output rdma_queue_post_result result,
    output rdma_status status
  );
    result = null;
    status = null;
    if (!configured || delegate == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "SQ facade is not configured");
      return;
    end
    status = validate_live_authority("SQ post");

    if (status == null) begin
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "SQ post authority validation returned null");
      return;
    end

    if (!status.ok())
      return;

    status = validate_transport(request);

    if (status == null) begin
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "SQ transport validation returned null status");
      return;
    end

    if (!status.ok())
      return;

    delegate.post_send(request, result, status);

    if (status == null) begin
      result = null;
      status = rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "SQ delegate post_send returned null status");
    end
    else if (!status.ok()) begin
      result = null;
    end
  endtask
endclass
