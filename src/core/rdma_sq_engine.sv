// 目录：核心执行层 core/rdma_sq_engine.sv，位于队列数据路径的 SQ facade。
// 职责：提供面向发送队列的窄接口，把 post_send 委托给唯一的 rdma_queue_data_engine。
// 依赖：rdma_queue_data_engine 及其 resource/adapter/codec 契约。
// 所有权与生命周期：facade 不拥有 manager、binding、Host-memory、doorbell 或 runtime；
//       这些对象由 Function context/测试 fixture 创建并在上层释放。

// SQ facade 只做入口校验和转发。PI、CI、credit、slot ledger、pending journal
// 全部留在 delegate 中，避免 SQ/RQ/CQ/EQ 各自维护互相漂移的副本。
class rdma_sq_engine extends uvm_object;
  `uvm_object_utils(rdma_sq_engine)

  protected rdma_queue_data_engine delegate;
  protected time operation_timeout;
  protected bit configured;

  // 功能：创建未配置的 SQ facade，并清空共享 delegate 引用。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：构造成功不代表可用，必须先通过 configure() 建立完整依赖边界。
  function new(string name = "rdma_sq_engine");
    super.new(name);
    delegate = null;
    operation_timeout = 0;
    configured = 1'b0;
  endfunction

  // 功能：把 SQ facade 绑定到已配置的共享 queue-data engine，并校验所有依赖是同一组引用。
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
                               "SQ facade configuration dependency is null/zero");
    if (shared_engine.manager != resource_manager ||
        shared_engine.binding != function_binding ||
        shared_engine.host_mem != memory ||
        shared_engine.doorbells != scheduler ||
        shared_engine.registry != codecs)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "SQ facade dependencies do not match shared engine");
    status = function_binding.validate();
    if (status == null || !status.ok() || function_binding.state != RDMA_BIND_ACTIVE)
      return status == null ?
        rdma_status::make(RDMA_SC_INVALID_STATE, "SQ Function binding validation returned null") :
        status;
    delegate = shared_engine;
    operation_timeout = timeout;
    configured = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：将发送请求交给共享 engine 执行完整的预检、WQE 写入、doorbell 和提交流程。
  // 输入/输出及副作用：request（输入）、result（输出）、status（输出）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending
  //   journal，并通过 output 返回结果。
  // 失败/边界：未配置、空请求、跨 Function handle、队列耗尽或 ambiguous MMIO 时原样返回 delegate 状态。
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
    delegate.post_send(request, result, status);
  endtask
endclass
