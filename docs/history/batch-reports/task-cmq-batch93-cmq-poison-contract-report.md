# CMQ Batch 93：poison 失败语义契约校正

本批复审 `rdma_cmq_engine::poison` 的失败边界并同步中文/英文设计说明；没有改变
生产逻辑。入口仍在任何诊断 staging 前清空 `late_final_fifo`，这是 fail-closed
策略：POISONED engine 不再交付可能与失效账本关联的 late-final，而 journal/已有
diagnostic authority 不被伪造或回滚。

说明现在明确区分三个阶段：

1. primary diagnostic staging；
2. trusted ticket 不一致时的无 ticket fallback staging；
3. `last_poison` 的 detached clone staging。

只有全部候选成功才安装新的 `diagnostic_fifo`/`last_poison` 并返回原始
`RDMA_SC_CODEC_ERROR`。任一阶段返回 null/失败时，不发布半成品诊断，保留已有诊断
快照，仍把 engine 置为 `RDMA_CMQ_ENGINE_POISONED` 并返回 `INVALID_STATE`；入口已
清理的 late-final 不恢复。

## 源码边界

| 文件 | SHA-256 | Git blob SHA-1 |
| --- | --- | --- |
| `src/core/rdma_cmq_engine.sv` | `6f7fa58d609bd8edc8d2fb572128a8918043339994555a53b2575db15354653f` | `f73b166fe7f8d0874770938666d00a4a0626dbb0` |

## 验证

在 `ubuntu@10.11.10.53` 登录 bash 环境运行 `rdma_cmq_engine_test` 与
`rdma_cmq_completion_test`，均要求 wrapper rc=0、PROCESS/LOGICAL PASS、严格 UVM
warning/error/fatal=0/0/0。完整日志和 SHA 记录在本批 `evidence/batch93.meta` 与
artifact 清单中。

本批未引入 staging fault fixture；下一轮若扩展测试，应覆盖同一 poll 中 late-final
先入队、随后 malformed CQE poison 的组合，以及已有 diagnostic 在 staging 失败时
保持不变。Phase 1C F2、reset coordinator 生命周期、全目录契约复审和 parent gate
仍开放。
