# CMQ Batch 65-A — QDE CQ recovery route identity seam reuse

计划：`docs/superpowers/plans/2026-09-17-rdma-structural-refactor.md`。本批保留工作树中的全部既有脏改动，不提交、不 push、不修改外部依赖。

## 结果：GREEN

本批在 `replay_pending` 的 CQ consumer-recovery route 选择阶段，将四处 direct
`same_instance` 统一改为既有 `same_handle_instance`：

- routed completion QP 与 `pending.routed_qp_h`；
- SQ `send_cq_h` 与 pending CQ handle；
- 非 SRQ RQ `recv_cq_h` 与 pending CQ handle；
- SRQ `recv_cq_h` 与 pending CQ handle。

所有比较仍位于 attachment/pending、completion target、QP kind、route/epoch 和对应
null 门禁之后。routed-QP 身份失配仍返回 `STALE_GENERATION`；SQ/RQ/SRQ route 失配仍
返回各自原 `INVALID_STATE` 文本。helper 不改变 `lookup_attachment`、release-range
校验、WQE release、completion commit 或任何 runtime/backing/ledger 状态和所有权。

Batch65-A 边界 source SHA：

- before：`f2bb8b983702c5ba76c43498df5fafddec407856d936aa11a683e4c57a8fe6cc`；
- after：`b583e69ded524693a8944bd71117fb16737ab23bff6a565c1f388d8a6ed09daf`；
- 行数：9290 → 9297；
- 精确 source diff SHA：`b0b21764dc3c7917126802980ffab57ef54c0ac734254e7e0b484b1fa98c263d`。

`recover_queue` 的 unclaimed/claimed/reservation-only 三处 scan 仍保持 direct
comparison，作为后续 Batch65-B 独立审查边界。

## 结构审计与静态验证

- source review：`evidence/batch65a-source-review.log`，SHA
  `f849049093c573c71503dd67dd4e1fe133a547718d32ec0ce644f59d18bcbd4e`；
- before/after archive SHA 分别为
  `d90ce254e9ad9852b153714f48c4412d00074f52719e36045a2097a0777f1268` /
  `ff10a97d502aa42f7cebee9c7cb731bde3b472c36f69dae0f4764b847aeaff7d`；archive
  validation 日志 SHA
  `bde6dd13d33ab837c81c1af1bf80bb2bf44f2fb67d8a28c649cac077dcd1c09b`，成员与边界
  source SHA 均匹配；
- `git diff --check`：rc 0，日志 SHA
  `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`；changed-SV
  style rc 0，仅既有 `src/model/rdma_cmq_body_value_contract.sv:303` soft-limit hint，
  日志 SHA `90c5fc7d1938676c9f36c248151b419ff906e11059992d17e698542762ab2328`。

## VCS53 验证

所有仿真均通过 `ubuntu@10.11.10.53` 登录 bash 的 `scripts/run_vcs53.sh` 执行：

- `rdma_queue_data_engine_recovery_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格
  UVM 0/0/0，日志 SHA
  `d874f6fc8be42fb4a80249c435646d1a46fe6b57a68e84c94db6d0075a892e06`；
- `rdma_queue_data_engine_device_publish_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、
  严格 UVM 0/0/0，日志 SHA
  `5e12af87d3bc3ce430cbbc9f7e7ef92283775ec7d5afa974b23618fd23bd7adf`；
- 完整 `cmq_gate regression`：wrapper rc 0、PROCESS 28/28、LOGICAL 11/11、无
  gate FAIL、严格 UVM pristine 28/28，日志 SHA
  `7ee61a93e50efd2db27c4deb6eb62af00269c03a9c8ac18d16a1c7323db76b81`。

## Python / manifest

- `python3 -m unittest discover -s tests/unit -p 'test_*.py'`：292/292 OK，日志 SHA
  `3bc3ee7d9560f5fa6fe6581905cdc7df190f2c2f93e9943d581c5bca467379a7`；
- `python3 -m unittest tests.unit.test_cmq_gate_manifest`：22/22 OK，日志 SHA
  `97eb0c46c57c161ff093001e7e055064ded1af05dd72d738923510c6bbb2a19a`。

## 交付边界

本批没有改变 CQ recovery 的状态迁移、route/epoch authority、Host-memory/MMIO 顺序、
锁、reset epoch、错误码或资源所有权。Batch65-B 将单独处理 `recover_queue` 三处
skip-vs-fail identity scan；CMQ command-snapshot、queue-data resize/reset、runtime 深层
recovery/MMIO、resource-manager 其余 direct identity、Phase 1C F2 和最终结构复审仍未
完成，整份结构重构计划不能标记完成。
