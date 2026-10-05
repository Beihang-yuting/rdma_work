# CMQ Batch 98：reset authority ledger 与 quiesce 前置校验

本批把 reset 请求的 identity/Host scope 校验前移到 quiesce 之前。coordinator 的
ledger key 纳入 parent-PF BDF，并记录 registration epoch；当前 generation/reset
epoch 由 immutable registration snapshot 与已发布 Function epoch 推导。未知、过时
或未登记 scope 的请求不会创建 phantom epoch，也不会先改变 context/router。

## 变更边界

- `src/integration/rdma_reset_coordinator.sv`：新增
  `validate_registered_identity`、`validate_registered_host_scope` 和 registration
  epoch ledger；VF/PF/Host reset 在 bump 前建立 authority 屏障。
- `src/integration/rdma_device_env.sv`：新增 `validate_reset_scope`，在 VF/PF/Host/
  Device quiesce 前验证完整 scope 与 context 覆盖；外部 router 仍为非拥有引用。
- `src/integration/rdma_function_context.sv`：候选式 identity/binding reset 与 owner
  handle 发布，失败保留旧 context 状态。
- `tests/unit/rdma_reset_coordinator_test.sv`、
  `tests/integration/rdma_reset_cascade_test.sv`：覆盖未知/过时 VF/PF/Host、批量
  registration 失败原子性和 reset scope 无副作用。

## VCS53 integration 验证

四项有效 integration wrapper 均 rc=0、PROCESS/LOGICAL=1/1，UVM warning/error/fatal
均为 0/0/0：

| 测试 | 日志 SHA-256 |
| --- | --- |
| `rdma_reset_coordinator_test` | `9c8202c3bea9c3c4e517e1cd6f62085cce3e8a68f516d539442772c5fef7a80a` |
| `rdma_function_context_test` | `f5cacdc90493ea3c81e58ccfd710da519e684e474995164373bbb93796c8673c` |
| `rdma_device_env_test` | `08a4e0a60b83603fc97e5811110a5cee2c92b7170a2329426491c2a5575308d7` |
| `rdma_reset_cascade_test` | `80f3d42a30b9a90d3320c52357b83cb66a027eb1adfb16979898e2d6d896f7ea` |

日志位于 `.superpowers/sdd/2026-09-17-rdma-structural-refactor/evidence/`。
一次误用 `core` suite 的尝试因 `RDMA_DPU_INTEGRATION` 未定义而返回 rc=2，原始日志
`post-batch98-rdma_reset_coordinator_test-core.log`（SHA-256
`8cf776b8c6765d22ef2229716864d6f1bceaecad5bb0cdaf55488995f2d5c491`）仅作为诊断，
不计入生产回归结果。

## 尚未关闭

reset 后多个 context 的 quiesce → epoch bump → rebuild 仍可能出现跨 context 的逐项
提交窗口；本批只建立 preflight 屏障，未声称跨 context prepare/commit 原子性。
