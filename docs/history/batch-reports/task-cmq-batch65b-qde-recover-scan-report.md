# CMQ Batch 65-B — QDE recovery attachment scan identity seam reuse

计划：`docs/superpowers/plans/2026-09-17-rdma-structural-refactor.md`。本批保留工作树中的全部既有脏改动，不提交、不 push、不修改外部依赖。

## 结果：GREEN

本批在 `recover_queue` 的三个 attachment scan 中复用 `same_handle_instance`：

- unclaimed recovery 的 `found.queue_h` 与请求 queue handle；
- claimed attachment scan 的 `candidate.queue_h` 与请求 queue handle；
- reservation-only scan 的 `candidate.queue_h` 与请求 queue handle。

三处的语义边界不同但均保持不变：unclaimed identity 失配仍硬失败为
`RECOVERY_REQUIRED`；claimed/reservation-only scan 的 identity 失配仍只跳过候选。map
pair、candidate/runtime、reservation/status、ambiguity、abort action 和 detach 顺序均
保持原状。helper 是纯比较，不改变 recovery map、runtime、reservation、ledger、backing
或资源所有权。

Batch65-B 边界 source SHA：

- before：`b583e69ded524693a8944bd71117fb16737ab23bff6a565c1f388d8a6ed09daf`；
- after：`66443b3113f909eaf5a2e15d168c13d2c8503de9f367b595aabac4055c836394`；
- 行数：9297 → 9307；
- 精确 source diff SHA：`7cf6f271a7f175789aa77923a39115ec9a28d5e0231d2d599c1d892b92707d69`。

## 结构审计与静态验证

- source review：`evidence/batch65b-source-review.log`，SHA
  `16407935f849a9945c85d21cb1dfad2a84ae594df951ee1633ca9d9122fec36b`；
- before/after archive SHA 分别为
  `e00c6b408e095f9c4b65b1e72cb81a59554bc101e72497d500f4e034a74fd701` /
  `7a4d2499c7f46a6248a0261baa2e451316a65d57e3217806aa6261d51e5d6983`；archive
  validation 日志 SHA
  `2e4a460e32c28f776d04d20a81d723b79434461d7726ac9e31f196bb160f6602`；
- `git diff --check`：rc 0，日志 SHA
  `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`；changed-SV
  style rc 0，仅既有 `src/model/rdma_cmq_body_value_contract.sv:303` soft-limit hint，
  日志 SHA `90c5fc7d1938676c9f36c248151b419ff906e11059992d17e698542762ab2328`。

## VCS53 验证

Batch65-B focused 仿真均通过 `ubuntu@10.11.10.53` 登录 bash 的
`scripts/run_vcs53.sh` 执行。focused 与完整 gate 记录是在随后独立的 CMQ Batch66 单处
identity seam 同时存在的工作树上完成；QDE Batch65-B 的边界未被改写：

- `rdma_queue_data_engine_device_publish_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、
  严格 UVM 0/0/0，日志 SHA
  `24ff143b7a358f51139158b55316ec781fe09dedfff370b4b2ffd1869345b5f5`；
- `rdma_queue_data_engine_recovery_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格
  UVM 0/0/0，日志 SHA
  `ad5b41a1fa9aa211ffadc723595275b26956ffe9f82467382135c47b81819547`；
- `rdma_queue_lifecycle_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格 UVM 0/0/0，
  日志 SHA
  `b9f706f9e19a103f32f0a7e673a21e9f1124fcc4dd25b396f1d9974f86ddaa39`；
- 随后联合 `cmq_gate regression`：wrapper rc 0、PROCESS 28/28、LOGICAL 11/11、无
  gate FAIL、严格 UVM pristine 28/28，日志 SHA
  `8caeb094e0b6875fc0b37fa27566d1084cccf90ad07b5fddd96045a4f13bcc36`。

联合静态验证：Python 292/292（`post-batch66-python.log`，SHA
`fc27c7c3ca166fc6b30486ab6fcb0f9f31560d9c5694f5f8c178c337165de200`）、manifest 22/22
（`post-batch66-manifest.log`，SHA
`6a54ce1874e9f784d6c02e1c3c6ec79ae343f00119ae1b07bcf03036eddfd9b4`）均通过；这些日志
同时覆盖了独立 CMQ Batch66 的当前工作树验证。

## 交付边界

本批没有改变 queue-data recovery 状态迁移、route/epoch authority、Host-memory/MMIO
顺序、锁、reset epoch、错误码或资源所有权。QDE direct caller 已全部收敛到 helper；
后续工作转向 CMQ/其它业务层和结构复审，整份结构重构计划仍未完成。
