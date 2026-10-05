# Batch178：runtime/queue-data shared cursor policy

日期：2026-09-24。基线：`feature/rdma-cmq-structural-phase2-batch160`。

## 目标

Batch177 已把 queue-data engine 的 successor 计算移入 detached policy，但 queue
runtime 仍保留同样的 `i + 1 >= depth` 算术。该重复实现会让 runtime 与 SQ/RQ/CQ/CEQ/AEQ
在环回或 wrap 翻转规则上产生漂移风险。

## 实现

- 新增 `src/core/rdma/rdma_queue_cursor_policy.sv`，将
  `rdma_queue_cursor_policy` 放到 core 公共纯值层，脱离 queue-data transaction
  result 模型；core package 在 runtime transaction models 之前 include 它。
- `rdma_queue_data_engine.sv` 的既有兼容 wrapper 继续转发到 policy。
- `rdma_queue_runtime.sv::cursor_advance()` 改为调用同一 policy，runtime 仍唯一拥有
  depth、cursor mutation、slot ledger、reservation、lock 和 commit；wrapper 只原地
  更新 caller 的 index/wrap。
- `rdma_queue_data_transaction_models.sv` 删除重复 policy 定义，避免同名 class 或
  两份 successor 规则；geometry admission 和错误优先级仍留在各 caller。

## 验证

```text
DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common \
SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_runtime_test
PROCESS PASS logical=rdma_queue_runtime_test physical=rdma_queue_runtime_test
LOGICAL PASS logical=rdma_queue_runtime_test processes=1
UVM warning/error/fatal = 0/0/0

DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common \
SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_data_engine_post_test
PROCESS PASS logical=rdma_queue_data_engine_post_test physical=rdma_queue_data_engine_post_test
LOGICAL PASS logical=rdma_queue_data_engine_post_test processes=1
UVM warning/error/fatal = 0/0/0
```

Batch177 完成后的完整回归（未改变业务逻辑的公共 policy 收缩前）也已通过：core
97/97 PROCESS、80/80 LOGICAL，integration 10/10 场景，107 个 UVM report pristine，
无 PROCESS/LOGICAL FAIL。Batch178 修改后已重新刷新完整 regression：core 97/97
PROCESS、80/80 LOGICAL，integration 10/10 场景，107 个 UVM report 全部 pristine，
PROCESS/LOGICAL FAIL 为 0；日志见 `/tmp/rdma-full-regression-batch178-final.log`。

本地 `python3 tools/check_changed_sv_style.py --base HEAD` 与 `git diff --check` 均应
作为本批提交门禁执行。

## 未关闭项

SRQ 全生命周期、跨队列/跨线程并发、SQD/SQE drain/flush、legacy descriptor、外部 PCIe
ordering/error、manager 外部调用窗口补偿、AMBIGUOUS 全方向组合、完整最终 regression
和最终 ownership/中文契约审计仍保持 OPEN；项目计划继续 `active`。
