# CMQ Batch 81：QDE detach attachment identity seam

本批只修改 `src/core/rdma_queue_data_engine.sv`，复用 Batch80 已验证的
`attachment_matches_queue_identity(attachment, queue_h)` 纯 helper，收敛普通 detach
与 recovery detach transaction 中重复的完整 attachment/queue incarnation 判断。未改
测试、外部依赖或其他源码文件。

## 实现边界

- `detach` 的 attachment matching scan 复用 helper；runtime 查询、pending/reservation
  门禁、锁释放、首次 mutation 前的 preflight 和“queue is not attached”错误保持原序。
- `detach_recovery_transaction` 的 expected-attachment 初始检查保留
  `queue_h`、`expected_attachment`、`expected_attachment.queue_h` 和 runtime null 门禁，
  仅将最终 identity 比较转发到 helper；原 `recovery detach attachment is invalid`
  status 不变。
- 同一 transaction 的 attachment scan 复用 helper；expected pointer 比较、锁所有权、
  abort/cancel、runtime state transition、attachment/QP-link 删除顺序保持不变。
- 同步更新两处函数契约注释，明确 helper 内部委托 canonical
  `same_handle_instance`；helper 本身不读写 runtime、recovery、cursor、lock 或 ledger。

## 精确边界

- source before SHA-256：`9c9746a05e6f7f36a2292806a367389707849d1b8f2c41aca0759f03f6b3e80f`
- source after SHA-256：`389c110f28c7030a4cce7dd26aff23553d7149720ef1b249c0caae574af8dd64`
- source lines：`9340 -> 9341`
- 精确 diff SHA-256：`3f6897551da6fd4197f0418f05229f13c843e4cab9930784f240ed70c58837c5`
- before archive SHA-256：`422dbd5ea3bf17c1bce86f55f2a9e12327cf9d713d013efc0b869089793146d7`
- after archive SHA-256：`be637f54b65ea43db6fec9a60cec95accbb3705adf9253bd35fe6599ee509883`

归档、source review、archive validation、精确 diff 和测试日志位于
`.superpowers/sdd/2026-09-17-rdma-structural-refactor/evidence/batch81-*`。

## 验证

所有 VCS 仿真均通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 环境执行。

| 测试 | wrapper | logical/physical | 严格 UVM（warning/error/fatal） |
| --- | --- | --- | --- |
| `rdma_queue_data_engine_recovery_test` | 0 | 1/1 | 0/0/0 |
| `rdma_queue_data_engine_poll_test` | 0 | 1/1 | 0/0/0 |
| `rdma_queue_data_engine_device_publish_test` | 0 | 1/1 | 0/0/0 |

日志 SHA-256 分别为：

- recovery：`6e30decad658c8427d639440cb710fdf07d35482877694c07372a5692f50b519`；
- poll：`a0442b087a313a95e677577e73effa56bb9b8eab0bd176f726bc72266298aed8`；
- device publish：`ee84597987e59eb0e83d2fbcacdd6fbb02aeb2e52dd982e6e359cf6a1d6afb5a`。

changed-SV style rc 0（仅既有 `rdma_cmq_body_value_contract.sv:303` soft-limit hint），
`git diff --check -- src/core/rdma_queue_data_engine.sv` rc 0；source review 与 archive
validation 均 PASS。

本批不标记整个结构重构计划完成；Batch81 integration gate、后续 recovery seams、
Phase 1C F2 和最终全目录注释/所有权复审仍由主代理安排。

## Integration gate 收口

Batch81 源码边界冻结后，完整 CMQ gate 在 `ubuntu@10.11.10.53` 登录 bash 环境
通过：wrapper rc 0，28/28 physical process、11/11 logical test、28/28 UVM
pristine，严格 warning/error/fatal 为 0/0/0；gate 日志 SHA-256 为
`c8bc55795db472ab085bc00eb1d7440c2f25eed488b5e7a84032d57f214256cf`。
同一边界的 Python 292/292、manifest 22/22、changed-SV style rc 0 与
`git diff --check` rc 0；对应日志和哈希登记在 `evidence/batch81.meta`。

本批 integration gate 已 GREEN；后续 QDE recovery/resize seams、Phase 1C F2
及最终全目录注释/所有权复审仍开放。
