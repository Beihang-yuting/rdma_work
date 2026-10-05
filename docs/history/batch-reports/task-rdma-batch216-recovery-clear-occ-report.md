<!-- 目录：项目根目录；职责：记录 Batch216 recovery clear OCC 重构与验证证据。 -->

# Batch216：recovery clear OCC 提交

## 改动

- 新增 `clear_recovery_record()`，集中 recovery source/epoch/guard 检查和单条删除。
- `clear_recovery()` 保留 ERROR、absence、release completion 与 recovery-ready 前置，只在
  所有外部观察完成后冻结 source/epoch，再通过 helper 删除 entry。
- 未知 recovery key 仍返回幂等成功；成功删除推进 `publication_epoch`，失败不改变记录。

## 验证

- `./scripts/run_vcs53.sh core rdma_resource_manager_test`
  - PROCESS PASS / LOGICAL PASS
  - UVM `INFO=3, WARNING=0, ERROR=0, FATAL=0`
  - 日志：`/tmp/rdma_batch216_resource_manager.log`
- `python3 tools/check_changed_sv_style.py --base HEAD`：PASS
- `git diff --check HEAD`：PASS

## 未关闭边界

其它 manager 外部写回、allocator/registry 跨线程或跨进程完整互斥、SRQ 全生命周期、跨
queue/engine 原子性、SQD/SQE drain/flush、legacy descriptor、PCIe ordering/error/backpressure、
Phase-1C F2 whole-plan 与最终 ownership 审计继续保持 OPEN。
