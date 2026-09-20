# CMQ Batch 83：QDE resize_cq attachment identity seam

本批只修改 `src/core/rdma_queue_data_engine.sv`，复用既有纯
`attachment_matches_queue_identity(old_attachment, runtime_queue_h)` helper，收敛
`resize_cq` 在 `query_attachment_config` 后的 runtime/attachment 完整 identity
比较。未改测试、外部依赖或其他源码文件。

## 实现边界

- 保留 `status == null || !status.ok()`、`runtime_queue_h == null` 和
  `old_attachment.queue_h == null` 的显式门禁及其首错顺序。
- 仅将 `!same_handle_instance(runtime_queue_h, old_attachment.queue_h)` 替换为
  `!attachment_matches_queue_identity(old_attachment, runtime_queue_h)`；
  `runtime_kind != RDMA_QUEUE_RUNTIME_CQ` 与 `runtime_host_produced` 继续由
  `resize_cq` caller 审计。
- `RDMA_SC_INVALID_STATE`、原错误文本、`finish_resize` 锁释放、manager/quiesce/
  backing 分配与 recovery 发布顺序均保持不变；helper 不检查 geometry、状态、
  route/epoch、producer direction 或锁。
- 同步更新紧邻设计注释，说明 helper 只负责 canonical 完整 incarnation 比较，
  runtime kind/producer direction 仍属于 caller authority。

## 精确边界

- source before SHA-256：`29c682b27a81dc59ecdbf45653602bec94b599c84540d64bf0a796d29a75764f`
- source after SHA-256：`da9d972e5bad2f0f90ed2e2e2868e473e396c737c8aaba92a374dd9cd26e8745`
- source lines：`9340 -> 9342`
- canonical diff（`before/src` → `after/src`）SHA-256：
  `9c23ea86a5f0debd2bef259054d0209f25daf75ca0b58bfefcb12b27a13c993f`
- before archive SHA-256：`6cbb7aa87b853c942d793060a2d3703faa2c8adb2f1c2c93ad7ecb04d72d9e4a`
- after archive SHA-256：`743fb97a8b7b748bc9bafd384800f189b3e9b68fd8d73773d13e9c5437653ccc`

归档、source review、archive validation、canonical diff 和 focused 测试日志位于
`.superpowers/sdd/2026-09-17-rdma-structural-refactor/evidence/batch83-*`。

## 验证

所有 VCS 仿真均通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 环境执行。

| 测试 | wrapper | logical/physical | 严格 UVM（warning/error/fatal） |
| --- | --- | --- | --- |
| `rdma_cq_engine_resize_test` | 0 | 1/1 | 0/0/0 |
| `rdma_cq_engine_test` | 0 | 1/1 | 0/0/0 |
| `rdma_cq_shadow_flush_test` | 0 | 1/1 | 0/0/0 |

日志 SHA-256 分别为：

- resize：`07e80290f74d623a4dba8338d572958608afaf49f8db00519f33d593d9a43e05`；
- CQ engine：`0255926d0ffd45b5c3e58515c6f2d655891717e7e80c71658e598c01236c3556`；
- shadow flush：`12de541a1529e5e5dc7f0c30eedc16c693e6e66844979c7c1ade59592d85a0fb`。

changed-SV style rc 0（仅既有 `rdma_cmq_body_value_contract.sv:303` soft-limit hint），
`git diff --check -- src/core/rdma_queue_data_engine.sv` rc 0；source review 与 archive
validation 均 PASS。

本批不标记整个结构重构计划完成；Batch83 integration gate、后续 recovery authority
seams、Phase 1C F2 和最终全目录注释/所有权复审仍开放。

## Integration gate 收口

Batch83 源码边界冻结后，完整 CMQ gate 在 `ubuntu@10.11.10.53` 登录 bash 环境
通过：wrapper rc 0，28/28 physical process、11/11 logical test、28/28 UVM
pristine，严格 warning/error/fatal 为 0/0/0；gate 日志 SHA-256 为
`57636b2ae0b175144b41368c39b101d6ad45e43ff18dc40d272fe6c88af522c0`。
同一边界的 Python 292/292、manifest 22/22、changed-SV style rc 0 与
`git diff --check` rc 0；对应日志和哈希登记在 `evidence/batch83.meta`。

本批 integration gate 已 GREEN；后续 pending/attachment recovery identity seams、
Phase 1C F2 及最终全目录注释/所有权复审仍开放。
