# Batch169 queue-data detached result models report

## 目标

把 queue-data engine 文件开头的四类公共结果对象移到独立 transaction-model 文件，
让 SQ/RQ/CQ/EQ facade 共享清晰的 detached value boundary，并缩小 engine 的实现入口。

## 实现

- 新增 `src/core/rdma_queue_data_transaction_models.sv`，定义
  `rdma_queue_post_result`、`rdma_queue_device_publish_result`、
  `rdma_queue_completion_result` 和 `rdma_queue_event_result`。
- `rdma_core_pkg.sv` 在 runtime transaction models 之后、queue-data/backing engine 之前
  include 新文件；`rdma_queue_data_engine.sv` 删除四个结果类定义，只保留 attachment、
  route、poll/post/recovery 与 runtime mutation。
- 结果类只拥有自身 handle/image/status/slot 快照，不保存 runtime、registry、mapping、
  manager 或外部 adapter 引用；返回字段和构造默认值保持不变。

## 验证

- VCS53 `rdma_queue_data_engine_poll_test`：PROCESS/LOGICAL PASS，UVM 0/0/0。
- VCS53 `rdma_queue_data_engine_post_test`：PROCESS/LOGICAL PASS，UVM 0/0/0。
- VCS53 `rdma_queue_data_engine_recovery_test`：PROCESS/LOGICAL PASS，UVM 0/0/0。
- VCS53 `rdma_queue_data_engine_device_publish_test`：PROCESS/LOGICAL PASS，UVM
  WARNING/ERROR/FATAL 为 0/0/0（保留既有 TPREGR informational overrides）。
- VCS53 `rdma_queue_event_route_consume_test`：PROCESS/LOGICAL PASS，UVM 0/0/0。

## 未关闭边界

queue-data 全量 parent/core regression、跨队列并发、SRQ 全生命周期、legacy descriptor、
外部 ordering/error、engine-level 全局锁和最终 ownership 审计仍保持 OPEN；项目级计划继续
为 `active`。
