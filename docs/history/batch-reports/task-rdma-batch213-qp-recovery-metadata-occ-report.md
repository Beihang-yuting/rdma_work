<!-- 目录：项目根目录；职责：记录 Batch213 QP recovery metadata OCC 重构与验证证据。 -->

# Batch213：QP recovery metadata OCC helper

## 改动

- 新增 `commit_recovery_replacement()`，集中 recovery-only 的 key/source/epoch/validate
  校验、短 mutation guard 写回和 publication epoch 推进。
- `update_qp_recovery_progress()` 在投影前冻结原 recovery record 与 epoch，保留原有 intent、
  QPC、mapping、query-presence 和 opcode authority 比较后调用 helper。
- `retain_qp_query_mapping()` 的 owned/recovery-only mapping clone 仍在 guard 外执行，完成
  nested recovery record 投影后通过同一 helper 提交，失败不残留 mapping 或半条记录。

## 验证

- `./scripts/run_vcs53.sh core rdma_qp_recovery_test`
  - PROCESS PASS / LOGICAL PASS
  - UVM `INFO=3, WARNING=0, ERROR=0, FATAL=0`
  - 日志：`/tmp/rdma_batch213_qp_recovery.log`
- `python3 tools/check_changed_sv_style.py --base HEAD`：PASS
- `git diff --check HEAD`：PASS

## 未关闭边界

mark-error/programmed 的 registry+recovery 双写仍未统一；allocator/registry 跨线程或跨进程
完整互斥、manager 其它外部调用窗口、SRQ 全生命周期、跨 queue/engine 原子性、SQD/SQE
drain/flush、legacy descriptor、PCIe ordering/error/backpressure、Phase-1C F2 whole-plan
与最终 ownership 审计继续保持 OPEN。
