# CMQ Batch 63 — QDE CQ resize runtime identity seam reuse

计划：`docs/superpowers/plans/2026-09-17-rdma-structural-refactor.md`。本批保留工作树
中的全部既有脏改动，不提交、不 push、不修改外部依赖。

## 结果：GREEN

本批在 QDE CQ resize 路径的 `runtime_attachment_config` guard 中，将一个已经具备
status/null/kind/producer 前置门禁的 `runtime_queue_h.same_instance(old_attachment.queue_h)`
改为 `!same_handle_instance(runtime_queue_h, old_attachment.queue_h)`。

`query_attachment_config` 的 null/非成功 status 优先级、两个 queue handle 显式 null
拒绝、CQ kind/host-produced 检查、`finish_resize(status)` 锁释放与错误路径均保持；
比较仍发生在 `begin_cq_resize`、quiesce、依赖冻结和 publish 等任何 mutation 之前。
helper 只比较完整 handle incarnation，不改变 route/epoch、attachment lifecycle、manager
或 cursor 状态。

Batch63 边界 source SHA：

- before：`248579570e201ee6d1ec25a57d17a76a81c3d21901c6b196f0ace45870f7cfb8`；
- after：`ca6b67a381cd43dcf6a272df04681ded478ea26a0cd268d3557df500f26ef42a`；
- 行数：9279 → 9282；direct `.same_instance(` 从 12 处降为 11 处。

随后 Batch64 已继续推进同一文件至
`f2bb8b983702c5ba76c43498df5fafddec407856d936aa11a683e4c57a8fe6cc`，所以本批 archive
与 source/current 结论明确指向 Batch63 完成瞬间。

## 结构审计与静态验证

- source review：`evidence/batch63-source-review.log`，SHA
  `e766d40fb6dff5d87d3788f57d6484897664f916cf3b55190d387c2c40ff5f4c`；精确 diff
  SHA `2ffe74ed0bc82e5231646f3ffca922db8c18a890b9118848bc78008f9c9e7887`。
- before/after archive SHA 分别为
  `c8473422fe3afe27e0ccedd6eef93c78ad05b781a6e7b1f301685b3b82e26860` /
  `6ee7f7b1f6ab4d0fa3041dc791456f1ae99393fdf4637a04323b02a8e99c3d97`；archive
  validation 日志 SHA `ad7949903c162a9c2f0e93f72e5927af95bcc6207c3238a7eb1778eb650fdc40`。
- `git diff --check`：rc 0，日志 SHA
  `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`；changed-SV
  style rc 0，仅既有 `src/model/rdma_cmq_body_value_contract.sv:303` soft-limit hint。

## VCS53 验证

所有仿真均通过 `ubuntu@10.11.10.53` 登录 bash 的 `scripts/run_vcs53.sh` 执行：

- `rdma_cq_engine_resize_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格 UVM 0/0/0，
  日志 SHA `6e3d05fccff78c5a2a506754d3f2ca968dfe3454b005d9cec05dec28ee8d1899`；
- `rdma_queue_data_engine_recovery_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格
  UVM 0/0/0，日志 SHA
  `26b54deefa5b4f157fbbe86fb790f1e1bd075a6115d08c70c061f546dd95f3a0`；
- `rdma_queue_lifecycle_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格 UVM 0/0/0，
  日志 SHA `29dc1cb39f90398607c4ec4a0910d20869943765f8e10c24f7377a0578726bd2`；
- `rdma_queue_data_engine_post_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格 UVM
  0/0/0，日志 SHA
  `62b0d1bf1c2618ebf61d2635a7694e3c1135831d58e29c264287b9bf4f58df04`；
- `rdma_queue_data_engine_device_publish_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、
  严格 UVM 0/0/0，日志 SHA
  `1ead1ae33e03977918c373cbb241b3af4602482f97320555894145dbfe66ea9b`；
- 完整 `cmq_gate regression`：wrapper rc 0、PROCESS 28/28、LOGICAL 11/11、无
  gate FAIL、严格 UVM pristine 28/28，日志 SHA
  `c0ea85ffd8a6e7610db559cade73eded59b1c1f5ded4969fbed33b7dbd5f5ab7`。

## Python / manifest

- `python3 -m unittest discover -s tests/unit -p 'test_*.py'`：292/292 OK，日志 SHA
  `3283d82f565455e8fbba315127bc27ab74217eb7e306d2449eb4aa9f607a3cf4`；
- `python3 -m unittest tests.unit.test_cmq_gate_manifest`：22/22 OK，日志 SHA
  `7dc43eb9649d43b4f44a4964704eb1431230b58c9cccf11cb96a425352eabde2`。

## 交付边界

本批没有改变 CQ resize lock、finish/rollback、runtime attachment config、quiesce、
Host-memory/MMIO、reset epoch 或错误码。Batch64 正在处理三处低风险 recovery identity；
其余 CQ recovery route、CMQ command-snapshot、queue-data resize/reset、runtime 深层
recovery/MMIO 和 Phase 1C F2 仍留待后续批次，整份结构重构计划尚未完成。
