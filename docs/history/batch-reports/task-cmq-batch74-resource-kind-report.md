# CMQ Batch 74 — resource-manager lifecycle queue kind seam

计划：`docs/superpowers/plans/2026-09-17-rdma-structural-refactor.md`。
本批只修改 `src/core/rdma_resource_manager.sv`，保留工作树中已有改动；不修改
测试、外部依赖，不提交或 push。

## 结果：纯资源类型分类 helper 已完成

在 `rdma_resource_manager` 中新增 protected 只读 helper
`lifecycle_queue_kind(kind)`，集中判定由 queue backing plan 参与
QUIESCING/ERROR 生命周期的四类资源：CQ、SRQ、CEQ、AEQ。helper 只读取枚举并
返回 bit，不访问 registry/recovery，不改变状态，也不取得 backing 所有权。

以下六个原本完全相同的 `inside {CQ, SRQ, CEQ, AEQ}` 判定改为调用该 helper：

- `queue_progress_snapshots` 的 queue kind/state 门禁；
- `restore_active` 的 ERROR queue 分派；
- `restore_active` 的恢复 plan 重建、pre-validate observer 和 pre-publish observer
  三处门禁；
- `mark_error_transition` 的 queue-specific recovery 分派。

`valid_kind` 保持原有更宽的可登记资源语义，未被替换。lookup、schema、projection、
opaque release proof、observer 调用点、registry/recovery 提交顺序和所有错误文本均未
改变。`queue_progress_snapshots` 函数注释与失败边界之间的多余空行同时按 style
checker 修正；该修正无功能影响并纳入本批边界。

source before：
`b094558e1fbba78277973be7c9028a7960c3650443d931feaa3fc02794ccb4b9`
（8512 行）；source after：
`3a9e29f490d63a5c4cfb8008e50c6e3b4ca7a3f515156a0186253c3b58880b77`
（8515 行）。精确 Batch74 diff SHA：
`0559b77a17c6e392e3008c05387de6440220cf02586c7d1b20d4d1b25aee8c3e`。

对应 source archive、精确 diff、审查和校验日志位于
`.superpowers/sdd/2026-09-17-rdma-structural-refactor/evidence/batch74-*`；
before/after archive SHA 分别为
`1d1ab1be90395efda1c8b485eab4e64072bc099d4ab88d2d3e049d5f06043cea` 与
`ed9dae7dd11ca2d526de77a2ad92890a9e572e669a2475fab513118c7f9b22f0`。

## 静态验证

- `git diff --check -- src/core/rdma_resource_manager.sv`：rc 0。
- `python3 tools/check_changed_sv_style.py --base HEAD`：rc 0；仅报告既有
  soft-limit 提示 `src/model/rdma_cmq_body_value_contract.sv:303`，不属于本批新增逻辑。
- `rdma_resource_manager_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格 UVM
  0/0/0；日志 SHA
  `b1e541c1d499c696582789c8c1ab35c730c507c12eabb6a0a9e285f43b75daca`。
- `rdma_queue_lifecycle_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格 UVM
  0/0/0；日志 SHA
  `ef7003602f94c6e354b1173bdf5984ee48147f81d68cef2d115f29c9007b06a4`。
- `rdma_queue_recovery_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格 UVM
  0/0/0；日志 SHA
  `14d59910bff61223e62e89fe1eed0e1a8a0cc040f59e5ca96670c0775c750248`。
- Python unit discover：292/292；manifest：22/22；日志分别位于
  `evidence/batch74-python.log` 与 `evidence/batch74-manifest.log`。完整 CMQ gate
  由主代理在批次整合后统一执行。

## 边界

helper 不替代 `valid_kind`、handle identity、resource lookup、recovery schema 或
hardware/opaque completion proof；FUNCTION、PD、MR、QP、CMQ 和未知枚举值均返回 0。
本批不标记整个结构重构计划完成，Phase 1C F2 与最终全目录复审仍开放。
