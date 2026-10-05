// 目录：核心执行层 core/rdma_sq_engine.sv，位于队列数据路径的 SQ facade。
// 职责：提供面向发送队列的窄接口，把 post_send 委托给唯一的 rdma_queue_data_engine。
// 依赖：rdma_queue_data_engine 及其 resource/adapter/codec 契约。
// 所有权与生命周期：facade 不拥有 manager、binding、Host-memory、doorbell 或 runtime；
// 这些对象由 Function context/测试 fixture 创建并在上层释放。

// SQ facade 只做入口校验和转发。PI、CI、credit、slot ledger、pending journal
// 全部留在 delegate 中，避免 SQ/RQ/CQ/EQ 各自维护互相漂移的副本。
class rdma_sq_engine extends rdma_queue_facade;
  `uvm_object_utils(rdma_sq_engine)

  // 功能：创建未配置的 SQ facade，不分配发送队列或 Host-memory。
  // 输入/输出及副作用：name（输入）；默认字段由基类写入。
  // 失败/边界：调用方必须在 post_send 前完成 configure()，否则返回 INVALID_STATE。
  function new(string name = "rdma_sq_engine");
    super.new(name, "SQ");
  endfunction

  // 功能：在发送入口校验 transport 与请求字段，阻断 RC-only 字段串入 UD/URC。
  // 输入/输出及副作用：request 为输入；只返回状态，不修改队列游标或资源。
  // 失败/边界：未配置、空请求、transport 非 RC/UD/URC 或 request.validate() 失败；成功不代表已提交。
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

  // 功能：校验后把发送请求委托给共享 engine（预检、WQE 写入、doorbell、提交）。
  // 输入/输出及副作用：request 输入；result/status 输出；成功时由 delegate 更新 PI/CI 与 ledger。
  // 失败/边界：授权或 transport 校验失败直接返回；delegate 的 null status 归一为
  //   INVALID_STATE，其余失败保留 code/message；任一失败都清空 result。
  task post_send(
    rdma_post_send_req request,
    output rdma_queue_post_result result,
    output rdma_status status
  );
    result = null;
    status = validate_operation_authority("SQ post");
    if (!status.ok())
      return;
    status = rdma_status::nonnull(validate_transport(request),
                                  "SQ transport validation returned null status");
    if (!status.ok())
      return;
    delegate.post_send(request, result, status);
    status = normalize_delegate_status(status, "post_send");
    if (!status.ok())
      result = null;
  endtask
endclass
