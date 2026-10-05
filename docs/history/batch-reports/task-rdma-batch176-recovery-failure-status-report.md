# Batch176：recovery failure-status publication helper

日期：2026-09-24。基线：`feature/rdma-cmq-structural-phase2-batch160`。

## 目标

继续压缩 runtime recovery 的重复提交代码。普通 `record_recovery_failure()` 与
noalloc `record_recovery_failure_noalloc()` 原先分别复制 failure status 的全部字段，
存在漏字段和错误顺序漂移风险。

## 实现

- `rdma_queue_runtime.sv` 新增锁内 `copy_recovery_failure_status_locked()`，集中复制
  `category/code/hardware_code/hardware_code_valid/source_engine/function_uid/generation/`
  `resource_id/command_id/wr_id/severity/retryable/message`。
- 两个 recovery 入口继续各自负责 lock、evidence admission、status-slot 行为和
  commit/retry gate；helper 只在既有 pending/failure-status 目标上执行按值覆盖，
  不创建 status、不拥有外部资源、不改变 confirmation 或 cursor。
- 原有 `actual_failure=null`（仅阶段投影）和 `actual_failure.ok()` 拒绝语义保持不变，
  所有状态写入仍发生在原锁窗口内。

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

SRQ 生命周期、跨队列/跨线程并发、SQD/SQE drain/flush、legacy descriptor、外部 PCIe
ordering/error、manager 外部调用窗口补偿、AMBIGUOUS 全方向组合、完整 parent/core/
integration regression 和最终 ownership/中文契约审计仍保持 OPEN；项目计划继续 `active`。
