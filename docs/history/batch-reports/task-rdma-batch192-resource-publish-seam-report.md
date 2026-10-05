# Batch192：resource identity publish transaction seam

日期：2026-09-25

## 目标

继续 Phase C 的 resource-manager 收缩，将普通资源 `create_*` 入口重复的
`register_resource()`、失败回滚和 candidate 清除收束为一个受保护事务 helper；保持
Function 的 generation/tombstone 专用路径不变，避免把两种 identity 语义错误合并。

## 实现

- 在 `src/core/rdma_resource_manager.sv` 新增
  `publish_identity_candidate()`，统一执行：
  `candidate.valid()` → authoritative 形状检查 → `register_resource()` → null/失败
  归一化 → `rollback_identity_candidate()` → 成功 `candidate.clear()`。
- PD/MR/CQ/QP/SRQ/CMQ/CEQ/AEQ 的普通创建入口均改用该 helper；字段投影、依赖校验、
  QP sequence 更新、错误文本和 output cast 保持在各自 caller，Function 创建继续使用
  `rdma_function_identity_candidate` 的独立路径。
- helper 不保存 registry、allocator、lock 或 external adapter 引用；manager 仍是
  allocator、binding registration、registry、incarnation publication 的唯一 mutable owner。

## 验证

- `SSHPASS=123 scripts/run_vcs53.sh core rdma_resource_manager_test`：PROCESS/LOGICAL
  PASS，UVM warning/error/fatal `0/0/0`。
- `SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_lifecycle_test`：PROCESS/LOGICAL
  PASS，UVM warning/error/fatal `0/0/0`。
- `SSHPASS=123 scripts/run_vcs53.sh core rdma_qp_lifecycle_test`：PROCESS/LOGICAL PASS，
  UVM warning/error/fatal `0/0/0`。
- `SSHPASS=123 scripts/run_vcs53.sh core rdma_control_plane_test`：PROCESS/LOGICAL PASS，
  UVM warning/error/fatal `0/0/0`。
- `python3 -m unittest discover -s tests/unit -p 'test_*.py'`：293/293 PASS。
- `python3 tools/check_changed_sv_style.py --base HEAD`、`git diff --check HEAD`：PASS。

## 边界

本批只收束普通资源 publication 的重复事务 seam，不改变资源依赖 admission、Function
incarnation、跨线程 allocator 并发、SRQ 全生命周期、外部 adapter ordering/error 或
项目级最终 ownership 审计；项目级计划继续保持 `active`。
