# Batch206：queue recovery OCC flush transaction seam

日期：2026-09-25

## 目标

继续收缩 `rdma_queue_lifecycle_executor::recover_locked()` 中 SRQ pre-delete barrier
和 post-delete OCC retry 的重复执行骨架，同时保留 recovery ledger 对 ambiguity、
`flush_complete`、持久化和终止状态的唯一写入权。

## 实现

- 新增受保护 task `execute_recovery_flush_step()`，统一 detached target 的 descriptor
  构造、单次 `execute_queue_command()`、generation fence 和
  `manager.record_queue_flush_complete()`。
- task 返回 `execute_failed` 与 `progress_failed` 两个阶段证据，caller 继续区分
  descriptor 构造失败、CMQ/fence 失败和 manager progress 失败的原有诊断路径。
- `recover_locked()` 仍负责 ambiguous ticket、role、hardware presence、
  `queue_plan.flush_complete`、`recovery_complete_step()`、持久化和下一阶段 barrier；
  helper 不持有 recovery/registry ledger，也不修改 target 的 completion 标志。
- pre-delete 与 post-delete 两个循环分别保留原有 retry 顺序、错误文案、恢复结果和
  `RDMA_QUEUE_AMBIG_OCC_FLUSH` 证据。

## 验证

- `SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_lifecycle_test`：PROCESS/LOGICAL
  PASS，UVM `WARNING/ERROR/FATAL=0/0/0`。
- `SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_recovery_test`：PROCESS/LOGICAL
  PASS，UVM `WARNING/ERROR/FATAL=0/0/0`。
- `python3 tools/check_changed_sv_style.py --base HEAD`：PASS。
- `python3 tools/check_queue_lifecycle.py`：PASS。
- `git diff --check HEAD`：PASS。

本批只关闭 queue recovery OCC flush 的重复事务 seam；SRQ 完整 create/post/recovery/
destroy 组合、allocator/registry 并发、跨 queue/engine 全局原子性、SQD/SQE drain/flush、
legacy descriptor、PCIe ordering/error/backpressure、manager 外部调用窗口、Phase-1C F2
whole-plan 和最终 ownership 审计继续保持 OPEN，项目级计划仍为 `active`。
