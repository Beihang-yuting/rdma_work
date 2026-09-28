<!-- 目录：项目根目录；职责：记录 Batch215 outstanding ledger OCC 重构与验证证据。 -->

# Batch215：outstanding ledger registry OCC 提交

## 改动

- `commit_registry_replacement()` 增加可选 `check_snapshot`、`expected_epoch` 和
  `expected_source`，在 guard 内复核 detached candidate 的 freshness。
- `track_outstanding()` 在追加 operation ID 前冻结 registry source/epoch，提交统一走 helper；
  旧 source 或并发 mutation 不会覆盖新 ledger。
- `retire_outstanding()` 同样以 source/epoch 保护删除操作，原有 zero/duplicate/unknown ID
  错误优先级保持不变。

## 验证

- `./scripts/run_vcs53.sh core rdma_resource_manager_test`
  - PROCESS PASS / LOGICAL PASS
  - UVM `INFO=3, WARNING=0, ERROR=0, FATAL=0`
  - 日志：`/tmp/rdma_batch215_resource_manager.log`
- `python3 tools/check_changed_sv_style.py --base HEAD`：PASS
- `git diff --check HEAD`：PASS

## 未关闭边界

其它 manager 外部写回、allocator/registry 跨线程或跨进程完整互斥、SRQ 全生命周期、跨
queue/engine 原子性、SQD/SQE drain/flush、legacy descriptor、PCIe ordering/error/backpressure、
Phase-1C F2 whole-plan 与最终 ownership 审计继续保持 OPEN。
