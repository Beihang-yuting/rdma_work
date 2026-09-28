# Batch170 queue-data attachment model report

## 目标

继续缩小 queue-data engine 的实现入口，将 attachment、QP link 和 CQ resize recovery
等 detached 结构从 engine 顶层移到公共 transaction-model 文件，明确 engine 只编排
这些值与 runtime/backing owner 的交互。

## 实现

- `src/core/rdma_queue_data_transaction_models.sv` 新增
  `rdma_queue_data_attachment`、`rdma_queue_data_qp_link` 和 `rdma_cq_resize_recovery`。
- `rdma_core_pkg.sv` 在 `rdma_queue_backing_access.sv` 之后 include 新模型，保证 capability
  类型先定义后使用；`rdma_queue_data_engine.sv` 保留单一 engine class，删除三类顶层
  detached model 定义。
- 三类对象仍只保存 handle、runtime/backing capability、route/QPC context、recovery
  geometry 和 status 快照，不取得 manager、Host-memory、PCIe、mapping 或 runtime ledger
  所有权；字段默认值与原实现保持一致。

## 验证

- VCS53 `rdma_queue_data_engine_poll_test`：PROCESS/LOGICAL PASS，UVM 0/0/0。
- VCS53 `rdma_cq_engine_test`：PROCESS/LOGICAL PASS，UVM 0/0/0。
- VCS53 `rdma_eq_engine_test`：PROCESS/LOGICAL PASS，UVM 0/0/0。
- Batch169 的 post/recovery/device-publish/event focused 继续作为同一模型文件的
  交叉使用证据，均已 PROCESS/LOGICAL PASS。
- current-boundary parent regressions：CMQ gate 28/28 process、11/11 logical；core
  regression 97/97 process、80/80 logical；所有 UVM summary 均 pristine（warning/error/fatal
  为 0/0/0）。
- current-boundary integration regression：10/10 integration scenarios completed，10 个
  UVM summary 均 pristine（warning/error/fatal 为 0/0/0），使用锁定的
  `/home/ubuntu/deps_virtio/dpu_common`。

## 未关闭边界

queue-data current-boundary parent/core regression、跨队列并发、SRQ lifecycle、legacy
descriptor、外部 ordering/error、engine-level 全局锁和最终 ownership 审计仍保持 OPEN；
项目级计划继续为 `active`。
