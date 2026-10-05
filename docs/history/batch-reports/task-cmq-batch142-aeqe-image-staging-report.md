# Batch142：AEQE reservation 前 image staging seam

日期：2026-09-22。工作树：`feature/rdma-cmq-contract-foundation`。

本批 `src/core/rdma_queue_data_engine.sv` 当前源码 SHA-256：
`b651f42066610ad7bdc844b1094e2a5471199648f9510710f06e814fe83d5876`。

## 实现边界

`publish_aeqe_common()` 原先把 route authority 解析、detached model clone、profile
owner authority、registry typed cast、codec encode 和 producer reservation 全部写在
同一 task。现将 reservation 之前的可失败、无 runtime 副作用阶段提取为
`prepare_aeqe_publish_image()`：

- 先复制调用方 AEQE model，并把 live primary route 复制为 encode target；
- 保持既有 profile authority、固定 AEQE codec key、registry lookup/type cast 和
  encode 顺序；
- 只接受完整的 16-byte image，失败时清空 `encode_model`/`image` 输出并返回原有错误
  分类；
- helper 不触碰 attachment、runtime、cursor、backing、pending、Host-memory 或
  MMIO，也不取得外部资源所有权。

`publish_aeqe_common()` 仍在 helper 成功后才 reserve；reserve 后的 route-epoch、polarity、
cancel/recovery 和 `write_commit_device_entry()` 顺序完全保留。CQE/CEQE 的
reserve-before-encode 语义未合并到本 helper。

## 验证

以下 VCS 仿真均通过 `ubuntu@10.11.10.53` 登录 bash，在最终源码边界执行：

| 入口 | 结果 |
| --- | --- |
| `rdma_queue_data_engine_device_publish_test` | PROCESS/LOGICAL PASS；UVM `INFO=220/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_aeqe_route_test` | PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_aeqe_f5_e2e_test` | PROCESS/LOGICAL PASS；UVM `INFO=115/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_queue_event_route_consume_test` | PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |

静态门禁同样通过：`git diff --check`、changed-SV style、profile naming、queue
lifecycle checker，以及 Python unit 292/292 `OK`。所有仿真均未修改外部依赖。

## 保留的边界

本批是 reservation 前 AEQE image staging 的局部职责收缩，不新增 codec fault fixture，
也不宣称完成 AEQE malformed retry、poll/recovery 组合、SRQ 全生命周期、legacy
descriptor、跨队列并发或最终 ownership 审计。registry null/typed-fault 的更细粒度
原子性证据仍可在后续独立批次补充；当前计划继续保持 `active`。
