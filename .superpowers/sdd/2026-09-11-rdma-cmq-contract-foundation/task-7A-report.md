# Task 7A 实现报告

## 范围

本任务新增 Phase 1A approval preflight checker 与 focused unit tests。实现未创建
`docs/superpowers/approvals/2026-09-11-rdma-cmq-contract-foundation-phase1a.env`，未运行真实仓库 checker，也未开始 Task 8。

## 实现结果

- `tools/check_rdma_phase1a_approval.py` 提供冻结的 `Phase1AApproval`、严格十键 ordered parser、UTF-8/BOM/CRLF/terminal LF/blank/comment/spacing 拒绝和字段 grammar 校验。
- 默认模式证明 approval tracked 且 worktree/index clean 后读取 worktree bytes；`--staged` 只接受单一 staged approval 路径并读取 `git show :<path>`。
- 两种模式均证明 plan tracked/clean，解析完整 plan commit，检查 ancestry、`cc07586` first parent、唯一 plan path、frozen blob SHA-256 与当前计划原始 bytes。
- Git 命令统一使用参数数组，并允许注入只读 `(returncode, stdout, stderr)` runner；CLI 失败只输出单行稳定 stderr 诊断。

## 验证

- RED：`python3 -m unittest tests.unit.test_check_rdma_phase1a_approval -v` 在 checker 不存在时按预期导入失败。
- GREEN：同一命令通过，11 tests / 11 passed。
- `python3 -m py_compile tools/check_rdma_phase1a_approval.py tests/unit/test_check_rdma_phase1a_approval.py` 通过。
- `git diff --check` 通过。
- 已清理生成的 `__pycache__` 目录。

## Concerns

Approval artifact 仍故意缺失；默认 CLI 在当前 checkout 上应继续 fail-closed，待项目 owner 显式批准后由后续 checkpoint 创建并绑定 artifact。
