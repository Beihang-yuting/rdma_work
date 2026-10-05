# Batch70：control-plane recovery hardware scan helper

## 审查结论

`src/core/rdma_control_plane.sv` 的 `recover_resource` 在两个位置重复遍历恢复账本：

1. `reserved_only` 判定遍历 `completed_steps`，若包含硬件阶段则取消 reserved-only 快速路径；
2. 本地清理前遍历 `pending_steps`，判断是否仍有硬件阶段未完成。

两处遍历都只读取 `rdma_control_step_is_hardware` 的结果，没有副作用，适合收敛为纯 helper。

## 本批次改动

- 新增 `recovery_has_hardware_step(recovery, inspect_completed)`：
  - `inspect_completed=1` 扫描 `completed_steps`；
  - `inspect_completed=0` 扫描 `pending_steps`；
  - `recovery == null` 或数组为空时返回 `0`；
  - 不修改恢复记录、结果、锁、CMQ 或外部资源，也不替代调用方的 authority、状态和错误门禁。
- `reserved_only` 分支改用 `recovery_has_hardware_step(recovery, 1'b1)`。
- 末尾 `has_hardware_pending` 分支改用 `recovery_has_hardware_step(recovery, 1'b0)`。

扫描顺序、默认值、错误文本、状态迁移和恢复账本持久化顺序均保持不变；while 循环中首个 pending 硬件阶段仍由既有 `first_pending_hardware_step` 选择。

## 边界与证据

source before 为 Batch68 after 快照 `e6834b25521473cb94e24c4616e9d33a159e61d8fa91227610a474d3550e3688`
（4389 行），source after 为 `454b75aed1e778633318ca78bcfc8d1a02eb54faa169d9d34ac87b0724398d1c`
（4415 行）；纯 Batch70 diff SHA 为
`7769badd6fd7edf0dd0343a8d9b03026de4f139dcba31181c0e244a6e5f1374e`。
文件头、helper 的三段中文契约注释、短路顺序和既有
`RDMA_CONTEXT_VALID` → `RDMA_MR_STATE_VALID` 工作树改动均已复审。完整 source review、archive
validation 和 before/after tar 位于
`.superpowers/sdd/2026-09-17-rdma-structural-refactor/evidence/batch70-*`。

## 验证

- `git diff --check`：通过；changed-SV style 返回 rc 0，仅保留既有
  `src/model/rdma_cmq_body_value_contract.sv:303` soft-limit 提示。
- `rdma_control_plane_test`：PROCESS/LOGICAL 1/1，严格 UVM 0/0/0；日志 SHA
  `70ed39a9089bdd469388ffc2f7b763a9adb55b229173b5665c97283cd239afcc`。
- `rdma_control_plane_cmq_engine_test`：PROCESS/LOGICAL 1/1，严格 UVM 0/0/0；日志 SHA
  `99e9c620b32d34c966496246220125a00297f8c56254e219d6f633c1e0d4219e`。
- `rdma_resource_manager_test`：PROCESS/LOGICAL 1/1，严格 UVM 0/0/0；日志 SHA
  `f8071b12ba65092cddfbdbab3d35dbbfc9e333c70aa91baf09bbbfa90df2d6cc`。
- 联合 `cmq_gate regression`：PROCESS 28/28、LOGICAL 11/11、无 gate FAIL、严格 UVM
  pristine 28/28；日志 SHA
  `10dda7b73c55f13582bc9b23297879fc8144fc90f14f8a2923fdfb26e06e1a84`。
- Python unit discover：292/292；manifest：22/22；日志和校验值见
  `evidence/post-batch70-{python,manifest,style,diff-check}.log`。

本批没有修改外部依赖、未提交或 push；runtime mutable-evidence/route、codec metadata、
resource-manager 深层 recovery、Phase 1C F2 和最终结构复审仍开放。
