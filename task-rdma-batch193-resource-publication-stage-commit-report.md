# Batch193：resource publication stage/commit seam

日期：2026-09-25

## 目标

继续推进 Phase C，缩短 `rdma_resource_manager::register_resource()` 的外部投影调用窗口。
把可能触发 factory/clone 的 detached projection 与 registry/代际账本 mutation 分成显式
`stage → commit` 两段；不改变既有 create、lookup、rollback API 或资源所有权。

## 实现

- `src/core/rdma_resource_transaction_models.sv` 新增
  `rdma_resource_publication_candidate`，保存 registry/published 快照、owner/handle 快照
  和三类稳定 key；`valid()`/`clear()` 只处理 detached 值，不复制 registry、allocator、
  lock 或外部 adapter。
- `src/core/rdma_resource_manager.sv` 新增受保护
  `stage_resource_publication()` 与 `commit_resource_publication()`：前者一次完成全部
  projection 并在失败时清除 candidate，后者不再调用 factory/clone，只写入 registry、
  incarnation owner/handle 与 known generation 四份 manager-owned 账本。
- `register_resource()` 继续作为兼容入口，委托 stage/commit，成功返回 detached
  `published`；`create_function()`、普通 resource create 和既有 lifecycle caller 无需改变。
- `rdma_resource_manager_probe` 增加 stage/commit/count 只读测试入口；fixture 覆盖 null
  输入的零副作用、valid candidate 的 detached staging、一次性 commit/lookup 以及 clear
  后二次 commit 拒绝。

## 验证

- `SSHPASS=123 scripts/run_vcs53.sh core rdma_resource_manager_test`：PROCESS/LOGICAL
  PASS，UVM warning/error/fatal `0/0/0`。
- `SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_lifecycle_test`：PROCESS/LOGICAL
  PASS，UVM warning/error/fatal `0/0/0`。
- `SSHPASS=123 scripts/run_vcs53.sh core rdma_qp_lifecycle_test`：PROCESS/LOGICAL PASS，
  UVM warning/error/fatal `0/0/0`。
- `SSHPASS=123 scripts/run_vcs53.sh core rdma_control_plane_test`：PROCESS/LOGICAL PASS，
  UVM warning/error/fatal `0/0/0`。
- `python3 -m unittest discover -s tests/unit -p 'test_*.py'`、changed-SV style、
  `git diff --check` 与中文契约 scanner 在最终源码边界复跑通过。

## 边界

本批只关闭 resource publication 的外部投影/账本提交结构窗口，不宣称解决 allocator/
registry 跨线程锁、跨 incarnation destroy dependency、SRQ 全生命周期、外部 ordering/
error/backpressure、Phase-1C F2 whole-plan 或最终 ownership 审计；项目计划继续保持
`active`。
