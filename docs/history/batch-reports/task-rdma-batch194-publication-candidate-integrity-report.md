# Batch194：publication candidate identity integrity

日期：2026-09-25

## 目标

继续收紧 Batch193 的 resource publication stage/commit 边界，确保 detached candidate
在离开 stage 后即使被调用方篡改，也不能通过伪造 key、owner 或 handle 身份写入第二个
registry alias，或覆盖已经提交的同一 incarnation。

## 实现

- `rdma_resource_publication_candidate::valid()` 现在按 manager 的 canonical 格式重算
  `registry_key`、`incarnation_key` 与 `generation_key`，并核对 owner/handle kind、两份
  resource snapshot 的 handle/owner identity；不再把“key 非空”当作充分证明。
- `commit_resource_publication()` 在任何账本写入前拒绝已经存在的 registry 或 incarnation
  key，避免 stage→commit 间的旧 candidate 覆盖后来发布的同一资源。
- `rdma_resource_manager_test` 增加 hostile key、hostile owner 和重复 stage/commit 矩阵；
  失败 commit 保持 registry cardinality 不变，首次合法 commit 只发布一次。

## 验证

- `SSHPASS=123 scripts/run_vcs53.sh core rdma_resource_manager_test`：PROCESS/LOGICAL
  PASS，UVM warning/error/fatal `0/0/0`。
- `python3 -m unittest discover -s tests/unit -p 'test_*.py'`：293/293 PASS。
- `python3 tools/check_changed_sv_style.py --base HEAD` 与 `git diff --check HEAD`：PASS。

## 边界

本批只关闭 publication candidate 的 key/identity provenance 与重复提交覆盖窗口；不把
单线程 duplicate guard 扩大解释为跨线程/跨进程锁、allocator/registry 全局并发、SRQ
全生命周期、外部 ordering/error/backpressure、Phase-1C F2 whole-plan 或最终 ownership
审计完成。项目计划继续保持 `active`。
