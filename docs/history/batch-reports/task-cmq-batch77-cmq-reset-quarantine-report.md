# CMQ Batch 77 — reset quarantine predicate seam

本批只修改 `src/core/rdma_cmq_engine.sv`，保留工作树中的其他未提交改动；不修改
测试、外部依赖、resource-manager 或 queue-data。目标是把 reset staging 中重复的
“状态属于 quarantine 集合且尚未完成 isolation confirmation”判定集中为一个纯 helper。

## 实现

新增 protected helper `reset_item_needs_quarantine(state, reset_isolation_confirmed)`。
它只读取 `rdma_cmq_submission_state_e` 与确认 bit，先复用既有
`reset_item_requires_quarantine(state)`，再排除
`RESET_QUARANTINED && reset_isolation_confirmed`；不创建 status、不取锁、不访问
journal/slot/proof/completion，也不转移外部资源所有权。

四个调用点统一使用该 helper：

- `stage_reset_candidate_locked` 的 affected-batch 扫描；
- reset proof tuple 扫描；
- reducer 的 `needs_reset` 计算；
- cancellation candidate 的 `needs_reset` 计算。

调用方原有的 null/item validation、unobserved-effect 拒绝、recovery-owner 与
completion/ticket/timeout 门禁、reducer 顺序和首错 status 均保留。已确认的
`RESET_QUARANTINED` item 仍不会重复进入 proof、reducer 或 cancellation；未确认的
同状态 item 仍会进入原有隔离流程。

## 精确边界

- source before SHA-256：`bc40f74eb504f70673d42774efc2b9a1f7eafeeb86504b110d398747cfa6cfd3`
- source after SHA-256：`48f4d83788421e2be06bde8dbce95e685a56b2ea004ea554ba74771c0f03f45b`
- source lines：`14222 -> 14236`
- Batch77 精确 diff SHA-256：`a651b8542065cc4453e6fc59958775221cbceb8b2255d8411561f247975ca928`
- 变更范围：仅一个 helper 与四处调用替换；旧的 state-only helper
  `reset_item_requires_quarantine` 保持原语义和唯一状态集合 authority。

before/after source archive、精确 diff、source review 和 archive validation 位于
`.superpowers/sdd/2026-09-17-rdma-structural-refactor/evidence/batch77-*`。

## 验证

- `git diff --check -- src/core/rdma_cmq_engine.sv`：rc 0。
- `python3 tools/check_changed_sv_style.py --base HEAD`：rc 0；仅报告既有
  `src/model/rdma_cmq_body_value_contract.sv:303` soft-limit 提示。
- 远端 `ubuntu@10.11.10.53` 登录 bash：
  `scripts/run_vcs53.sh core rdma_cmq_engine_test`：wrapper rc 0，
  PROCESS/LOGICAL `18/18`，严格 UVM warning/error/fatal `0/0/0`。
- 同一 VCS53 环境 `rdma_cmq_engine_models_test`：wrapper rc 0，
  PROCESS/LOGICAL `1/1`，严格 UVM warning/error/fatal `0/0/0`。

日志 SHA-256：

- `batch77-rdma_cmq_engine_test.log`：`30e85a083e2de4037dd2197b2c7374483d4757aa18d4a7ac21a209890fa24628`
- `batch77-rdma_cmq_engine_models_test.log`：`0460c7075dce9b7b2b9ad69645f71c9b025724e6be0bd61746f5cb947909d0b9`

本批不标记整个结构重构计划完成；完整 CMQ gate 和跨目录最终复审仍由主代理统一安排。
