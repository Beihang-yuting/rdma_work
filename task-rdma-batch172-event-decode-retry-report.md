# Batch172：CEQ/AEQ 共用解码与 malformed retry

## 目标

降低 `rdma_queue_data_engine` 中 CEQ/AEQ poll 前半段的重复逻辑，并锁定 malformed
image 不得提前确认、修复后只能确认一次的业务契约。

## 实现

- 新增受保护 task `decode_event_image()`，统一 CEQE/AEQE 的 codec key、registry lookup、
  decode 和 null-status 归一化。
- helper 只产生 detached model/status；runtime、cursor、pending、Host-memory、MMIO、
  recovery 和外部资源所有权仍由 event engine/caller 管理。
- `poll_ceqe_once()` 与 `poll_aeqe_once()` 继续分别保留 owner polarity、route/CQ flush、
  result candidate、doorbell 和 consumer commit 顺序。
- event-route 测试增加 CEQE/AEQE reserved-bit 注入：malformed poll 返回
  `RDMA_SC_CODEC_ERROR` 且不改变 CI、occupancy、pending 或 MMIO；恢复原始 16-byte image
  后 retry 恰好完成一次 consumer commit。

## 验证

```text
DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common \
SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_event_route_consume_test
PROCESS PASS logical=rdma_queue_event_route_consume_test physical=rdma_queue_event_route_consume_test
LOGICAL PASS logical=rdma_queue_event_route_consume_test processes=1
UVM warning/error/fatal = 0/0/0
```

```text
python3 tools/check_changed_sv_style.py --base HEAD   PASS
git diff --check                                      PASS
```

Batch171 的完整 queue lifecycle regression 在本批代码之前已完成；本批新增代码需在
最终交付前重新刷新 parent/core/CMQ/integration 全量回归。

## 保持开放

跨队列/跨线程并发、SRQ 全生命周期、SQD/SQE drain/flush、legacy descriptor、外部
PCIe ordering/error、manager 外部调用窗口补偿和最终 ownership 审计仍未关闭。
