# CMQ Batch 58 — QDE CQ route-scan instance seam reuse

计划：`docs/superpowers/plans/2026-09-17-rdma-structural-refactor.md`。本批保留工作树
中的全部既有脏改动，不提交、不 push、不修改外部依赖。

## 结果：GREEN

本批只整理 `src/core/rdma_queue_data_engine.sv` 的
`find_qp_link_for_cq`：精确 local-QPN 扫描与超宽-QPN 投影扫描各有 send/recv 一对
CQ route 比较，共四个 direct `same_instance` 调用改为既有纯 helper
`same_handle_instance(lhs, rhs)`。

两轮扫描原有 `candidate == null`、QPN/低位投影筛选、send/receive 方向选择、CQ handle
非空短路、重复命中错误和超宽 QPN 诊断全部保留。helper 只在非空时调用原始
`lhs.same_instance(rhs)`，不检查 route、epoch、状态、ownership、锁或 ledger；三个
caller（CQE authority、variant resolver、poll path）原有的 CQ/attachment/image 门禁
和错误优先级不变。

Batch58 边界 source SHA：

- before：`f1dd1e990d3c8616f23737572c41d33265df8045d344bc3656c6155c7c9d8dd6`；
- after：`e8768d3cc2e33d8fb3fda30c3a4f7bbc1cbd2ea43ee572254ce4b59561819e21`；
- 行数：9266 → 9267；direct `.same_instance(` 从 28 处（Batch57 边界）降为 24 处。

随后 Batch59 已在同一文件继续推进至
`d290ba9f8566248e0d92557691644fb56dd0d3c3596384fed8788ff5100fb2bf`，所以本批归档与
source/current 结论明确指向 Batch58 完成瞬间。

## 结构审计与静态验证

- source review：`evidence/batch58-source-review.log`，SHA
  `7752bb2d31228b339e6091718ae6ba7d893e50c7158926b775dac2ad7607b084`；精确四调用
  diff SHA `4b67d1460ee73c429a165338d75f844e30b4c8457c1c36862dadbf6ee27e6941`。
- before/after archive SHA 分别为
  `32b1ef3cd9f54032a44694dee4b09a710aa4ed38bb898ec81c5e743c029b441e` /
  `e4559852861f93455f21383bc08964e10b4791b006b903017f4131981864b411`；archive
  validation 日志 SHA `656ce2ac56feff000b349ac9af415dff24e5c3557217c382ff4630b3165ed17d`。
- `git diff --check`：rc 0，日志 SHA
  `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`；changed-SV
  style rc 0，仅既有 `src/model/rdma_cmq_body_value_contract.sv:303` soft-limit hint。

## VCS53 验证

所有仿真均通过 `ubuntu@10.11.10.53` 登录 bash 的 `scripts/run_vcs53.sh` 执行：

- `rdma_queue_data_engine_device_publish_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、
  严格 UVM 0/0/0，日志 SHA
  `0567c490c221b9f7ebdc3aa6fd08ad27b7a60bf37eceaa91d3288ff091674b8c`；
- `rdma_queue_data_engine_recovery_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格
  UVM 0/0/0，日志 SHA
  `e87c70efcf2bd0f6fbeeb8f995f3a26d630e83709e09a284cf0d1f9c92afe925`；
- `rdma_queue_lifecycle_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格 UVM 0/0/0，
  日志 SHA `9b0cfd03d52d6d7b6cd30151250c7f2090bc5e2a2acc526522a4337ce7a379fa`；
- `rdma_queue_data_engine_post_test`：wrapper rc 0、PROCESS/LOGICAL 1/1、严格 UVM
  0/0/0，日志 SHA
  `9d2dc48eac92411b79a4f8927f255cbf632288f66ecccbb347ced56f4a592f89`；
- 完整 `cmq_gate regression`：wrapper rc 0、PROCESS 28/28、LOGICAL 11/11、无
  gate FAIL、严格 UVM pristine 28/28，日志 SHA
  `32b063ceaf5fa8f831a1e5c9074a60a707299864105bf19b7fcbe6c2d5d7d440`。

## Python / manifest

- `python3 -m unittest discover -s tests/unit -p 'test_*.py'`：292/292 OK，日志 SHA
  `9747b66f838721dd582058072e1ee3852a8b2f01de8c9c5f75f602314c5b8c70`；
- `python3 -m unittest tests.unit.test_cmq_gate_manifest`：22/22 OK，日志 SHA
  `fb956c20bd0f302c1ce1c7cabba1223c621543c8dd9ba55f5f8e461ab80236d3`。

## 交付边界

本批没有改变 CQE route authority、QPN width 诊断、send/recv CQ 方向语义、attachment
所有权、Host-memory/MMIO、reset/recovery 状态迁移或错误码。QDE 的 SQE authority
三处 direct seam 已在后续 Batch59 单独处理；detach recovery、其余复杂 producer/recovery
比较、CMQ command-snapshot、queue-data resize/reset、runtime 深层 recovery/MMIO 和
Phase 1C F2 仍留待后续批次，整份结构重构计划尚未完成。
