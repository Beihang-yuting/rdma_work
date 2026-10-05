// 目录：核心执行层 core/rdma_cmq_ambiguity_policy.sv。
// 职责：集中 CMQ command outcome “证据不足即 ambiguous”的纯值判定，供队列与 QP lifecycle executor 复用。
// 依赖：rdma_status、rdma_cmq_ticket、rdma_cmq_completion 的只读字段；不依赖 adapter、engine 账本、锁或恢复账本。
// 所有权与生命周期：只读调用方传入的值；不保存引用、不分配对象、不接管外部资源生命周期。

// 设计说明：queue 与 QP 的历史契约都要求 timeout/reset 或缺失证据默认保守地进入 ambiguous，但对“无 ticket/
//  completion 的明确成功”与“completion 壳存在但缺 status 时 no-submit 证明是否足够”有业务差异；policy 把
//  这两项作为显式布尔输入，公共层只做证据分类，adapter 取证与后续恢复由 caller 负责。

class rdma_cmq_ambiguity_policy;
  // 功能：根据 status、ticket、completion 与 no-submit 证明，判断 command outcome 是否仍无法证明硬件提交结果。
  // 输入/输出及副作用：证据只读；definitive_no_submit 表示 adapter 证明未越过提交边界；null_success_is_definitive、
  //  missing_completion_shell_is_definitive、ticket_missing_is_ambiguous 为 queue/QP 的业务差异开关；返回 bit。
  // 失败/边界：status 为空、status 或 completion.status 为 TIMEOUT/RESET_CANCELLED、缺证据且无适用 no-submit
  //  证明时返回 1；仅显式允许的无证据成功或 no-submit 失败返回 0。
  static function automatic bit is_ambiguous(
    input rdma_status status,
    input rdma_cmq_ticket ticket,
    input rdma_cmq_completion completion,
    input bit definitive_no_submit,
    input bit null_success_is_definitive,
    input bit missing_completion_shell_is_definitive,
    input bit ticket_missing_is_ambiguous
  );
    if (status == null)
      return 1'b1;
    if (status.code inside {RDMA_SC_TIMEOUT, RDMA_SC_RESET_CANCELLED})
      return 1'b1;
    if (completion != null && completion.status != null &&
        completion.status.code inside {RDMA_SC_TIMEOUT,
                                       RDMA_SC_RESET_CANCELLED})
      return 1'b1;
    if (ticket == null && ticket_missing_is_ambiguous &&
        completion != null && completion.status != null)
      return 1'b1;

    if (completion == null || completion.status == null) begin
      if (status.ok() && ticket == null && completion == null &&
          null_success_is_definitive)
        return 1'b0;
      if (!status.ok() && ticket == null && definitive_no_submit &&
          (completion == null || missing_completion_shell_is_definitive))
        return 1'b0;
      return 1'b1;
    end

    return 1'b0;
  endfunction
endclass
