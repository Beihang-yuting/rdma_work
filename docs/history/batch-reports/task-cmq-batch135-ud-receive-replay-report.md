# Batch135：UD receive/replay 窄闭环证据

日期：2026-09-22。工作树：`feature/rdma-cmq-contract-foundation`。

## 实现边界

本批只扩展 `tests/unit/rdma_queue_data_engine_poll_test.sv` 的公开契约 fixture，未修改
外部依赖；生产 queue-data engine 仍由既有 `post_recv()`、`recover_queue()`、
`publish_cqe()` 和 `poll_cqe()` 路径执行。fixture 显式建立 UD QP/CQ route，并避免把
基础 RC attachment 当作 UD authority。

测试闭环如下：

1. 对 UD RQ `post_recv()` 注入一次 RQE Host-memory write failure，确认首次调用失败且
   不发布 post result；
2. 读取 admission-time pending image，先用未确认 retry 验证 `RDMA_SC_INVALID_ARGUMENT`
   拒绝，再以 confirmed retry 调用 `recover_queue()`；
3. 回读 RQE backing，逐字节核对 replay image 与 pending snapshot，确认 RQ occupancy
   恢复为 1；
4. 通过公开 `publish_cqe()`→`poll_cqe()` 发布/消费 UD receive CQE，检查
   `RDMA_CQE_VARIANT_RQ_SRFQ`、QPN、WR ID、单个 released slot 以及 RQ/CQ occupancy 和
   cursor 完整释放。

## 验证

在 `ubuntu@10.11.10.53` 登录 bash 执行：

```bash
SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_data_engine_poll_test
```

结果：compile/elab/link、PROCESS/LOGICAL 均 PASS；`UVM_INFO=3`、
`UVM_WARNING=0`、`UVM_ERROR=0`、`UVM_FATAL=0`。同一源码边界下
`git diff --check` 和 changed-SV style gate 通过。

## 遗留边界

本批关闭的是一条真实 UD receive RQE write-fault→replay→CQE poll/release 窄路径，
不代表以下项目已完成：UD 多包/多队列 replay、malformed CQE/recovery 组合、legacy
descriptor 分支、CQ→WQ 跨队列并发、SRQ 全生命周期、engine-level 全局锁及最终
ownership/中文契约全目录复审。
