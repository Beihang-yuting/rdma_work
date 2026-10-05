# Batch173：CEQ/AEQ consumer doorbell recovery exactly-once

日期：2026-09-24。基线：`feature/rdma-cmq-structural-phase2-batch160`。

## 目标

补齐 Batch172 malformed decode 之后仍开放的 CEQ/AEQ consumer doorbell
`NO_SUBMIT` recovery 组合证据。测试不改变生产 engine 的 owner 或副作用顺序，
只复用已有 `rdma_queue_data_engine_ordering_fault` seam 注入一次确定性 doorbell
失败，再经公开 `recover_queue()` 重放同一 detached pending。

## 实现

`tests/unit/rdma_queue_event_route_consume_test.sv` 新增
`check_event_doorbell_failure_recovery()`，在真实 CEQ/AEQ topology 上分别覆盖：

- 首次 poll 返回失败、result 为空、`RDMA_QUEUE_MMIO_NO_SUBMIT` pending 被保留；
- 未携带 caller confirmation 的 retry 返回 `RDMA_SC_INVALID_ARGUMENT`，不触碰
  doorbell 或 cursor；
- 携带 confirmation 的 retry 恢复同一 entry，doorbell 次数从一次失败调用增加到
  恰好两次，CI/occupancy 清空且 pending 完成；
- recovery 完成后再次 retry 返回 `RDMA_SC_INVALID_STATE`，doorbell 不重复提交。

CEQ 与 AEQ 仍由各自 caller 保留 route、result delivery 和 queue owner；新增测试只
验证公共 `commit_event_poll_candidate()`/`replay_consumer_pending()` 的 exactly-once
边界，没有复制 runtime ledger、lock、resource 或外部 adapter 所有权。

## 验证

```text
DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common \
SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_event_route_consume_test
PROCESS PASS logical=rdma_queue_event_route_consume_test physical=rdma_queue_event_route_consume_test
LOGICAL PASS logical=rdma_queue_event_route_consume_test processes=1
UVM warning/error/fatal = 0/0/0
```

本地 `python3 tools/check_changed_sv_style.py --base HEAD` 与 `git diff --check` 均通过。
完整 queue lifecycle regression 在本批测试加入前已运行至 integration tail，已观察到
全部已输出 scenario PASS；加入本批后仍需再刷新完整 parent/core/integration 汇总，不能
把本 focused 结果解释为整个项目级计划完成。

## 未关闭项

跨队列/跨线程并发、SRQ 全生命周期、legacy descriptor、外部 PCIe ordering/error、
engine-level 全局锁、Phase-1C F2 whole-plan canonical authority 和最终 ownership/
中文注释审计继续保持 OPEN。
