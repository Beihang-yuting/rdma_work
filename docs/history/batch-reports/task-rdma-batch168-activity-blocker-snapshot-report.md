# Batch168 resource activity blocker snapshot report

## 目标

把 resource manager 多个 quiesce/finalize/release 入口重复的两个 blocker bit 收束为
一个 detached value snapshot，同时保留依赖优先的错误顺序与 manager 的唯一账本所有权。

## 实现

- `src/core/rdma_resource_transaction_models.sv` 新增
  `rdma_resource_activity_blocker_snapshot`，携带 `has_live_dependents`、
  `has_outstanding_operations` 以及对应数量。
- `snapshot_activity_blockers()` 一次扫描 registry 和 `outstanding_ids` 生成该结构；
  `begin_quiesce()`、QP finalize、普通 finalize 和 reservation release 仅读取 snapshot，
  不复制 registry、lock、recovery 或 reset ledger。
- 依赖判断仍按原规则识别直接 handle dependency 与 Function owner 关系，调用方仍按
  “live dependent 先于 outstanding”返回既有错误码和文案。
- resource-manager 测试 probe 暴露只读观察 seam，dependency fixture 验证 PD 的三个直接
  dependent 计数和零 outstanding，未增加生产侧状态写入口。

## 验证

- VCS53 `rdma_resource_manager_test`：PROCESS/LOGICAL PASS，UVM 0/0/0。
- VCS53 `rdma_queue_lifecycle_test`：PROCESS/LOGICAL PASS，UVM 0/0/0。
- VCS53 `rdma_qp_lifecycle_test`：PROCESS/LOGICAL PASS，UVM 0/0/0。
- VCS53 `rdma_control_plane_test`：PROCESS/LOGICAL PASS，UVM 0/0/0。
- changed-SV style、`git diff --check`、queue/profile/Phase-1A 门禁通过；全目录中文契约
  scanner 为 196 个源码文件（194 `.sv`、2 `.svh`）、5,518 个 function/task、0 hard
  diagnostics。

## 未关闭边界

QP/SRQ 更广泛 destroy dependency 组合、跨线程/跨队列并发、SQD/SQE drain/flush、外部
ordering/error、manager 外部调用窗口补偿和最终 ownership 审计仍保持 OPEN；项目级计划
继续为 `active`。
