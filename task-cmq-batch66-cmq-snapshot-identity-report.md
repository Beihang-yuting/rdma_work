# CMQ Batch 66 — CMQ command snapshot identity seam reuse

计划：`docs/superpowers/plans/2026-09-17-rdma-structural-refactor.md`。本批保留工作树中的全部既有脏改动，不提交、不 push、不修改外部依赖。

## 结果：GREEN

在 `src/core/rdma_cmq_engine.sv` 的
`snapshot_command_with_profile_locked` 中，将 candidate Function shell 的唯一 direct
`same_instance` 比较改为 engine 已有的 `same_handle` protected seam。`same_handle` 继续
转发 `rdma_cmq_same_handle_instance`；因此完整 kind/Function UID/object ID/generation
比较保持一致，同时获得共享 helper 的 null-safe false 语义。

source/context/profile/exact-type、body snapshot/value/detach、nested shell、owner、cast
和 alias 门禁顺序均保持；identity 失配仍返回 `RDMA_SC_INVALID_ARGUMENT` 及原错误文本。
调用方 `snapshot_journal_record_with_profile_locked` 与
`snapshot_recovery_request_locked` 的锁、journal、profile、runtime、backing 和所有权
边界不变。

Batch66 边界 source SHA：

- before（仅反向恢复本 seam 一行）：`38f8bcac37c21001c91f52c2e70362aa4ea68c36f5d889beda9c20065ec94e3f`；
- after：`bc40f74eb504f70673d42774efc2b9a1f7eafeeb86504b110d398747cfa6cfd3`；
- 行数：14222 → 14222；
- 精确 source diff SHA：`b851d8ecebede34b44dd0691f82aaae1dee9ea1ab4c5bb1240f662338024810f`。

## 结构审计与静态验证

- source review：`evidence/batch66-source-review.log`，SHA
  `18443274bf4a547e42d3dc00d3d828318741eed5fabfa7ec762d6892943b6ed9`；
- before/after archive SHA 分别为
  `d33983b265eb8841c3a31e08e082068d8f5ca8a945f8ca9893dc37110b7c0796` /
  `f75c26a587f50a952ba7f3361962b9b1c9fc7a9f1752629efe17b9b5033b21c4`；archive
  validation 日志 SHA
  `947b4118eb9977aa8233552a0c11d44384e811dedda04559ef2375f9238936e5`；
- `git diff --check`：rc 0，日志 SHA
  `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`；changed-SV
  style rc 0，仅既有 `src/model/rdma_cmq_body_value_contract.sv:303` soft-limit hint，
  日志 SHA `90c5fc7d1938676c9f36c248151b419ff906e11059992d17e698542762ab2328`。

## VCS53 验证

所有仿真均通过 `ubuntu@10.11.10.53` 登录 bash 的 `scripts/run_vcs53.sh` 执行：

- `rdma_cmq_engine_models_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格 UVM
  0/0/0，日志 SHA
  `9992208fd0a018278d4abb72db9fd428b33e3734804b793164a88039fd79f64c`；
- `rdma_cmq_engine_test`：wrapper rc 0、PROCESS/LOGICAL 18/18、严格 UVM pristine
  18/18，日志 SHA
  `8bb635bf17a9d9ffa60c02ca86fe10c862cdbfb4a7a60049c866acc0ea08a56e`；
- 完整 `cmq_gate regression`：wrapper rc 0、PROCESS 28/28、LOGICAL 11/11、无
  gate FAIL、严格 UVM pristine 28/28，日志 SHA
  `8caeb094e0b6875fc0b37fa27566d1084cccf90ad07b5fddd96045a4f13bcc36`。

## Python / manifest

- `python3 -m unittest discover -s tests/unit -p 'test_*.py'`：292/292 OK，日志 SHA
  `fc27c7c3ca166fc6b30486ab6fcb0f9f31560d9c5694f5f8c178c337165de200`；
- `python3 -m unittest tests.unit.test_cmq_gate_manifest`：22/22 OK，日志 SHA
  `6a54ce1874e9f784d6c02e1c3c6ec79ae343f00119ae1b07bcf03036eddfd9b4`。

## 交付边界

本批没有改变 command snapshot 的 wire/body/profile 语义、lock、journal、reset epoch、
runtime/MMIO 或资源所有权。QDE Batch65-A/B 已完成其 direct identity caller 收敛；
CMQ 其余较深的提交/恢复/复位结构、runtime/resource-manager 以及 Phase 1C F2 仍开放，
整份结构重构计划不能标记完成。
