# Batch177：queue-data cursor policy

日期：2026-09-24。基线：`feature/rdma-cmq-structural-phase2-batch160`。

## 目标

继续收缩 queue-data engine 中重复的 ring cursor 环回计算。SQ/RQ/CQ/CEQ/AEQ
调用方都需要相同的“末项回零并翻转 wrap、其余递增”规则，但 cursor 的计算本身不应
读取或修改 runtime、pending、ledger、backing 或 scheduler。

## 实现

- 在 `src/core/rdma_queue_data_transaction_models.sv` 新增无状态
  `rdma_queue_cursor_policy::advance()`，只接收 `depth/source_index/source_wrap`
  并返回 `next_index/next_wrap` 值。
- `rdma_queue_data_engine.sv` 保留原有
  `advance_queue_cursor_value()` 兼容 wrapper，内部转发到 detached policy；engine
  仍负责 depth/index admission、runtime cursor mutation、reservation 和 commit 顺序。
- `depth=0` 或越界 index 的算术结果保持原 wrapper 语义，geometry 拒绝仍由 caller
  在既有 admission 分支完成，避免 policy 偷换错误优先级。
- policy 不复制 runtime ledger、lock、pending 或外部资源所有权；结果只是候选值，不能
  单独证明 reservation 或 commit 已完成。

## 验证

```text
DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common \
SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_data_engine_post_test
PROCESS PASS logical=rdma_queue_data_engine_post_test physical=rdma_queue_data_engine_post_test
LOGICAL PASS logical=rdma_queue_data_engine_post_test processes=1
UVM warning/error/fatal = 0/0/0
```

本地 `python3 tools/check_changed_sv_style.py --base HEAD` 与 `git diff --check` 均通过。

## 未关闭项

SRQ 全生命周期、跨队列/跨线程并发、SQD/SQE drain/flush、legacy descriptor、外部 PCIe
ordering/error、manager 外部调用窗口补偿、AMBIGUOUS 全方向组合、完整 parent/core/
integration regression 和最终 ownership/中文契约审计仍保持 OPEN；项目计划继续 `active`。
