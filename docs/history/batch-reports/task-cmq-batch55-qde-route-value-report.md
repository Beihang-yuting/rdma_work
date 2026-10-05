# CMQ Batch 55 — QDE route value comparison reuse

计划：`docs/superpowers/plans/2026-09-17-rdma-structural-refactor.md`。本批保留工作树
中的全部既有脏改动，不提交、不 push、不修改外部依赖。

## 结果：GREEN

本批只整理 `src/core/rdma_queue_data_engine.sv` 中两个已经具备完整 valid/status
门禁的 route 值比较点。

### 变更

`pending_route_epoch_matches` 将 `pending.route == runtime_route` 改为既有纯值
`same_route(pending.route, runtime_route)`；函数仍先检查 pending、两侧 route/epoch
valid 位，再比较 reset epoch。`validate_attachment_route_epoch` 将
`route != identity.route_key()` 改为 `!same_route(route, identity.route_key())`；
runtime query status、`identity.validate()`、route/epoch valid、stale status 和错误
优先级均留在 caller。

`same_route` 只比较 `host_topology_key/root_id/segment` 与完整 BDF。`rdma_route_key_t`
和 `rdma_bdf_t` 的字段均为二态 `bit`，没有 padding 或 X/Z 语义；helper 不校验 route
合法性、valid 位、epoch、Function identity，也不取得锁或写入任何对象。

## 结构审计与静态验证

- source-before/source-after SHA：
  `112f41805f46f305170da08576b5d1dcbb50201e06e1df418dc29bd579934206` /
  `5900d640d3fa981c248f09812aaa696ce356a6285a60fa605ed0a48eccf96ef`；行数
  9240 → 9244；精确 diff 仅为两个调用点和相应中文边界注释。
- 以 route 七个二态字段进行 100000 组随机等价核对，结果记录于
  `evidence/batch55-route-equivalence.log`；valid/status/epoch 门禁保持不变。
- before/after archive member 与当前 source SHA 成对一致；归档及 source review
  见 `evidence/batch55-source-review.log`、`evidence/batch55-archive-validation.log`。
- `git diff --check`：rc 0；changed-SV style：rc 0，仅既有
  `src/model/rdma_cmq_body_value_contract.sv:303` soft-limit hint。

## VCS53 验证

所有仿真均通过 `ubuntu@10.11.10.53` 登录 bash 的 `scripts/run_vcs53.sh` 执行：

- `rdma_queue_data_engine_recovery_test`：wrapper rc 0、PROCESS/LOGICAL 1/1，严格
  UVM 0/0/0；
- `rdma_queue_data_engine_device_publish_test`：wrapper rc 0、PROCESS/LOGICAL 1/1，
  严格 UVM 0/0/0；
- `rdma_queue_lifecycle_test`：wrapper rc 0、PROCESS/LOGICAL 1/1，严格 UVM 0/0/0；
- `rdma_queue_data_engine_post_test`：wrapper rc 0、PROCESS/LOGICAL 1/1，严格 UVM
  0/0/0；
- 完整 `cmq_gate regression`：wrapper rc 0、PROCESS 28/28、LOGICAL 11/11、无 gate
  FAIL，严格 UVM pristine 28/28。日志 SHA：
  `61744bdb8dd5010f51e92453d46ab512cc0895e6d62e9825396e3e2cfa335553`。

## Python / manifest

- `python3 -m unittest discover -s tests/unit -p 'test_*.py'`：292/292 OK，日志
  `evidence/batch55-python.log`；
- `python3 -m unittest tests.unit.test_cmq_gate_manifest`：22/22 OK，日志
  `evidence/batch55-manifest.log`。

## 交付边界

本批没有改变 queue attachment 的所有权、route/epoch 查询顺序、pending cursor、
Host-memory/MMIO、reset/recovery 状态迁移或错误码。CMQ direct `same_instance` seam、
queue-data resize/reset、runtime 深层 recovery/MMIO 和 Phase 1C F2 仍留待后续批次；整份
结构重构计划尚未完成。
