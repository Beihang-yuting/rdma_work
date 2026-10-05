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
