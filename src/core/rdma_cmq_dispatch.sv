// 目录：核心执行层 core/rdma_cmq_dispatch.sv。
// 职责：为控制面、队列生命周期与 QP 生命周期 executor 提供统一的 CMQ 调用入口：
//   门禁 → 一次 execute_observed → 拆出 ticket/completion/status 与“确定未提交”证明。
// 依赖：依赖 rdma_cmq_port、rdma_cmq_execution_result 与 rdma_cmq_result_no_submit_proven。
// 所有权与生命周期：只在调用期间持有输出引用；命令与结果对象归调用方。

// 设计说明：null status 归一化、completion 完整性、generation fence 与歧义分类仍留在各
//   owner；这里不改写后端返回的 status 对象（保持 identity），只负责一次调用与拆包。

// 功能：执行一条 CMQ 命令并拆出 ticket/completion/status 与 no_submit 证明。
// 输入/输出及副作用：cmq/command 为非拥有输入；四个输出每次调用先清空；仅在门禁通过时
//   调用一次 cmq.execute_observed。
// 失败/边界：cmq 为空返回 INVALID_STATE，command 为空返回 INVALID_ARGUMENT（两者均不调用端口、
//   no_submit=0）；端口返回 null result 时 status 为 INVALID_STATE；后端 null status 原样保留。
task automatic rdma_cmq_dispatch(
    input rdma_cmq_port cmq,
    input rdma_cmq_command_desc command,
    output rdma_cmq_ticket ticket,
    output rdma_cmq_completion completion,
    output rdma_status status,
    output bit no_submit,
    input string unavailable_message,
    input string null_command_message
);
  rdma_cmq_execution_result result;

  ticket = null;
  completion = null;
  status = null;
  no_submit = 1'b0;
  if (cmq == null) begin
    status = rdma_status::make(RDMA_SC_INVALID_STATE, unavailable_message);
    return;
  end
  if (command == null) begin
    status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT, null_command_message);
    return;
  end
  cmq.execute_observed(command, result);
  if (result == null) begin
    status = rdma_status::make(RDMA_SC_INVALID_STATE,
                               "CMQ observed execute returned null result");
    return;
  end
  status = result.status;
  ticket = result.ticket;
  completion = result.completion;
  no_submit = rdma_cmq_result_no_submit_proven(result);
endtask
