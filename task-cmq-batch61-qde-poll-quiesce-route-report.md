# CMQ Batch 61 — QDE poll/quiesce route-scan instance seam reuse

计划：`docs/superpowers/plans/2026-09-17-rdma-structural-refactor.md`。本批保留工作树
中的全部既有脏改动，不提交、不 push、不修改外部依赖。

## 结果：GREEN

本批在 `src/core/rdma_queue_data_engine.sv` 集中整理四个已经具备 null/route 前置
门禁的 CQ instance 比较：

- `poll_cqe_once` simulator 防御性 route 重查中的 send/recv CQ 两处；
- `quiesce_cq_dependents` 的 send/recv CQ 依赖扫描两处。

四处 direct `same_instance` 均改为 `same_handle_instance`。原有 `link == null`、QPN
筛选、send/recv CQ handle 非空短路、CQ attachment/occupancy/decode 门禁，以及 quiesce
的 begin/rollback、重复 runtime 抑制、错误优先级和状态恢复顺序均保持。需要澄清的是，
约 7112/7113 行实际属于 `quiesce_cq_dependents`；`lookup_event_cq_route_for_poll`
本身在本源码边界没有 direct `same_instance`。

Batch61 边界 source SHA：

- before：`a7258dea85867e83300a99736933000441119e8fc3a810334d14c965c8045cc2`；
- after：`a8c4adc011a5fee1aac991df3ee8f45a620bbd07d9255fff3d353ff622f42b8f`；
- 行数：9272 → 9277；direct `.same_instance(` 从 19 处降为 15 处。

随后 Batch62 已继续推进同一文件至
`248579570e201ee6d1ec25a57d17a76a81c3d21901c6b196f0ace45870f7cfb8`，所以本批 archive
与 source/current 结论明确指向 Batch61 完成瞬间。

## 结构审计与静态验证

- source review：`evidence/batch61-source-review.log`，SHA
  `f892bc0acb52424af44901555d5593306898d3c57121c456abc4c452d2d1ea2f`；精确 diff
  SHA `e5e2954619b94a6b6c0f7a8c17a0d9ed9c8790d8d0503a734bdf5db8a275c2fa`。
- before/after archive SHA 分别为
  `e05c47df63463a34edf410c4f2e53d66288631e053f8e438dc52a0d656f65c9d` /
  `93bff12a48720f0b3e1567dd04a7d9c02e9d81e0beeb4addabf7a0652b7f0252`；archive
  validation 日志 SHA `dd0a015b8a5eeae44137eda71e399eccb0f80c4a89ff3b71c110c9e9324d1470`。
- `git diff --check`：rc 0，日志 SHA
  `a0865f4f1d1fddb7d7ce3d9bcac9da15d3cab8561a8de33f380e286e81b2a6fb`；changed-SV
  style rc 0，仅既有 `src/model/rdma_cmq_body_value_contract.sv:303` soft-limit hint。

## VCS53 验证

所有仿真均通过 `ubuntu@10.11.10.53` 登录 bash 的 `scripts/run_vcs53.sh` 执行：

- `rdma_queue_data_engine_recovery_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格
  UVM 0/0/0，日志 SHA
  `63ad580ccd1eef4a8606bb80396e13a6355e2eb9548eda905581dcae0c30004c`；
- `rdma_queue_lifecycle_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格 UVM 0/0/0，
  日志 SHA `3433a1f567ccc93a0448695944c52c4da9c87bd9bf46b508611195c071a46925`；
- `rdma_queue_data_engine_post_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格 UVM
  0/0/0，日志 SHA
  `5d5b190217873a9af7f8c88ec6d08e4e8739eacff04be3f71f2b8ad87be8b1cb`；
- `rdma_queue_data_engine_device_publish_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、
  严格 UVM 0/0/0，日志 SHA
  `05dd09e9c9a6de649368ba5ead2769ecff69db8d92c9085eaa3f222960b4fbbf`；
- 完整 `cmq_gate regression`：wrapper rc 0、PROCESS 28/28、LOGICAL 11/11、无
  gate FAIL、严格 UVM pristine 28/28，日志 SHA
  `5f90c094b6a92bb3d6570f724f436a25cef2918aaefa62514d4246440fe9e1d3`。

## Python / manifest

- `python3 -m unittest discover -s tests/unit -p 'test_*.py'`：292/292 OK，日志 SHA
  `e16dc44c6fd119a94ab3e43d28199e0e44ee90bbeaf28bc60c7901d063871456`；
- `python3 -m unittest tests.unit.test_cmq_gate_manifest`：22/22 OK，日志 SHA
  `ee15fbc759f94806e02de97c82f2e8d94d78e8e9959575054b5de5adfd3be870`。

## 交付边界

本批没有改变 CQ poll cursor、route selection、quiesce/rollback 状态、attachment 所有权、
Host-memory/MMIO 或错误码。AEQE authority 三处已在后续 Batch62 单独处理；resize、
URC/recovery 路径、CMQ command-snapshot、queue-data resize/reset、runtime 深层
recovery/MMIO 和 Phase 1C F2 仍留待后续批次，整份结构重构计划尚未完成。
