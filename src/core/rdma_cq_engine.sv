// 目录：核心执行层 core/rdma_cq_engine.sv，位于队列数据路径的 CQ facade。
// 职责：提供 CQE 消费入口，把解码、route、CI 提交和 WQE release 委托给共享 queue-data engine。
// 依赖：rdma_queue_data_engine、rdma_queue_completion_result 及 CQ codec/adapter 契约。
// 所有权与生命周期：facade 不拥有 CQ runtime、backing mapping 或 doorbell；这些由上层管理。

class rdma_cq_engine extends uvm_object;
  `uvm_object_utils(rdma_cq_engine)

  protected rdma_queue_data_engine delegate;
  protected time operation_timeout;
  protected bit configured;

  // 功能：创建未配置的 CQ facade，不读取或修改任何 CQ backing。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：未 configure 的 facade 调用 poll_cqe 必须返回 INVALID_STATE 且 result 为空。
  function new(string name = "rdma_cq_engine");
    super.new(name);
    delegate = null;
    operation_timeout = 0;
    configured = 1'b0;
  endfunction

  // 功能：绑定共享 queue-data engine，校验 CQ 使用的资源、binding、Host-memory、doorbell 和 codec 引用一致。
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
                               "CQ facade configuration dependency is null/zero");
    if (shared_engine.manager != resource_manager ||
        shared_engine.binding != function_binding ||
        shared_engine.host_mem != memory ||
        shared_engine.doorbells != scheduler ||
        shared_engine.registry != codecs)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CQ facade dependencies do not match shared engine");
    status = function_binding.validate();
    if (status == null || !status.ok() || function_binding.state != RDMA_BIND_ACTIVE)
      return status == null ?
        rdma_status::make(RDMA_SC_INVALID_STATE, "CQ Function binding validation returned null") :
        status;
    delegate = shared_engine;
    operation_timeout = timeout;
    configured = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：轮询一个 CQE，并由共享 engine 完成读/解码/route、CI doorbell、consumer commit 和 WQE release。
  // 输入/输出及副作用：cq_h（输入）、result（输出）、status（输出）；poll_cqe 驱动下游事务，并写入 result、status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：未配置、CQ 未登记、owner/identity 错误或 CI 提交失败时不发布 completion；空环返回 QUEUE_EMPTY。
  task poll_cqe(
    rdma_handle cq_h,
    output rdma_queue_completion_result result,
    output rdma_status status
  );
    result = null;
    status = null;
    if (!configured || delegate == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "CQ facade is not configured");
      return;
    end
    delegate.poll_cqe(cq_h, operation_timeout, result, status);
  endtask

  // 功能：请求共享 queue-data engine 对 CQ ring 做 quiesce、重建和原子切换。
  // 输入输出及副作用：cq_h/new_depth/new_cqe_bytes 为输入；成功时更新共享 attachment geometry。
  // 失败边界：facade 未配置或 delegate 拒绝 quiesce/分配/激活时返回错误且旧 ring 保持有效。
  function rdma_status resize(rdma_handle cq_h, int unsigned new_depth,
                              int unsigned new_cqe_bytes);
    if (!configured || delegate == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "CQ facade is not configured");
    return delegate.resize_cq(cq_h, new_depth, new_cqe_bytes);
  endfunction
endclass
