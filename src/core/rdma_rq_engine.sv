// 目录：核心执行层 core/rdma_rq_engine.sv，位于队列数据路径的 RQ facade。
// 职责：提供面向接收队列的窄接口，把 post_recv 委托给唯一的 rdma_queue_data_engine。
// 依赖：rdma_queue_data_engine 及其 resource/adapter/codec 契约。
// 所有权与生命周期：facade 只借用共享 delegate；runtime、映射和外部后端由上层拥有。

// RQ 与 SQ 共用相同的 runtime authority，但通过 delegate 的 queue kind/handle 校验保持环隔离。
class rdma_rq_engine extends uvm_object;
  `uvm_object_utils(rdma_rq_engine)

  protected rdma_queue_data_engine delegate;
  // Facade 借用 binding，并冻结配置时的 Function incarnation；不拥有外部
  // binding，post_recv 前只验证该 authority 未被 reset 或重绑。
  protected rdma_function_binding authority_binding;
  protected longint unsigned authority_function_uid;
  protected int unsigned authority_generation;
  protected rdma_reset_epoch_t authority_reset_epoch;
  protected time operation_timeout;
  protected bit configured;

  // 功能：创建未配置的 RQ facade，不分配接收队列或 Host-memory。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回
  //   void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：调用方必须在 post_recv 前完成 configure()，否则返回 INVALID_STATE。
  function new(string name = "rdma_rq_engine");
    super.new(name);
    delegate = null;
    authority_binding = null;
    authority_function_uid = 0;
    authority_generation = 0;
    authority_reset_epoch = 0;
    operation_timeout = 0;
    configured = 1'b0;
  endfunction

  // 功能：validate_live_authority 检查 RQ facade 配置时冻结的 Function UID、generation
  //   和 reset epoch 仍与借用 binding 一致，阻止 reset 后继续写 RQE。
  // 输入/输出及副作用：label 仅用于诊断消息；函数只读 binding 和快照字段，不修改
  //   delegate、runtime、cursor 或 backing，返回 rdma_status。
  // 失败/边界：未配置/缺少 binding、binding 失活或校验失败返回对应错误；UID、generation
  //   或 reset epoch 漂移返回 STALE_GENERATION，调用方不得继续提交 WQE。
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

  // 功能：绑定已配置的共享 queue-data engine，并校验 RQ facade 使用的依赖
  //   没有被替换。
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
                               "RQ facade configuration dependency is null/zero");
    if (shared_engine.manager != resource_manager ||
        shared_engine.binding != function_binding ||
        shared_engine.host_mem != memory ||
        shared_engine.doorbells != scheduler ||
        shared_engine.registry != codecs)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "RQ facade dependencies do not match shared engine");
    status = function_binding.validate();
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "RQ Function binding validation returned null");
    if (!status.ok())
      return status;
    if (function_binding.state != RDMA_BIND_ACTIVE)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "RQ Function binding is not ACTIVE");
    // 中文设计：配置是 one-shot。完整依赖与 authority 校验必须先于该门禁，
    // 这样非法重配保留具体错误，合法重配不会覆盖正在使用的 delegate/timeout。
    if (configured)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "RQ facade is already configured");
    delegate = shared_engine;
    authority_binding = function_binding;
    authority_function_uid = function_binding.function_uid;
    authority_generation = function_binding.generation;
    authority_reset_epoch = function_binding.function_reset_epoch();
    operation_timeout = timeout;
    configured = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：将接收请求交给共享 engine，执行 RQ 槽位预留、RQE 写入、producer
  //   doorbell 和提交。
  // 输入/输出及副作用：request（输入）、result/status（输出）；输入 request/image/
  //   cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，
  //   并通过 output 返回结果。
  // 失败/边界：未配置、空请求、错误 Function/队列类型、槽位耗尽或 MMIO 不确定
  //   时不发布结果；authority/delegate 返回 null status 时统一返回 INVALID_STATE；
  //   delegate 返回非空失败状态时保留其 code/message。任一失败都清空 result，
  //   调用方不会观察到没有成功状态支撑的提交结果。
  task post_recv(
    rdma_post_recv_req request,
    output rdma_queue_post_result result,
    output rdma_status status
  );
    result = null;
    status = null;
    if (!configured || delegate == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "RQ facade is not configured");
      return;
    end
    status = validate_live_authority("RQ post");

    if (status == null) begin
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "RQ post authority validation returned null");
      return;
    end

    if (!status.ok())
      return;

    delegate.post_recv(request, result, status);

    if (status == null) begin
      result = null;
      status = rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "RQ delegate post_recv returned null status");
    end
    else if (!status.ok()) begin
      result = null;
    end
  endtask
endclass
