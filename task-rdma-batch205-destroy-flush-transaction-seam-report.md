# Batch205：queue destroy flush transaction seam

日期：2026-09-25

## 目标

收束 `src/core/rdma_queue_lifecycle_executor.sv` 中 `destroy_locked()` 对 SRQ 前置
OCC flush 与 CQ/CEQ/AEQ 删除后 OCC flush 的重复执行骨架。两条路径都必须保持
`build_flush_command → 单次 legacy CMQ execute → live binding fence →
record_queue_flush_complete` 的既有顺序，因此本批只提取事务边界，不改变 queue
policy、recipe、恢复账本或外部 backing 所有权。

## 实现

- 新增受保护 task `execute_destroy_flush_step()`。
- task 只接收已通过 recipe/cardinality 校验的 detached `rdma_queue_flush_target`
  和 queue handle；不保存 plan、registry、recovery ledger、lock 或 backing 引用。
- task 统一初始化 `ticket`、`completion`、`ambiguous`、`completed`，归一化 descriptor/
  CMQ/fence/manager 的 null/失败状态，并在 completion status 为 OK 时提交 role progress。
- `destroy_locked()` 的 delete-before-flush 和 flush-before-delete 两个循环均复用该 task；
  `ambiguous_op`、`hardware_absent`、`completed_steps` 以及 recovery 分支仍由 caller
  保持原有决策。

## 验证

- `SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_lifecycle_test`：PROCESS PASS、
  LOGICAL PASS，UVM `WARNING/ERROR/FATAL=0/0/0`。
- `python3 tools/check_changed_sv_style.py --base HEAD`：PASS。
- `python3 tools/check_queue_lifecycle.py`：PASS。
- `git diff --check HEAD`：PASS。

本批只关闭 queue destroy OCC flush 的重复事务 seam；SRQ 完整 create/post/recovery/
destroy 组合、跨 queue/engine 并发、SQD/SQE drain/flush、legacy descriptor、外部
ordering/error/backpressure、manager 外部调用窗口、Phase-1C F2 whole-plan 和最终
ownership 审计继续保持 OPEN，项目级计划仍为 `active`。
