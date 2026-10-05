# RDMA Batch184：runtime lock contention characterization 报告

日期：2026-09-24

## 目标

为 queue runtime 的跨线程边界补充可重复的 lock contention 证据，确认唯一 semaphore
owner 在另一个线程持锁时拒绝并发 query，并在释放后恢复正常查询；不引入第二把锁或
改变 runtime 的 mutable owner。

## 实现

- `rdma_queue_runtime_lock_probe` 仅在测试层继承 production runtime，用于持有既有
  protected semaphore 一段受控时间；不暴露 ledger 写入口。
- `test_runtime_lock_contention()` 以 fork 两个线程覆盖 holder/query/after-release 三个
  阶段：窗口内 `query_occupancy()` 必须返回 `RDMA_SC_RESOURCE_BUSY`，释放后返回 OK 且
  occupancy 仍为零。
- 生产 `rdma_queue_runtime.sv` 未新增状态、锁或外部引用，跨线程 admission 继续由原有
  runtime semaphore 统一负责。

## 验证

- 需在本批测试同步后重跑 `rdma_queue_runtime_test` 与完整 core regression；UVM
  warning/error/fatal 必须保持 `0/0/0`。
- `check_changed_sv_style.py --base HEAD` 与 `git diff --check` 已通过。

## 未关闭边界

该 characterization 只证明单 runtime semaphore 的拒绝/恢复契约，不宣称跨 queue、跨
engine 的全局锁、SRQ 全生命周期、外部 ordering/error/backpressure 或最终 ownership
审计已经完成。
