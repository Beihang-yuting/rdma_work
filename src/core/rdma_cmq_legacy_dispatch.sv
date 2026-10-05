// 目录：核心执行层 core/rdma_cmq_legacy_dispatch.sv。
// 职责：提供 legacy CMQ execute 的无状态输出初始化和参数门禁，供控制面、队列
//   生命周期与 QP 生命周期 executor 共享，避免每个 owner 复制一套原始 dispatch。
// 依赖：依赖 rdma_cmq_port、rdma_cmq_command_desc、rdma_cmq_ticket、
//   rdma_cmq_completion 和 rdma_status；不读取 engine ledger、lock、generation 或
//   recovery 状态，也不推断提交 ambiguity。
// 所有权与生命周期：本文件只持有 task 调用期间的输出引用；CMQ、command、ticket、
//   completion 和 status 的生命周期与所有权仍由调用方及 CMQ adapter 管理。

// 中文设计说明：legacy execute 是旧 executor 必须消费的窄 ABI，这里只做“清空输出 → 门禁 →
// 调用一次 execute”；null status 归一化、completion 完整性、generation fence、ambiguity
// 分类留在各 owner，避免公共 helper 变成第二个事务 owner。

// 功能：legacy CMQ execute 的统一 raw 派发：清空输出、门禁 cmq/command、调用一次 cmq.execute。
// 输入/输出及副作用：ticket/completion/status 先置 null，成功时由 adapter 写入；不复制 command。
// 失败/边界：cmq 空返回 INVALID_STATE，command 空返回 INVALID_ARGUMENT；adapter 的 null status 原样保留；不重试。
task automatic rdma_cmq_dispatch_legacy_raw(
    input rdma_cmq_port cmq,
    input rdma_cmq_command_desc command,
    output rdma_cmq_ticket ticket,
    output rdma_cmq_completion completion,
    output rdma_status status,
    input string unavailable_message,
    input string null_command_message
);
  ticket = null;
  completion = null;
  status = null;
  if (cmq == null) begin
    status = rdma_status::make(RDMA_SC_INVALID_STATE, unavailable_message);
    return;
  end
  if (command == null) begin
    status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT, null_command_message);
    return;
  end
  cmq.execute(command, ticket, completion, status);
endtask
