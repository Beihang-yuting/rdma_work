// 目录：核心执行层 core/rdma_cmq_port.sv。
// 职责：定义控制面/队列/QP executor 使用的 CMQ 端口抽象：observed 执行与 ticket 对账。
// 依赖：依赖 rdma_cmq_command_desc、rdma_cmq_execution_result、rdma_cmq_ticket 等 CMQ 值模型。
// 所有权与生命周期：端口不拥有命令；返回的 result/completion 由调用方持有。

// 设计说明：端口只暴露 execute_observed。返回的 rdma_cmq_execution_result 同时携带
//   status/ticket/completion 与 submission/attempt effect，调用方用
//   rdma_cmq_result_no_submit_proven() 判定“确定未提交”，不再依赖端口上的
//   “最近一次调用”可变标志。
virtual class rdma_cmq_port extends uvm_object;

  // 功能：构造 CMQ 端口。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无。
  function new(string name = "rdma_cmq_port");
    super.new(name);
  endfunction

  // 功能：提交一条 CMQ 命令并返回 observed 执行结果（子类实现）。
  // 输入/输出及副作用：command 为非拥有输入；result 输出新建结果，包含 status、ticket、
  //   completion、effect 与恢复要求。
  // 失败/边界：result 不得为 null；提交前拒绝须标记 PRE_SUBMIT_REJECTED 且不带身份图。
  pure virtual task execute_observed(
    input rdma_cmq_command_desc command,
    output rdma_cmq_execution_result result
  );

  // 功能：按 ticket 对账一次已提交命令的终态（子类实现）。
  // 输入/输出及副作用：ticket 输入；terminal_known/completion/status 输出。
  // 失败/边界：无法确定终态时 terminal_known=0，不推进调用方状态。
  pure virtual task reconcile(
    rdma_cmq_ticket ticket,
    output bit terminal_known,
    output rdma_cmq_completion completion,
    output rdma_status status
  );
endclass
