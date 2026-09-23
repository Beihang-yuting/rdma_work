# Batch149：reservation-only recovery seam 收缩

日期：2026-09-22。工作树：`feature/rdma-cmq-contract-foundation`。

本批继续沿着 Batch148 的 recovery 边界收缩 `recover_queue()`。目标是把“只有
producer reservation、没有可重放 image”的查询、cardinality 判定和 abort/detach
顺序放到一个受保护 task 中；不改变 runtime、Host-memory/PCIe adapter 或
`dpu_common` 的所有权。

## 代码收缩

- 新增 `resolve_reservation_only_recovery()`，集中收集完整 queue incarnation 的
  reservation-only candidate，逐个查询 `query_device_reservation()`，在任何 detach
  之前完成全部 cardinality 判定。
- 唯一 reservation 只允许公开的
  `RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH`；retry 继续以
  `RDMA_SC_RECOVERY_REQUIRED` fail-closed，因为该路径没有可重放 image。
- 多个 valid reservation 返回 `RDMA_SC_INVALID_STATE`，不取消任何 reservation；
  query、detach 或 null-status 失败保留原 evidence。没有 reservation 时 helper 返回
  `handled=0`，由 `recover_queue()` 继续发布“queue has no pending recovery”的原首错。
- `recover_queue()` 的 found==null 分支只保留控制面分派和首错映射；unclaimed
  admission 失败分支仍保留自己的 ACTIVE/cursor 对齐门禁，没有把两类不同 evidence
  错误合并。

该 task 只借用 attachment/runtime 引用；成功 abort 仍通过既有
`detach_recovery_transaction()` 完成 runtime cancel、attachment 删除和 QP link 清理，
不复制 mutable ledger，也不接管外部 mapping/backing 生命周期。

## 既有故障契约覆盖

`check_reservation_only_detach_reconfigure()` 已覆盖本 seam 的完整边界：

- next-cursor factory 失败产生 reservation-only evidence，不能伪造 pending；
- alias 注入造成 multiple matching reservation 时，在任何 detach 前返回
  `RDMA_SC_INVALID_STATE`，reservation 保持不变；
- detach lock 忙、cancel 失败和最终公开 abort 的 status/可重配置顺序保持不变；
- unclaimed admission-failure fixture 继续覆盖另一条带 ACTIVE/cursor guard 的 abort
  分支，避免 helper 抽取弱化其证据约束。

## 验证

所有 VCS 命令均通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 环境执行：

| 入口 | 结果 |
| --- | --- |
| `rdma_queue_data_engine_device_publish_test` | PROCESS/LOGICAL PASS；UVM `INFO=220/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_queue_data_engine_recovery_test` | PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |

静态验证：`git diff --check`、changed-SV style、profile naming、queue lifecycle、
Phase-1A approval 通过；完整 Python unit 回归 292/292。当前源码
`src/core/rdma_queue_data_engine.sv` SHA-256 为
`adf49cd8f64b94fc7f0426637df9869688e76333401f08727ce353f9b679c322`。
全目录中文 function/task 与文件头复审覆盖 185 个 `.sv`、2 个 `.svh`，共 5,461
个 method（`.sv` 5,459、`.svh` 2），0 diagnostics。

本批没有把 focused GREEN 扩大解释为 integration、跨队列并发、SRQ 全生命周期、
legacy descriptor、外部 PCIe error/ordering 组合、engine-level 全局锁或最终
ownership 审计完成；结构重构计划继续保持 `active`。
