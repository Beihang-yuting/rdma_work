# CMQ Batch 94：QP borrowed-owner 原子绑定

本批收敛 `rdma_qp_lifecycle_executor` 的 borrowed-owner 绑定路径：先验证主
mapping 与全部 backing segment 的 Function authority，再在 detached handle 上
准备所有 owner，最后一次性发布。任一 segment 不合法或 canonical postcheck 失败
都恢复旧 owner，不留下“主 mapping 已换、第二 segment 未换”的半提交状态。

## 变更边界

- `src/core/rdma_qp_lifecycle_executor.sv`：owner 绑定改为全量预校验、候选 clone、
  一次性提交和失败恢复；外部 mapping/segment 生命周期仍由原拥有者管理。
- `tests/unit/rdma_qp_lifecycle_test.sv`：增加 malformed second-segment 场景，断言
  失败后主 mapping 与全部 segment owner 均保持原值。

## 验证

`rdma_qp_lifecycle_test` 通过 `scripts/run_vcs53.sh core` 在
`ubuntu@10.11.10.53` 登录 bash 环境执行，wrapper rc=0，PROCESS/LOGICAL=1/1，
UVM warning/error/fatal=0/0/0。日志：
`.superpowers/sdd/2026-09-17-rdma-structural-refactor/evidence/post-batch94-rdma_qp_lifecycle_test.log`。

该日志 SHA-256：
`1268a8f136294022f909ceac0af53371b1cf9f5b58e0a2aea502608a322ed533`。

本批未修改外部依赖、未提交或 push；后续 parent gate 与全目录复审仍需在最终
源码边界重新执行。
