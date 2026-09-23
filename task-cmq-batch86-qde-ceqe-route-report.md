# CMQ Batch 86：QDE CEQE nonzero-QPN CQ route seam

本批只修改 `src/core/rdma_queue_data_engine.sv`，在
`validate_ceqe_publish_authority` 的非零 QPN 分支复用既有纯
`qp_link_cq_route_matches`，收敛 send/recv CQ route 的重复 identity 判断。未改测试、
外部依赖或其他源码文件。

## 实现边界

- `model.qpn == 0` 的通用 CEQE 通知绕过 QP route 检查，语义保持不变。
- `find_qp_link_for_local_id` 的 status/首错顺序、`link == null` 拒绝、原
  `CEQE QPN is not associated with routed CQ` 错误码/文本及 `encode_model = null`
  清理均保持；非零 QPN 只把 send/recv selected-CQ 判断转发到
  `qp_link_cq_route_matches(link, routed_cq_h, 1'b0/1'b1)`。
- CQ authority、route epoch、CEQ dependency、profile transport、cursor/codec、
  reservation 与 publish ownership 均继续由 caller 审计；helper 不承载这些语义。
- 同步更新 CEQE 设计注释，说明 qpn==0 协议边界及 route helper 的方向/identity 职责。

## 精确边界

- source before SHA-256：`b44b840e2e2891f37592872cc17e385db09076969e375489af832e513dd691c0`
- source after SHA-256：`dadf666adecb57ed5f02c03f159085f7566c8d4161a299da3540421bb4ba4936`
- source lines：`9364 -> 9363`
- canonical diff（`before/src` → `after/src`）SHA-256：
  `f5e5fbf85d5e3d591f61db41154e83564eeda23b95ac103abdde3aef0d1b95ed`
- before archive SHA-256：`c63d59e6eb23439bade8935045c0a31270782af6c6e229bc2c9a633445f1cf9f`
- after archive SHA-256：`f4690fe37493ffc05e578bff4f75ae57f377a260834df73a8e2937f1eb11ac11`

归档、source review、archive validation、canonical diff 和 focused 测试日志位于
`.superpowers/sdd/2026-09-17-rdma-structural-refactor/evidence/batch86-*`。

## 验证

所有 VCS 仿真均通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 环境执行。

| 测试 | wrapper | logical/physical | 严格 UVM（warning/error/fatal） |
| --- | --- | --- | --- |
| `rdma_queue_data_engine_device_publish_test` | 0 | 1/1 | 0/0/0 |
| `rdma_queue_event_route_consume_test` | 0 | 1/1 | 0/0/0 |
| `rdma_eq_engine_test` | 0 | 1/1 | 0/0/0 |

日志 SHA-256 分别为：

- device publish：`9788ea2eb6caac6a6f5dfeef4da379ab6b758801f0c8633067c9184a6c4046a7`；
- event route：`1868b00b71202150411d6e67842219979f6d1e351bcc4e8f3d430181769d7a2d`；
- EQ engine：`ddcef37419264e21b257a125b6e597104b000a11bf387019998fb5b5521e90c9`。

Batch86 完整 integration gate 同样在 VCS53 通过：wrapper rc 0、PROCESS 28/28、
LOGICAL 11/11、严格 UVM pristine 28/28、warning/error/fatal 0/0/0；gate 日志 SHA-256
为 `fae66da01541f6a6aea4a5bf87fe72ad9c13a6555d6a1ef6b2500a2a4e8ab14c`。

本批不标记整个结构重构计划完成；Phase 1C F2、最终全目录注释/所有权复审、覆盖矩阵
和原修复恢复入口仍开放。
