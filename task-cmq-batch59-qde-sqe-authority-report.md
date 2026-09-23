# CMQ Batch 59 — QDE SQE authority instance seam reuse

计划：`docs/superpowers/plans/2026-09-17-rdma-structural-refactor.md`。本批保留工作树
中的全部既有脏改动，不提交、不 push、不修改外部依赖。

## 结果：GREEN

本批在 `src/core/rdma_queue_data_engine.sv` 的 `sqe_authority_status` 中，将三个
已经具备完整 authority/null 前置门禁的 direct handle comparison 改为既有纯 helper
`same_handle_instance(lhs, rhs)`：

- posting QP：`link.qp_h` 与 `request.qp_h`；
- FLUSH authority：`request.authority_h` 与 posting link；
- URC completion QP：`completion_link.qp_h` 与 `request.completion_qp_h`。

`ensure_handle`、`rdma_handle_authority_status`、URC 分支、`qp_links` 查找、显式
`qp_h == null` 短路、原有 `INVALID_STATE` 文本和错误优先级均保留。helper 只比较
kind、Function UID、object ID、generation；owner/transport/attachment/route/epoch
仍由 caller 负责，不改变任何资源或锁副作用。

Batch59 边界 source SHA：

- before：`e8768d3cc2e33d8fb3fda30c3a4f7bbc1cbd2ea43ee572254ce4b59561819e21`；
- after：`d290ba9f8566248e0d92557691644fb56dd0d3c3596384fed8788ff5100fb2bf`；
- 行数：9267 → 9271；direct `.same_instance(` 从 24 处降为 21 处。

随后 Batch60 已把同一文件推进至
`a7258dea85867e83300a99736933000441119e8fc3a810334d14c965c8045cc2`，因此本批
archive/current 校验明确指向 Batch59 完成瞬间。

## 结构审计与静态验证

- source review：`evidence/batch59-source-review.log`，SHA
  `de78fb2b414b4159d8bfcab2d466daf9c97e8717210e23e6f90389ecfaaac157`；精确 diff
  SHA `a40cb6d278e770d46ba1cf0e433b513d9eaef080a19960d4c98f98c1906f7dea`。
- before/after archive SHA 分别为
  `51176ba778a3bc5e42518486c4bd9d2c752303927670e93a41cd8842f7a0ddde` /
  `5e7bb6de238f1454645a252b0564365653fe33ac72af2b66630918440fb4de96`；archive
  validation 日志 SHA `08791095beb3ec798e272d3487f07dc3968903b18583b87375324f25b2bba908`。
- `git diff --check`：rc 0，日志 SHA
  `8417d76ed67274349dd6fa282450c46afbb2ad1bedebd52466f3b57544d2a533`；changed-SV
  style rc 0，仅既有 `src/model/rdma_cmq_body_value_contract.sv:303` soft-limit hint。

## VCS53 验证

所有仿真均通过 `ubuntu@10.11.10.53` 登录 bash 的 `scripts/run_vcs53.sh` 执行：

- `rdma_queue_data_engine_post_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格 UVM
  0/0/0，日志 SHA `511ee4ca2d9f1350137d8ebc44fb1d704350dd8ec6b342bc481a5761ff496a7b`；
- `rdma_queue_data_engine_device_publish_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、
  严格 UVM 0/0/0，日志 SHA
  `64512b6fcbd78b7b99c0b5a95e20ab509c96fbba2606ddfce1a39d2c6c8d0967`；
- `rdma_queue_data_engine_recovery_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格
  UVM 0/0/0，日志 SHA
  `f7669f307ef2dcdd0297f0d441e10a20ba8b3aecfb466b04f7b3665ddd831ff1`；
- `rdma_queue_lifecycle_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格 UVM 0/0/0，
  日志 SHA `d948d9afae52e65629eca212699c6d3918024583d73742e6ee7515a9fc608814`；
- 完整 `cmq_gate regression`：wrapper rc 0、PROCESS 28/28、LOGICAL 11/11、无
  gate FAIL、严格 UVM pristine 28/28，日志 SHA
  `7d3b458de4db744641235457f8d42c0f2c6b2cf5e79ee68bbe2b52e65da08578`。

## Python / manifest

- `python3 -m unittest discover -s tests/unit -p 'test_*.py'`：292/292 OK，日志 SHA
  `72ed0f57e9b7e6267776cb37b10dfe431fa66c5bc6735e5ef2bd3c5e58598a7e`；
- `python3 -m unittest tests.unit.test_cmq_gate_manifest`：22/22 OK，日志 SHA
  `694c303365803f473f1db4e88929278eb319534ccc06fee3f06b1483a4ac05e4`。

## 交付边界

本批没有改变 SQE/FLUSH/URC authority 的状态、transport/profile、attachment 所有权、
Host-memory/MMIO、reset/recovery 状态迁移或错误码。QDE detach recovery 两处 direct
seam 已在后续 Batch60 单独处理；poll/route scan、其余复杂 producer/recovery 比较、
CMQ command-snapshot、queue-data resize/reset、runtime 深层 recovery/MMIO 和 Phase 1C
F2 仍留待后续批次，整份结构重构计划尚未完成。
