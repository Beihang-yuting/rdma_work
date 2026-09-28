# Batch198：CMQ ambiguity evidence policy 收束

## 变更

- 新增 `src/core/rdma_cmq_ambiguity_policy.sv`，以无状态
  `rdma_cmq_ambiguity_policy::is_ambiguous()` 集中 timeout/reset、null status、缺失
  ticket/completion 和 no-submit 证明的证据分类。
- `rdma_queue_lifecycle_executor` 与 `rdma_qp_lifecycle_executor` 保留原有兼容 wrapper，
  只把 caller-specific 差异作为显式 profile 参数传入：queue 继续允许 completion 壳
  配合 no-submit 证明，QP 继续要求 completion 也为空；QP 的无 ticket/completion 纯
  成功仍保持确定，queue 仍按保守规则判为 ambiguous。
- 不复制 CMQ adapter、ticket、completion、recovery 或 runtime ledger；policy 不保存
  引用、不产生副作用，后续 recovery/状态提交仍由各 executor 唯一拥有。

## 验证

- `rdma_cmq_engine_models_test`：VCS53 登录 bash，PROCESS/LOGICAL PASS；UVM 最终
  warning/error/fatal 为 `0/0/0`（测试环境 catcher 报告的既有预期 fatal 不计入最终
  report summary）。
- `python3 -m unittest discover -s tests/unit -p 'test_*.py'`：293/293 PASS。
- `python3 tools/check_changed_sv_style.py --base HEAD`：PASS。
- `git diff --check HEAD`：PASS。

## 边界

本批只去重 CMQ ambiguity 纯值分类，不改变 adapter 的 no-submit 证明、不实现
SQD/SQE drain/flush、registry/allocator 并发或 SRQ 全生命周期；相关组合和最终
ownership 审计仍由项目计划继续跟踪。
