<!-- 目录：项目根目录；职责：记录 Batch212 QP recovery progress OCC 重构与验证证据。 -->

# Batch212：QP recovery progress OCC 提交

## 改动

- `qp_progress_snapshots()` 新增 `epoch_snapshot`、`source_resource` 和
  `source_recovery` 输出；source 仅为 manager 账本的非拥有引用。
- `commit_qp_progress()` 在最终 mutation guard 内复核 epoch、registry/recovery source
  引用和 detached QP/recovery validate，任一证据不一致都 fail-closed，不写回任何一账。
- 成功提交同步安装 QP registry 与 ERROR recovery 快照，并推进 `publication_epoch`；
  flush、owned-backing cleanup、context cleanup 三个入口只传递 snapshot 证据，业务顺序
  和外部 backing 所有权不变。

## 验证

- `./scripts/run_vcs53.sh core rdma_resource_manager_test`
  - PROCESS PASS / LOGICAL PASS
  - UVM `INFO=3, WARNING=0, ERROR=0, FATAL=0`
  - 日志：`/tmp/rdma_batch212_resource_manager.log`
- `./scripts/run_vcs53.sh core rdma_qp_lifecycle_test`
  - PROCESS PASS / LOGICAL PASS
  - UVM `INFO=3, WARNING=0, ERROR=0, FATAL=0`
  - 日志：`/tmp/rdma_batch212_qp_lifecycle.log`
- Batch211 修改后的 core 回归：97/97 PROCESS、80/80 LOGICAL；integration 10/10 pristine。
- `python3 tools/check_changed_sv_style.py --base HEAD`：PASS
- `git diff --check HEAD`：PASS

## 未关闭边界

QP recovery 其它状态写回仍有直接 registry/recovery 路径；allocator/registry 跨线程或跨
进程完整互斥、manager 其它外部调用窗口、SRQ 全生命周期、跨 queue/engine 原子性、SQD/SQE
drain/flush、legacy descriptor、PCIe ordering/error/backpressure、Phase-1C F2 whole-plan
与最终 ownership 审计继续保持 OPEN。
