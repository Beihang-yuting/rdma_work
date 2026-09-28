# Batch162：resource lifecycle blocker snapshot

## 范围

本批继续项目级结构重构的 Phase C 小批迁移，只收束 resource manager 内部重复的只读
生命周期 blocker 判定，不改变 QP destroy 的业务流程，也不把依赖/outstanding 账本复制到
policy、executor 或 reset coordinator。

## 实现

- 在 `src/core/rdma_resource_manager.sv` 新增受保护的
  `snapshot_activity_blockers()`。
- helper 只读取 manager 自有 `registry`、`has_dependents()` 和资源的
  `outstanding_ids`，输出 `has_live_dependents` 与 `has_outstanding_operations` 两个
  detached bit；null 输入 fail-closed 为无 blocker，调用方仍需先完成 schema/handle
  admission。
- `begin_quiesce()`、`finalize_qp_release()`、`finalize_release()` 和
  `release_reserved()` 复用同一只读 snapshot；每个 caller 继续保留自己的状态门禁、
  recovery 校验、依赖优先级、错误文案和 `force_release_key()` 提交点。
- 没有新增第二把锁、第二份 outstanding ledger、外部资源引用或 QP destroy policy；
  manager 仍是依赖拓扑和可变资源 registry 的唯一 owner。

## 行为证据

- `rdma_resource_manager_test`：VCS53 登录 bash，PROCESS/LOGICAL PASS，UVM
  `WARNING=0/ERROR=0/FATAL=0`。
- `rdma_queue_lifecycle_test`：VCS53 登录 bash，PROCESS/LOGICAL PASS，UVM
  `WARNING=0/ERROR=0/FATAL=0`；既有 dependent reservation busy 断言保持通过。
- `rdma_qp_lifecycle_test`：VCS53 登录 bash，PROCESS/LOGICAL PASS，UVM
  `WARNING=0/ERROR=0/FATAL=0`；QP outstanding destroy 仍在 `begin_quiesce` 和任何 CMQ
  side effect 前返回 `RDMA_SC_RESOURCE_BUSY`。
- `rdma_qp_recovery_test` 与 `rdma_control_plane_test`：VCS53 登录 bash 均
  PROCESS/LOGICAL PASS，UVM `WARNING=0/ERROR=0/FATAL=0`；QP finalization、facade
  finalize/release_reserved 的 recovery/依赖边界均保持原顺序。

## 静态验证

- 全目录中文契约 scanner：192 文件（190 `.sv`、2 `.svh`），5,499 methods，0
  diagnostics。
- changed-SV style：通过（无 hard diagnostic）。
- `git diff --check`：通过。
- Python unit suite：293/293 通过。

## 保持开放

QP/SRQ 跨资源 destroy dependency 的完整组合、跨队列并发、reset 统一验收、manager
外部调用窗口补偿、SQD/SQE drain/flush 语义与最终 ownership 审计继续保持 OPEN；项目级
重构计划仍为 `active`。
