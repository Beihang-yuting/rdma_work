# Batch201：SRQ preflight 纯值策略收缩报告

日期：2026-09-25
工作树：`feature/rdma-cmq-structural-phase2-batch160`

## 目标

继续 Phase C/D 的小批迁移，降低 `rdma_queue_lifecycle_policy.sv` 中 SRQ preflight
的条件密度，同时保持请求校验、Function capability、PD dependency、backing clone
和 ring layout 的既有顺序与错误文案。

## 实现

- 新增 `src/core/rdma_srq_preflight_value_policy.sv`。
  - `requires_sgb()` 集中 `max_sge > 2` 的纯值判定。
  - `validate_limits()` 集中 SRQ depth、max_sge、Function capability 和 14-bit
    encoded limit 边界。
  - `validate_borrowed_backing()` 集中 SRQ_RING/SRFQ_RING/SRQ_SGB 角色合法性、
    optional SGB 和 required-role cardinality。
- `rdma_queue_lifecycle_policy::preflight()` 只保留 common request/authority 校验、
  PD dependency lookup、backing clone、ring layout 和 preflight publication；纯值条件
  通过新 policy 调用，错误码和原始消息保持不变。
- policy 无实例状态，不复制 manager registry、generation、lock、queue ledger 或
  外部 Host-memory/PCIe ownership；borrowed mapping 仍由 caller/planner 管理。
- `rdma_queue_lifecycle_test` 增加 SGB threshold、标量边界、缺失/多余/空 slice
  矩阵，并继续覆盖公开 SRQ create preflight、SGB ring layout 和 borrowed backing。

## 验证

- VCS53 `scripts/run_vcs53.sh core rdma_queue_lifecycle_test`
  - PROCESS PASS
  - LOGICAL PASS
  - UVM WARNING/ERROR/FATAL：`0/0/0`
- VCS53 `DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common scripts/run_vcs53.sh integration rdma_dpu_integration_test`
  - PROCESS PASS
  - LOGICAL PASS
  - UVM WARNING/ERROR/FATAL：`0/0/0`
  - dpu_common external dependency preflight/lock verify 通过。
- Python 全量单测：`293/293 PASS`。
- changed-SV style：PASS（包含未跟踪新增 `.sv` 文件）。
- queue lifecycle gate：PASS。
- profile naming：PASS。
- Phase-1A approval gate：PASS。
- `git diff --check HEAD`：PASS。

## 未关闭范围

本批只收缩 SRQ preflight 的纯值判定，不宣称完成 SRQ 完整 create/post/recovery/
destroy 组合、allocator/registry 跨线程或跨进程互斥、跨 queue/engine 并发、SQD/SQE
drain/flush、legacy descriptor、外部 PCIe ordering/error/backpressure、Phase-1C F2
whole-plan 或最终 ownership/中文契约全目录审计。两个结构重构计划继续保持 `active`。
