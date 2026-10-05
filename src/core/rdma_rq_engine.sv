// 目录：核心执行层 core/rdma_rq_engine.sv，位于队列数据路径的 RQ facade。
// 职责：提供面向接收队列的窄接口，把 post_recv 委托给唯一的 rdma_queue_data_engine。
// 依赖：rdma_queue_data_engine 及其 resource/adapter/codec 契约。
// 所有权与生命周期：facade 只借用共享 delegate；runtime、映射和外部后端由上层拥有。

// RQ 与 SQ 共用相同的 runtime authority，但通过 delegate 的 queue kind/handle 校验保持环隔离。
class rdma_rq_engine extends rdma_queue_facade;
  `uvm_object_utils(rdma_rq_engine)

  // 功能：创建未配置的 RQ facade，不分配接收队列或 Host-memory。
  // 输入/输出及副作用：name（输入）；默认字段由基类写入。
  // 失败/边界：调用方必须在 post_recv 前完成 configure()，否则返回 INVALID_STATE。
  function new(string name = "rdma_rq_engine");
    super.new(name, "RQ");
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
    status = validate_operation_authority("RQ post");
    if (!status.ok())
      return;
    delegate.post_recv(request, result, status);
    status = normalize_delegate_status(status, "post_recv");
    if (!status.ok())
      result = null;
  endtask
endclass
