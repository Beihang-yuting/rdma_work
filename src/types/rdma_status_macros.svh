// 目录：公共类型层 types/rdma_status_macros.svh。
// 职责：定义事务块内“状态失败即退出”的文本宏，消除逐点重复的 null/ok 判定样板。
// 依赖：展开点所在类必须提供 checked_status(rdma_status, string) 归一化函数。
// 所有权与生命周期：纯文本宏，不持有状态。
`ifndef RDMA_STATUS_MACROS_SVH
`define RDMA_STATUS_MACROS_SVH

// 在 do ... while (0) 事务块内使用：S 为 null 或非 OK 时，按 NULL_MSG 经
//   checked_status 归一化（null→INVALID_STATE，非 null→detached clone）后 break。
`define RDMA_BREAK_IF_FAILED(S, NULL_MSG) \
  if (S == null || !S.ok()) begin \
    S = checked_status(S, NULL_MSG); \
    break; \
  end

`endif
