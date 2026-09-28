# Batch161：QP 生命周期 transition policy 重构报告

日期：2026-09-24。基线：`feature/rdma-cmq-structural-phase2-batch160` 当前未提交工作树。

## 目标与边界

本批只抽取 QP 状态迁移 policy，不改变业务能力、错误码、外部资源生命周期或提交顺序。
业界 verbs 的主干 `RESET→INIT→RTR→RTS`、`ERROR/RESET` 回退和当前 profile 的
`SQD/SQE` capability gate 由无状态 `rdma_qp_transition_decide()` 集中表达；QP executor
仍是 QP backing、QPC image、CMQ、generation fence、outstanding ledger 和 resource
manager commit 的唯一 owner。

明确保留 `SQD/SQE → RDMA_SC_UNSUPPORTED_OPCODE`。本批不实现 drain/flush，不把 QP、SQ、
RQ、CQ、EQ 或 CMQ 合成万能 engine，也不复制 `dpu_common` 的 Function/topology authority。

## 实际改动

- 新增 `src/core/rdma_qp_transition_policy.sv`：定义 transition action/decision value，
  处理未知状态、非法矩阵和 SQD/SQE capability rejection。
- `src/core/rdma_core_pkg.sv` 纳入 policy include，保持先定义后使用。
- `src/core/rdma_qp_lifecycle_executor.sv` 删除内嵌迁移 `case`，仅把 policy decision
  映射回原有 `state_only/full_modify` 分支；其余 admission、QPC、CMQ 和 commit 路径不变。
- `tests/unit/rdma_qp_lifecycle_test.sv` 新增 policy characterization，覆盖主干、
  ERROR/RESET、非法迁移及 SQD/SQE gate。

## 验证结果

| 验证项 | 结果 |
| --- | --- |
| VCS53 `rdma_qp_lifecycle_test` | PROCESS/LOGICAL PASS；UVM warning/error/fatal `0/0/0` |
| VCS53 `rdma_qp_recovery_test` | PROCESS/LOGICAL PASS；UVM warning/error/fatal `0/0/0` |
| VCS53 `rdma_control_plane_test` | PROCESS/LOGICAL PASS；UVM warning/error/fatal `0/0/0` |
| VCS53 `rdma_control_plane_cmq_engine_test` | PROCESS/LOGICAL PASS；UVM warning/error/fatal `0/0/0` |
| Python unit suite | `293/293 OK` |
| CMQ gate manifest/keyword | `23/23`、`3/3` PASS |
| changed-SV style、diff | PASS；`git diff --check` 无输出 |
| queue/profile/Phase-1A | PASS |
| 外部依赖锁 | `pcie_work`、`host_mem` verify PASS |
| 全目录中文契约 scanner | 192 文件（190 `.sv`、2 `.svh`），5,498 methods，0 hard diagnostics |

CMQ gate 已在本批工作树重新跑完：11/11 logical、18/18 engine process、字段变异
evidence PASS，所有 UVM summary 的 warning/error/fatal 均为 0/0/0。53 机 `rdma_defs`
组合门禁也通过，包含 archive/profile、CMQ oracle 和 field ownership verification。

## 后续开放项

- `SQD/SQE` drain/flush、outstanding WQE flush 和 destroy dependency 尚未实现；仍按既有
  capability contract 拒绝。
- QP 与 queue/resource/reset 的跨组件并发、统一 reset epoch 验收和最终 ownership 审计
  仍需独立批次。
- 结构重构总计划保持 `active`，本批 focused GREEN 不等价于项目级重构完成。
