# CMQ Batch 60 — QDE detach-recovery instance seam reuse

计划：`docs/superpowers/plans/2026-09-17-rdma-structural-refactor.md`。本批保留工作树
中的全部既有脏改动，不提交、不 push、不修改外部依赖。

## 结果：GREEN

本批在 `src/core/rdma_queue_data_engine.sv` 的
`detach_recovery_transaction` 中，将两个 recovery attachment incarnation 比较改为
既有纯 helper `same_handle_instance(lhs, rhs)`：入口的
`expected_attachment.queue_h` 与 `queue_h` 比较，以及 `attachments` 扫描中的匹配比较。

入口原有 `queue_h`/attachment/runtime null 门禁、CQ resize-recovery 拒绝和
`resize_lock` 获取顺序保留；扫描仍在同一锁内收集 `matching_keys`、确认
`expected_found`，再按原顺序执行 runtime abort/cancel、attachment 删除和 QP-link 删除。
helper 只比较完整 handle incarnation，不改变 recovery state、route/epoch、ownership、
ledger 或锁副作用。

Batch60 边界 source SHA：

- before：`d290ba9f8566248e0d92557691644fb56dd0d3c3596384fed8788ff5100fb2bf`；
- after：`a7258dea85867e83300a99736933000441119e8fc3a810334d14c965c8045cc2`；
- 行数：9271 → 9272；direct `.same_instance(` 从 21 处降为 19 处。

随后 Batch61 已继续推进同一文件至
`a8c4adc011a5fee1aac991df3ee8f45a620bbd07d9255fff3d353ff622f42b8f`，所以本批 archive
与 source/current 结论明确指向 Batch60 完成瞬间。

## 结构审计与静态验证

- source review：`evidence/batch60-source-review.log`，SHA
  `aa76bf042c7468cbedf900d31ddbaa479b5d46c406b6060b1e8429207008e66f`；精确 diff
  SHA `7bd0917cf2dbf8389c3828b6898e02c3739e3104a7d26d5788d801b447ae4199`。
- before/after archive SHA 分别为
  `b0e4d1078deed9ae2c509ef60a3f2024b0911f408b94b4b837149c8db7157ed8` /
  `54fa9e5a3dfa017f311d85280bd59c25e011c4f60861043e469470cb547bc887`；archive
  validation 日志 SHA `5fc3b5aedeb391626eb348275dcaa35cfaf28bf562419f67a47048370ab82f84`。
- `git diff --check`：rc 0，日志 SHA
  `b2d978405bd3c4e9bf40f17957b21a7e341783e49d04bd500a1b1259b68441d2`；changed-SV
  style rc 0，仅既有 `src/model/rdma_cmq_body_value_contract.sv:303` soft-limit hint。

## VCS53 验证

所有仿真均通过 `ubuntu@10.11.10.53` 登录 bash 的 `scripts/run_vcs53.sh` 执行：

- `rdma_queue_data_engine_recovery_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格
  UVM 0/0/0，日志 SHA
  `1172b15cd21d02e4731dcdb595f9cafd0bd62015ac3c7ba9aedd7aef8692fadf`；
- `rdma_queue_lifecycle_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格 UVM 0/0/0，
  日志 SHA `f3d2cb9b044e2073ad725575d1741ce3fc092cc714448c2f07fb56057e664e78`；
- `rdma_queue_data_engine_post_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格 UVM
  0/0/0，日志 SHA
  `74536f2bb537ef3d4dcf806304c872f083adf62620a7a4d8051c073e8eeb997d`；
- `rdma_queue_data_engine_device_publish_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、
  严格 UVM 0/0/0，日志 SHA
  `df9fcfcb3b759dd099b40a943271e8713cbd9724539adc2d93000bccb81ca3af`；
- 完整 `cmq_gate regression`：wrapper rc 0、PROCESS 28/28、LOGICAL 11/11、无
  gate FAIL、严格 UVM pristine 28/28，日志 SHA
  `5d14dbfac727d529b6c5bc1a6ccb434589d1be50d34269023dca0ed4ceb39853`。

## Python / manifest

- `python3 -m unittest discover -s tests/unit -p 'test_*.py'`：292/292 OK，日志 SHA
  `3641dd513fe67aa6bbc13f83a2a2d1ae979cab9ffc12b943647762afcfc46786`；
- `python3 -m unittest tests.unit.test_cmq_gate_manifest`：22/22 OK，日志 SHA
  `a7c986116c37d9b4b6b8a9cca3f5b24e6030c7674cc84158398595813a6c49af`。

## 交付边界

本批没有改变 detach/recovery 的锁边界、状态迁移、错误优先级、attachment/QP-link
删除顺序、Host-memory/MMIO 或外部资源所有权。QDE poll/quiesce route-scan 四处
direct seam 已在后续 Batch61 单独处理；其余复杂 producer/recovery 比较、CMQ
command-snapshot、queue-data resize/reset、runtime 深层 recovery/MMIO 和 Phase 1C F2
仍留待后续批次，整份结构重构计划尚未完成。
