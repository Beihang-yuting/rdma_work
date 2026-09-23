# CMQ Batch 69 — queue-runtime resize copy identity snapshot seam

计划：`docs/superpowers/plans/2026-09-17-rdma-structural-refactor.md`。本批保留全部既有脏改动，不提交、不 push、不修改外部依赖。

## 结果：GREEN

在 `rdma_queue_runtime::copy_ring_state` 中新增纯 helper
`handle_value_matches_snapshot`，将 target queue 的 kind、Function UID、object ID、
generation 四字段比较集中到一个职责点。source lock 内原有四个 scalar 快照继续保留，
因此 target lock 阶段不会释放锁后重新读取可变 source handle；`queue_h == null`、state/
direction/depth、pending/reservation/retry、route/epoch、ledger staging 和发布顺序均不变。

source before `9e687e133dd518a3ff10bbad7b0e75cdda005e440410b80936d928ab6dc2ad9a`，after
`f4a2670b5ddb4d502d0849a350eaf38722c87f1802372b64a34305763d40c8d2`（5020 → 5043 行），
精确 diff SHA `02db221ad1f22257769ec003bce1e3ba6e56a1bc82431db84de7115fe0755209`。

## 验证

- source review/archive：review SHA
  `3b42f3430306c5c81ffc00fd6c6750d711823563f00d1295a8a281122e819e18`，archive validation
  SHA `45f6aa6547dc3eca1e1bc2cba894dcd7793883c2d2f92ac042ce3b3c7ddbf857`；
- `rdma_cq_engine_resize_test`：PROCESS/LOGICAL 1/1、UVM 0/0/0，日志 SHA
  `05034509a0ba6411b6a5d74be1f42bc11772cc17462978021f1bc43b10d84bea`；
- `rdma_queue_data_engine_recovery_test`：PROCESS/LOGICAL 1/1、UVM 0/0/0，日志 SHA
  `c41623c838c36406815b47268b5be691b7128b85bdd5fad66ed6e1c0695b1d53`；
- `rdma_queue_lifecycle_test`：PROCESS/LOGICAL 1/1、UVM 0/0/0，日志 SHA
  `99b50b63411377f1bc0ae6417d851d39660a70dbd94b7c0cf29f007f39a391e6`；
- 完整 `cmq_gate regression`：PROCESS 28/28、LOGICAL 11/11、严格 UVM pristine 28/28，
  日志 SHA `68072bc2feb8e205aa9075259255b041cc52e481d765af29051cc0774bc388f0`。

Python 292/292、manifest 22/22、style rc 0（仅既有 body-value:303 soft-limit）、
`git diff --check` rc 0，均以 `post-batch69-*` 记录。

本批没有改变 runtime owner/lifecycle、reset epoch、route authority、cursor/ledger 或
resize rollback；runtime 其它 recovery/MMIO predicate、codec metadata 和 Phase 1C F2
仍开放，整份结构重构计划不能标记完成。
