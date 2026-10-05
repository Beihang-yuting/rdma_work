# Batch195：queue progress detached candidate 收束

## 目标

继续压缩 `rdma_resource_manager` 的 queue flush/cleanup/context progress 事务边界，避免
调用方分别传递 `key`、authoritative snapshot、recovery snapshot 和 `has_recovery` 时发生
错配；不改变 registry、recovery record 或外部 backing 的所有权。

## 实现

- 在 `src/core/rdma_resource_transaction_models.sv` 新增
  `rdma_queue_progress_candidate`，只保存 detached `key`、`resource_copy`、可选
  `recovery_copy` 和 `has_recovery`。
- `valid()` 只做 shape 门禁，`clear()` 只断开 transient 引用；candidate 不读取或复制
  manager registry、锁、recovery ledger，也不执行提交/回滚。
- `rdma_resource_manager::queue_progress_snapshots()` 改为输出 candidate，并在所有拒绝
  分支清除半成品；`commit_queue_progress()` 改为消费单一 candidate，先验证两份快照，再
  在同一 publication 点写回 registry/recovery_records。
- `record_queue_flush_complete()`、`record_queue_cleanup_complete()` 和
  `record_queue_context_cleanup_complete()` 复用 candidate，保留原有 role cardinality、
  recovery authority、SRFQ flush predecessor、错误优先级和提交顺序。
- `rdma_resource_manager_test` 增加 default/partial/complete/clear candidate shape 矩阵。

## 验证

- `SSHPASS=123 scripts/run_vcs53.sh core rdma_resource_manager_test`：PROCESS/LOGICAL PASS，
  UVM WARNING/ERROR/FATAL `0/0/0`。
- `SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_lifecycle_test`：PROCESS/LOGICAL PASS，
  UVM WARNING/ERROR/FATAL `0/0/0`。
- `SSHPASS=123 scripts/run_vcs53.sh core rdma_qp_lifecycle_test`：PROCESS/LOGICAL PASS，
  UVM WARNING/ERROR/FATAL `0/0/0`。
- `SSHPASS=123 scripts/run_vcs53.sh core rdma_control_plane_test`：PROCESS/LOGICAL PASS，
  UVM WARNING/ERROR/FATAL `0/0/0`。
- `git diff --check`：PASS。
- `python3 tools/check_changed_sv_style.py --base HEAD`：PASS。

## 边界

本批只收束 queue progress detached 参数边界，不宣称关闭 registry 跨线程/跨进程互斥、
manager 外部调用窗口补偿、SRQ 全生命周期、跨 queue/engine 并发、Phase-1C F2 whole-plan
或最终 ownership 审计；项目级结构重构计划继续保持 `active`。
