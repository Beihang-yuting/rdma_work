// 目录：核心执行层 core/rdma_rq_engine.sv，位于队列数据路径的 RQ facade。
// 职责：提供面向接收队列的窄接口，把 post_recv 委托给唯一的 rdma_queue_data_engine。
// 依赖：rdma_queue_data_engine 及其 resource/adapter/codec 契约。
// 所有权与生命周期：facade 只借用共享 delegate；runtime、映射和外部后端由上层拥有。

// RQ 与 SQ 共用相同的 runtime authority，但通过 delegate 的 queue kind/handle 校验保持环隔离。
class rdma_rq_engine extends uvm_object;
  `uvm_object_utils(rdma_rq_engine)

  protected rdma_queue_data_engine delegate;
  protected time operation_timeout;
  protected bit configured;

  // 功能：创建未配置的 RQ facade，不分配接收队列或 Host-memory。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：调用方必须在 post_recv 前完成 configure()，否则返回 INVALID_STATE。
  function new(string name = "rdma_rq_engine");
    super.new(name);
    delegate = null;
    operation_timeout = 0;
    configured = 1'b0;
  endfunction

  // 功能：绑定已配置的共享 queue-data engine，并校验 RQ facade 使用的依赖没有被替换。
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
                               "RQ facade configuration dependency is null/zero");
    if (shared_engine.manager != resource_manager ||
        shared_engine.binding != function_binding ||
        shared_engine.host_mem != memory ||
        shared_engine.doorbells != scheduler ||
        shared_engine.registry != codecs)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "RQ facade dependencies do not match shared engine");
    status = function_binding.validate();
    if (status == null || !status.ok() || function_binding.state != RDMA_BIND_ACTIVE)
      return status == null ?
        rdma_status::make(RDMA_SC_INVALID_STATE, "RQ Function binding validation returned null") :
        status;
    delegate = shared_engine;
    operation_timeout = timeout;
    configured = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：将接收请求交给共享 engine，执行 RQ 槽位预留、RQE 写入、producer doorbell 和提交。
  // 输入/输出及副作用：request（输入）、result（输出）、status（输出）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending
  //   journal，并通过 output 返回结果。
  // 失败/边界：未配置、空请求、错误 Function/队列类型、槽位耗尽或 MMIO 不确定时不发布结果。
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
    delegate.post_recv(request, result, status);
  endtask
endclass
