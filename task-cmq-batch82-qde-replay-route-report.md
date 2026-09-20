# CMQ Batch 82：QDE replay_pending CQ consumer route seam

本批只修改 `src/core/rdma_queue_data_engine.sv`，复用 Batch78 已验证的纯
`qp_link_cq_route_matches(link, cq_h, rq_cqe)` helper，收敛
`replay_pending` 中 CQ completion 对 SQ/RQ/SRQ route 的重复 selected-CQ identity
判断。未改测试、外部依赖或其他源码文件。

## 实现边界

- SQ 分支将 `send_cq_h == null` 与完整 handle identity 比较替换为
  `qp_link_cq_route_matches(link, pending.queue_h, 1'b0)`。
- RQ 与 SRQ 分支均用 `qp_link_cq_route_matches(link, pending.queue_h, 1'b1)`，
  并保留各自的 `link.srq_h != null` / `link.srq_h == null` 门禁及其短路顺序。
- consumer evidence、route/reset epoch、completion target、routed-QP stale
  authority、status/error 文本、`lookup_attachment`、release validation 和完成发布
  顺序均保持 inline；helper 不检查 SRQ、epoch、状态、QPN 或错误分类。
- 同步更新 `replay_pending` 的中文设计注释，明确 helper 按方向选择 send/recv CQ
  并执行 null-safe 完整 identity 比较。

## 精确边界

- source before SHA-256：`389c110f28c7030a4cce7dd26aff23553d7149720ef1b249c0caae574af8dd64`
- source after SHA-256：`29c682b27a81dc59ecdbf45653602bec94b599c84540d64bf0a796d29a75764f`
- source lines：`9341 -> 9340`
- canonical diff（`before/src` → `after/src`）SHA-256：
  `f8c3317045911b2621edb5933d7dd37d493501f3f471da55d5319debfda046f7`
- before archive SHA-256：`be637f54b65ea43db6fec9a60cec95accbb3705adf9253bd35fe6599ee509883`
- after archive SHA-256：`6cbb7aa87b853c942d793060a2d3703faa2c8adb2f1c2c93ad7ecb04d72d9e4a`

归档、source review、archive validation、canonical diff 和 focused 测试日志位于
`.superpowers/sdd/2026-09-17-rdma-structural-refactor/evidence/batch82-*`。

## 验证

所有 VCS 仿真均通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 环境执行。

| 测试 | wrapper | logical/physical | 严格 UVM（warning/error/fatal） |
| --- | --- | --- | --- |
| `rdma_queue_data_engine_recovery_test` | 0 | 1/1 | 0/0/0 |
| `rdma_queue_data_engine_device_publish_test` | 0 | 1/1 | 0/0/0 |
| `rdma_queue_data_engine_post_test` | 0 | 1/1 | 0/0/0 |

日志 SHA-256 分别为：

- recovery：`018ab928e6cc0ccfeec55c840837001a306139021ef71ae86d6f3d2e814c4155`；
- device publish：`d30e10d3253dba346e4fde9653b31fee8448d96d2011567c9232a4145104c1be`；
- post：`ef5ebaee411e2369c9c5f3e420ce493ce783f6eeb5dd2bd9421a142f56a05843`。

changed-SV style rc 0（仅既有 `rdma_cmq_body_value_contract.sv:303` soft-limit hint），
`git diff --check -- src/core/rdma_queue_data_engine.sv` rc 0；source review 与 archive
validation 均 PASS。

本批不标记整个结构重构计划完成；Batch82 integration gate、后续 resize/recovery
authority seams、Phase 1C F2 和最终全目录注释/所有权复审仍开放。

## Integration gate 收口

Batch82 源码边界冻结后，完整 CMQ gate 在 `ubuntu@10.11.10.53` 登录 bash 环境
通过：wrapper rc 0，28/28 physical process、11/11 logical test、28/28 UVM
pristine，严格 warning/error/fatal 为 0/0/0；gate 日志 SHA-256 为
`ca8f621d3b7c82804c3bfabdbb657bc082940d05c4d2c2ffcb17be01615541c5`。
同一边界的 Python 292/292、manifest 22/22、changed-SV style rc 0 与
`git diff --check` rc 0；对应日志和哈希登记在 `evidence/batch82.meta`。

本批 integration gate 已 GREEN；后续 `resize_cq` identity seam、其他 recovery
authority seams、Phase 1C F2 及最终全目录注释/所有权复审仍开放。
