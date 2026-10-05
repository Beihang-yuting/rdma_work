# Batch151：facade live-authority helper 收缩

日期：2026-09-22。工作树：`feature/rdma-cmq-contract-foundation`。

本批把 CQ/EQ/RQ/SQ facade 中完全重复的 live Function-authority 检查集中到
`src/model/rdma_authority_validation.sv`，不改变 protected facade 入口或 queue-data
runtime 的所有权。计划继续保持 `active`。

## 代码收缩

- 新增 package-scope `rdma_validate_live_authority()`，按固定顺序处理
  configured/delegate/binding 缺失、冻结的 Function UID/generation/reset epoch 漂移、
  binding 非 `RDMA_BIND_ACTIVE`、`validate()` 返回 null，以及下游失败状态透传。
- `rdma_cq_engine`、`rdma_eq_engine`、`rdma_rq_engine`、`rdma_sq_engine` 的原
  protected `validate_live_authority()` 保留为薄转发，调用方继续负责 facade 的
  `configured` 状态、authority 快照和 delegate 生命周期；helper 不保存引用、不访问
  runtime、Host-memory、MMIO 或 ledger。
- `rdma_model_pkg.sv` 在 `rdma_function_binding.sv` 后按依赖顺序 include helper。

行为审计逐分支确认原拒绝优先级、状态码、消息前缀和输出清理语义保持不变；本批没有
把 `binding.validate()` 的失败改写为新的 code，也没有放宽 reset/重绑后的 stale gate。

## 验证

所有 VCS 命令通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 执行：

| 入口 | 结果 |
| --- | --- |
| `rdma_sq_engine_test` | PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_rq_engine_test` | PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_cq_engine_test` | PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_eq_engine_test` | PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |

本批边界的静态门禁与 Python unit suite 均通过；Batch151 后全目录 scanner 为 188 个
文件（186 `.sv`、2 `.svh`）、5,463 methods、0 diagnostics。Batch152 后的最新计数和
新增配置 helper 证据见 `task-cmq-batch152-facade-configuration-shrink-report.md`。

源码 SHA-256：

- `src/model/rdma_authority_validation.sv`：
  `4f768684482c548065cc0d2756180b445469805fc56cd8a7961c481a0a3ccf04`
- `src/model/rdma_model_pkg.sv`：
  `79ce34458fa755689480bfedfc472e0421a1e99f9bc71e84e2ad7b50d7c0ce24`
- `src/core/rdma_cq_engine.sv`：
  `250fc073d27c872c1a790588a0bf7dd4e60a25a1e5a6acff249097133a577d9a`
- `src/core/rdma_eq_engine.sv`：
  `7cb3a1cd8072e05029807fdca64db2a0fb3e908315f3153bd6c2eee08c9d038f`
- `src/core/rdma_rq_engine.sv`：
  `5da1163f7c66cbb6cb3b4c4e91594a21b974a18634b691d9992b100a9f1423f6`
- `src/core/rdma_sq_engine.sv`：
  `98f05053228dbbbe9c2b2b01aeec865c98d2ff3b9be827b3765d60de5cc57b19`

跨队列并发、CQ 专属配置、SRQ 全生命周期、legacy descriptor、外部 PCIe error/ordering、
engine-level 全局锁和最终 ownership 审计仍开放，不能把本批 focused GREEN 解释为整份
结构重构计划完成。
