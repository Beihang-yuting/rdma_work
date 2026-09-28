# Batch207：queue cleanup recipe policy

日期：2026-09-25

## 目标

把 `destroy_locked()` 内联的 cleanup recipe cardinality、context 一致性和 reverse
release 顺序校验提取到无状态 policy，降低 executor 的业务分支阅读成本，同时保持
释放动作和 mutable owner 不变。

## 实现

- 新增 `src/core/rdma_queue_cleanup_recipe_policy.sv`，校验 flush role/phase 一一对应、
  local role 唯一性、SRQ 可选 `SRQ_SGB`、context release 标记和 `plan.refs` 逆序释放。
- policy 只读取 detached `rdma_queue_backing_plan` 与 role 队列，返回既有
  `RDMA_SC_INVALID_STATE` 文案；不读取 manager/registry/recovery/runtime，也不拥有
  backing、锁或 adapter。
- `destroy_locked()` 保留 policy recipe 生成、quiesce、CMQ flush/delete、local cleanup、
  finalize/recovery 顺序，仅以一次 `validate()` 替换原重复扫描。
- 生命周期测试新增 canonical CQ plan 与 duplicate-role hostile 矩阵，直接验证 policy
  的成功/拒绝边界。

## 验证

- `SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_lifecycle_test`：PROCESS/LOGICAL
  PASS，UVM `WARNING/ERROR/FATAL=0/0/0`。
- `python3 tools/check_changed_sv_style.py --base HEAD`：PASS。
- `python3 tools/check_queue_lifecycle.py`：PASS。
- `git diff --check HEAD`：PASS。

本批只收束 cleanup recipe 纯值 admission，不关闭 SRQ 完整 create/post/recovery/destroy
组合、allocator/registry 并发、跨 queue/engine 全局原子性、SQD/SQE drain/flush、legacy
descriptor、PCIe ordering/error/backpressure、manager 外部调用窗口、Phase-1C F2
whole-plan 或最终 ownership 审计；项目级计划仍为 `active`。
