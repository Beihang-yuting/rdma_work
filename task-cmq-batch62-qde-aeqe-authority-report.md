# CMQ Batch 62 — QDE AEQE authority instance seam reuse

计划：`docs/superpowers/plans/2026-09-17-rdma-structural-refactor.md`。本批保留工作树
中的全部既有脏改动，不提交、不 push、不修改外部依赖。

## 结果：GREEN

本批在 `validate_aeqe_publish_authority` 中将三个已经具备 found/null/kind/Function/
generation 门禁的 direct handle comparison 改为 `same_handle_instance`：CQ flush
primary route、CQ flush secondary route，以及 non-flush primary route。

flush 分支的 `model.target_h`/`secondary_target_h` 拒绝条件、route candidate 查找和
复合条件短路保持；non-flush 分支的 secondary-target 拒绝、可选 target null 语义、
Function/generation 错误优先级保持。三处比较仍发生在 encode clone、codec lookup、
producer reservation、backing write 与 commit 之前；helper 不修改 model、binding、
route snapshot、runtime、cursor、manager 或 ledger。

Batch62 边界 source SHA：

- before：`a8c4adc011a5fee1aac991df3ee8f45a620bbd07d9255fff3d353ff622f42b8f`；
- after：`248579570e201ee6d1ec25a57d17a76a81c3d21901c6b196f0ace45870f7cfb8`；
- 行数：9277 → 9279；direct `.same_instance(` 从 15 处降为 12 处。

随后 Batch63 已继续推进同一文件至
`ca6b67a381cd43dcf6a272df04681ded478ea26a0cd268d3557df500f26ef42a`，所以本批 archive
与 source/current 结论明确指向 Batch62 完成瞬间。

## 结构审计与静态验证

- source review：`evidence/batch62-source-review.log`，SHA
  `dd67a80412cda36fbe33de2c2a47e91357ccf43a2a653362d5f30f1656347b6f`；精确 diff
  SHA `7e9b77f30546e7c244fa10b06dc11f583f21f3ab58591176b5fc36832d2bf4ba`。
- before/after archive SHA 分别为
  `de16f1e452285d6757fff03cde070f0cc86c59d89e9ea450e8ba32ab8abec8e5` /
  `d6b5391b301cea829eabe2d67cd9101a36aa79c725e62fc825e7333f7236ae21`；archive
  validation 日志 SHA `ba8e59550773ac88f0ca9a824c2b4e2eee2c665cb4358eece4b337b4f23da268`。
- `git diff --check`：rc 0，日志 SHA
  `e17105b9014b337fecd0f0f6fe227dfe60cc39eb7fba325148c3e58fbfb9b4e4`；changed-SV
  style rc 0，仅既有 `src/model/rdma_cmq_body_value_contract.sv:303` soft-limit hint。

## VCS53 验证

所有仿真均通过 `ubuntu@10.11.10.53` 登录 bash 的 `scripts/run_vcs53.sh` 执行：

- `rdma_aeqe_route_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格 UVM 0/0/0，日志
  SHA `6523b2f9328e320603fcbac257b23772a7a8b41774ec5bbe2de05b417c6bd330`；
- `rdma_queue_event_route_consume_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格
  UVM 0/0/0，日志 SHA
  `605a2c7131050afa9dc4aab6ef1b7cd5c32156d13dfd7b29ca15a295464551de`；
- `rdma_queue_data_engine_device_publish_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、
  严格 UVM 0/0/0，日志 SHA
  `d9907b458814c32c1c5df8c97e44c3dea40ab57b32c2ba98b011079a0bb0c362`；
- `rdma_queue_data_engine_recovery_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格
  UVM 0/0/0，日志 SHA
  `331f1802cf0da376c3c29eef6731ede77089c00f5771a2329cd63d60dce31dbe`；
- `rdma_queue_lifecycle_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格 UVM 0/0/0，
  日志 SHA `bb92881ffd5ef77f56f91510c2573da0122401bb01c06c1ede312dcf8e93b6f7`；
- `rdma_queue_data_engine_post_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格 UVM
  0/0/0，日志 SHA
  `ec022e3ebd3d757b8667bbb3306cc677d1e7c8308167c680ba6851e0e71a0027`；
- 完整 `cmq_gate regression`：wrapper rc 0、PROCESS 28/28、LOGICAL 11/11、无
  gate FAIL、严格 UVM pristine 28/28，日志 SHA
  `9d68c973b34551e39b647c10a14429d17f5f8d31f9aa7bff07ca311f62e9bf68`。

## Python / manifest

- `python3 -m unittest discover -s tests/unit -p 'test_*.py'`：292/292 OK，日志 SHA
  `4441ea0b5b96733efba9ac5aa7e4a86269733b7e22f136348dbc5b72653f0dea`；
- `python3 -m unittest tests.unit.test_cmq_gate_manifest`：22/22 OK，日志 SHA
  `7858ef08aa8d44cae54925b9d2693dde0fc6fdd8590550ae06e25e0349f6a486`。

## 交付边界

本批没有改变 AEQE route authority、CQ flush 双路交付、codec/profile、producer reservation、
backing write、attachment 所有权、Host-memory/MMIO、reset/recovery 状态迁移或错误码。
CQ resize、URC/recovery 路径、CMQ command-snapshot、queue-data resize/reset、runtime
深层 recovery/MMIO 和 Phase 1C F2 仍留待后续批次，整份结构重构计划尚未完成。
