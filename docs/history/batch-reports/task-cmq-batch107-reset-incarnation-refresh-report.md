# CMQ Batch 107：reset 后 registration incarnation 刷新边界

本批承接 Batch 106 的生命周期审计，修复一个会让旧 registration snapshot 在
reset 后误走幂等快路径的缺口。修复只收紧 coordinator 的 registration 判断，不改变
wire 坐标、外部依赖或全局并发锁语义；结构重构计划仍保持 `active`。

## 发现与修复

- `src/integration/rdma_reset_coordinator.sv`
  - `commit_registration_atomic()` 现在先解析 coordinator-owned snapshot 的当前
    `generation/reset_epoch`，再决定是否可以走 `same_incarnation()` 幂等路径。
  - 只有 registration snapshot 发布后尚未应用 reset（`applied_resets == 0`）且输入
    与 owned snapshot 完全相同，才保留重复登记的成功语义。
  - reset 后传入旧 snapshot 会返回 `RDMA_SC_STALE_GENERATION`；传入 coordinator
    推导出的当前 incarnation 才能刷新 registration baseline，未来跳跃和回退仍拒绝。
  - 该顺序避免旧 baseline 被重新发布，保持 Function absolute epoch 与有效
    incarnation 的一一对应。
- `tests/unit/rdma_reset_coordinator_test.sv`
  - lifecycle fixture 先登记 generation 7/reset_epoch 9 的 baseline 并执行 PF reset，
    随后显式重新提交旧 snapshot，断言返回 `RDMA_SC_STALE_GENERATION` 且 epoch 不变。
  - 同一 fixture 再提交推导出的 generation 8/reset_epoch 10 当前 incarnation，断言
    baseline refresh 成功，并继续覆盖未来跳跃、回退、UID/global-ID 冲突及 overflow。

本批 registration-focused 生命周期审计同时复核了 router-local epoch 原子性、
Function/PF/Host/Device overflow、candidate seal 和 env-local reentrancy guard；这些 seam
未发现需要追加源码修改的缺陷。更广的 callback 直调 coordinator、direct context reset、
router detach/rebind 与跨环境 ownership 风险另见 Batch 108 只读审计，仍是 OPEN，不被本批
GREEN 结果覆盖。router 的四维兼容聚合字段回绕和 `attach_host_router()` 的 null 前置条件
仍是已有 API 边界，未被误报为本批功能失败。

## 当前源码验证

所有 VCS 仿真均通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 环境执行，
VCS 为 `W-2024.09-SP1_Full64`；integration 使用
`DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common`。严格验收条件为 wrapper rc=0、
PROCESS/LOGICAL PASS，以及 UVM warning/error/fatal=0/0/0。

| 验证入口 | 结果 | 日志 SHA-256 |
| --- | --- | --- |
| `rdma_reset_coordinator_lifecycle_test` focused | rc=0；1/1；UVM 0/0/0 | `0190ac13977ed3f69dfa9ccb74f3949e3e361c3cbe3e779de220783f931a10c5` |
| integration regression（8 tests） | rc=0；8/8 tests pristine | `2d501a506ebae6862c262cafa1dc39affa8030708a847b1aa3f12799d3b6c042` |
| CMQ gate regression | rc=0；28/28 process、11/11 logical；UVM 0/0/0 | `1262871e56d76f6439f30e701b662059e6daa416e14fd229607e3211be574274` |
| core regression | rc=0；95/95 process、78/78 logical；UVM 0/0/0 | `dad439dd57984e62955f4e7ca0cb65e0075c9239a00a5a4e1a78d556e91d2f4f` |

完整日志位于 `.superpowers/sdd/2026-09-17-rdma-structural-refactor/evidence/`：
`batch107-rdma_reset_coordinator_lifecycle_test.log`、`batch107-integration-regression.log`、
`batch107-cmq-gate-regression.log` 和 `batch107-core-regression.log`。integration wrapper
中的 8 个测试分别为 `rdma_dpu_integration_test`、`rdma_function_context_test`、
`rdma_device_env_test`、`rdma_reset_cascade_test`、`rdma_pcie_router_test`、
`rdma_host_mem_router_test`、`rdma_reset_coordinator_test` 和本批 lifecycle test。

## 静态门禁与边界

Batch 107 当前源码静态门禁全部通过：Python unittest 292、CMQ manifest 22、SV keyword
guard 3、queue-lifecycle/profile/Phase-1A checks、changed-SV style、`git diff --check`，
以及覆盖 185 个 `.sv`、2 个 codec `.svh`、5,316 个 function/task 的中文契约扫描（0
diagnostics）。对应日志和 artifact 清单为 `evidence/batch107-*.log` 与
`evidence/batch107-artifact-sha256.txt`。

本批没有执行 reset、clean、merge、push，也没有修改外部依赖。以下事项仍明确开放：

- coordinator 的跨 env/thread 全局并发锁及更深生命周期/所有权设计；
- 广义 Phase 1C F2 的 `sge_num` canonical-authority/whole-plan 收口；
- `pcie_work` external lock，阻断文本仍必须是
  `external dependency is not approved: pcie_work`。
