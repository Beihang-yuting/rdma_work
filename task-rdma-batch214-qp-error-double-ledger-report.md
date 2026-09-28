<!-- 目录：项目根目录；职责：记录 Batch214 QP ERROR/programmed 双账本原子提交与验证证据。 -->

# Batch214：QP ERROR/programmed 双账本原子提交

## 改动

- 新增 `commit_resource_recovery_replacement()`，统一 resource replacement、recovery
  replacement/clear、staged clear 的最终 commit；外部 projection 不持有 mutation guard。
- `mark_qp_error()` 现在在完成 authority、ambiguity、plan 和 recovery schema 检查后冻结
  source/epoch，并以一个 helper 同步发布 ERROR resource 与 recovery record。
- `commit_qp_programmed()` 的普通 ACTIVE replacement 和 ERROR reconciliation 统一走同一
  helper；reconciliation 清 recovery 与 ACTIVE replacement 成为不可分割的提交。

## 验证

- `./scripts/run_vcs53.sh core rdma_resource_manager_test`：PROCESS/LOGICAL PASS，UVM
  `INFO=3, WARNING=0, ERROR=0, FATAL=0`；日志：`/tmp/rdma_batch214_resource_manager.log`
- `./scripts/run_vcs53.sh core rdma_qp_lifecycle_test`：PROCESS/LOGICAL PASS，UVM
  `INFO=3, WARNING=0, ERROR=0, FATAL=0`；日志：`/tmp/rdma_batch214_qp_lifecycle.log`
- `./scripts/run_vcs53.sh core rdma_qp_recovery_test`：PROCESS/LOGICAL PASS，UVM
  `INFO=3, WARNING=0, ERROR=0, FATAL=0`；日志：`/tmp/rdma_batch214_qp_recovery.log`
- `python3 tools/check_changed_sv_style.py --base HEAD`：PASS
- `git diff --check HEAD`：PASS

## 未关闭边界

allocator/registry 跨线程或跨进程完整互斥、manager 其它外部调用窗口、SRQ 全生命周期、跨
queue/engine 原子性、SQD/SQE drain/flush、legacy descriptor、PCIe ordering/error/backpressure、
Phase-1C F2 whole-plan 与最终 ownership 审计继续保持 OPEN。
