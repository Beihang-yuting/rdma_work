# CMQ Batch 95：device-env coordinator registration 原子性

本批把多 Function device-env 构建的 coordinator attach/register 收敛为显式
`commit_registration_atomic` 事务。identity 的完整性、clone/cast 和重复 incarnation
检查全部在局部 staging ledger 中完成；只有整组 Function 候选成功后才替换 Host
router 引用和 coordinator ledger。失败不会污染旧 router、identity ledger 或 epoch。

## 变更边界

- `src/integration/rdma_reset_coordinator.sv`：新增批量 registration commit，保留
  `register_function()` 兼容入口和原有幂等语义。
- `src/integration/rdma_function_context.sv`：`build_shared` 支持延迟 coordinator
  commit，在候选 context 完整后再发布登记。
- `src/integration/rdma_device_env.sv`：整组 Function 先构造并暂存，最后单次提交。
- `tests/unit/rdma_reset_coordinator_test.sv`：覆盖第二个 identity clone 失败、身份
  validate 失败和成功替换 router/ledger 的原子性。

## 验证

`rdma_reset_coordinator_test` 通过 VCS53 integration wrapper 通过，wrapper rc=0，
PROCESS/LOGICAL=1/1，UVM warning/error/fatal=0/0/0。日志：
`.superpowers/sdd/2026-09-17-rdma-structural-refactor/evidence/post-batch95-rdma_reset_coordinator_test.log`。

日志 SHA-256：
`05197267df90de7cfb9943acd20dd7b3d40cbc24cbaedbe0dd2a1b93d26e3530`。

本批未修改外部依赖、未提交或 push；后续 reset authority preflight 在 Batch98
继续收敛，不能把本批 focused 证据视为跨 context reset 的完整事务保证。
