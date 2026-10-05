# Batch175：runtime MMIO evidence transition policy

日期：2026-09-24。基线：`feature/rdma-cmq-structural-phase2-batch160`。

## 目标

消除 `rdma_queue_runtime` 普通 status 路径与 noalloc scheduler 路径重复维护的
MMIO evidence 状态迁移表，保证 `NO_SUBMIT` confirmation、`SUCCESS` exactly-once
和 `AMBIGUOUS` 不可重放规则始终一致。

## 实现

- 在 `src/core/rdma_queue_runtime_transaction_models.sv` 新增无状态
  `rdma_queue_mmio_transition_policy::decide()`，只输入当前/目标 evidence、
  device/consumer 方向、device-write-attempted 和 retry confirmation，输出
  transition 是否允许及是否消费 confirmation。
- `project_mmio_evidence_locked()` 与 `record_recovery_failure_noalloc()` 复用
  该 policy；runtime 继续唯一拥有 lock、pending、confirmation、兼容 marker 和
  failure-status 发布，policy 不访问 mutable ledger、Host-memory、MMIO 或外部资源。
- 保留原错误码和拒绝顺序：非法 enum 仍是 `INVALID_ARGUMENT`，合法 enum 但方向/
  evidence 降级仍是 `INVALID_STATE`；consumer `AMBIGUOUS` 仍不可 retry，device
  `NOT_APPLICABLE` 仍要求 backing write 已发生。

## 验证

```text
DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common \
SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_runtime_test
PROCESS PASS logical=rdma_queue_runtime_test physical=rdma_queue_runtime_test
LOGICAL PASS logical=rdma_queue_runtime_test processes=1
UVM warning/error/fatal = 0/0/0
```

本地 `python3 tools/check_changed_sv_style.py --base HEAD` 与 `git diff --check` 均通过。

## 未关闭项

本批只关闭 runtime MMIO transition table 的重复实现；仍需继续覆盖 AMBIGUOUS
不可重放的跨 queue/device/consumer 组合、SRQ 全生命周期、跨队列/跨线程并发、
SQD/SQE drain/flush、legacy descriptor、外部 PCIe ordering/error、manager 外部调用
窗口补偿、完整 parent/core/integration 汇总和最终 ownership/中文契约审计。项目级
计划继续保持 `active`。
