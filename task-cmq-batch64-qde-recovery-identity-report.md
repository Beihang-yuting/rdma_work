# CMQ Batch 64 — QDE recovery identity seam reuse

计划：`docs/superpowers/plans/2026-09-17-rdma-structural-refactor.md`。本批保留工作树中的全部既有脏改动，不提交、不 push、不修改外部依赖。

## 结果：GREEN

本批在 `src/core/rdma_queue_data_engine.sv` 的三个低风险 recovery identity guard
中复用既有 `same_handle_instance`：

1. `post_recv` 的 SRQ link 与冻结 target handle；
2. `replay_pending` device reservation 的 pending queue 与 attachment queue；
3. `replay_pending` consumer evidence 的 attachment queue 与 pending queue。

三处比较都位于既有 status/kind/null 门禁之后。helper 只比较完整 handle
incarnation（kind、Function UID、object ID、generation），不改变 route、reset epoch、
attachment lifecycle、reservation、runtime、backing、ledger 或锁语义。SRQ lookup、replay
image、route query、reservation release 和 completion 变更的顺序保持不变；原有
`INVALID_ARGUMENT`、`RECOVERY_REQUIRED`、`INVALID_STATE` 错误优先级保持不变。

Batch64 边界 source SHA：

- before：`ca6b67a381cd43dcf6a272df04681ded478ea26a0cd268d3557df500f26ef42a`；
- after：`f2bb8b983702c5ba76c43498df5fafddec407856d936aa11a683e4c57a8fe6cc`；
- 行数：9282 → 9290；
- 精确 source diff SHA：`9f9c077c8d58a5a3b22fadcb3f39618f08a803cbab42b35be4703218f4c39d6e`。

随后批次尚未修改该文件；其余七个 direct caller（CQ recovery routed-QP/CQ route
以及 `recover_queue` unclaimed/claimed/reservation-only scans）已单独记录为 Batch65
候选，不纳入本批。

## 结构审计与静态验证

- source review：`evidence/batch64-source-review.log`，SHA
  `9d260b337973ac66f9d4ce4b3b681a649e83e44233f7e9b266fc43e6fff63796`；
- 精确 diff：`evidence/batch64-source.diff`，SHA
  `9f9c077c8d58a5a3b22fadcb3f39618f08a803cbab42b35be4703218f4c39d6e`；
- before/after archive SHA 分别为
  `14afb0ed9a0ea8c91927b067acac120b62cd01a3e4ba06ae7ca8c399e5c909a7` /
  `8428db7157562634a0955964779a7ccdc20dcc130d1a89e2213f5297c2534ce6`；archive
  validation 日志 SHA
  `ebc6533f4df63bad86bdf5e3762a7029f841b3a42cd76954e1a1835111892935`，成员与边界
  source SHA 均匹配；
- `git diff --check`：rc 0，日志 SHA
  `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`；changed-SV
  style rc 0，仅既有 `src/model/rdma_cmq_body_value_contract.sv:303` soft-limit hint，
  日志 SHA `90c5fc7d1938676c9f36c248151b419ff906e11059992d17e698542762ab2328`。

## VCS53 验证

所有仿真均通过 `ubuntu@10.11.10.53` 登录 bash 的 `scripts/run_vcs53.sh` 执行：

- `rdma_cq_engine_resize_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格 UVM
  0/0/0，日志 SHA
  `1f456d5232299d597811c3022b56d8024ddcb29eaa8635e229e3f8d6c9378b73`；
- `rdma_queue_data_engine_recovery_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格
  UVM 0/0/0，日志 SHA
  `203518c7dfb6f642150c6db91098b56eb852b30b2f2b42024021112ab24023fd`；
- `rdma_queue_lifecycle_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格 UVM
  0/0/0，日志 SHA
  `9ebbefc60c4108bdb64daedae253a4a3a61db0e5b18a0d92e903e094ab524a1d`；
- `rdma_queue_data_engine_post_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格
  UVM 0/0/0，日志 SHA
  `e8a80e8e3a1c86454492e71ded90e8891905654f979e7df767c36662cf327fe8`；
- `rdma_queue_data_engine_device_publish_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、
  严格 UVM 0/0/0，日志 SHA
  `fc88a68ad01c44563af57f4def70c904ab8fd827b5cee9aab56552d2bc6f7414`；
- 完整 `cmq_gate regression`：wrapper rc 0、PROCESS 28/28、LOGICAL 11/11、无
  gate FAIL、严格 UVM pristine 28/28，日志 SHA
  `0858a80bfb92baac8e61e97d7092a32aa6d7de989acbaab5451dfe0522cd2cbd`。

## Python / manifest

- `python3 -m unittest discover -s tests/unit -p 'test_*.py'`：292/292 OK，日志 SHA
  `097825141e0d8e70063bc6c506b156b21d7b43ef45aae6ab5ce60cf59902d96a`；
- `python3 -m unittest tests.unit.test_cmq_gate_manifest`：22/22 OK，日志 SHA
  `172ad902d20eca1bc62eb567f2b090f41b0842699251faa788454d0848df2671`。

## 交付边界

本批没有改变 queue-data recovery 的状态迁移、route/epoch authority、Host-memory/MMIO
顺序、锁、reset epoch、generation、错误码或资源所有权。Batch65 候选 review 已保存于
`evidence/batch65-candidate-review.log`；CMQ command-snapshot、queue-data resize/reset、
runtime 深层 recovery/MMIO、resource-manager 其余 direct identity、Phase 1C F2 和最终
结构复审仍未完成，整份结构重构计划不能标记完成。
