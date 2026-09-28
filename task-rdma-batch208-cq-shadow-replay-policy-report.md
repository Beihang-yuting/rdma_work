# Batch208：CQ shadow replay authority policy

日期：2026-09-25

## 目标

明确 CQ shared-shadow replay 的 authority 与 canonical payload 边界，去除
`rdma_cq_engine::flush_shadow()` 对 caller snapshot 和 cached snapshot 的重复 identity
校验，同时不改变 replay 的 exactly-once evidence/cache 语义。

## 实现

- 新增 `src/core/rdma_cq_shadow_replay_policy.sv`，统一校验 CQ kind、Function UID、
  generation、reset epoch 和 CQ object ID；caller mismatch 默认返回
  `RDMA_SC_STALE_GENERATION`，cache integrity mismatch 可显式映射为
  `RDMA_SC_INVALID_STATE`。
- `flush_shadow()` 两个 authority gate 改为调用该 policy；首次 capture、URC evidence、
  cache/count mutation 和 replay detached clone 仍由 CQ facade 唯一拥有。
- replay 继续忽略 caller 的 SQ/RQ CI、arm、sequence，成功时从 canonical
  `flushed_shadow` 重建独立输出；policy 不读取 cache、不保存 handle、不拥有 delegate 或
  evidence。

## 验证

- `rdma_cq_shadow_flush_test`、`rdma_cq_engine_test`、`rdma_cq_engine_resize_test` 在
  VCS53 均 PROCESS/LOGICAL PASS，UVM `WARNING/ERROR/FATAL=0/0/0`。
- `python3 tools/check_changed_sv_style.py --base HEAD`：PASS。
- `python3 tools/check_queue_lifecycle.py`：PASS。
- `git diff --check HEAD`：PASS。

本批只收束 CQ shadow replay authority 纯值门禁，不关闭跨 queue/engine 并发、SRQ 完整
lifecycle、legacy descriptor、PCIe ordering/error/backpressure、manager 外部调用窗口、
Phase-1C F2 whole-plan 或最终 ownership 审计；项目级计划仍为 `active`。
