<!-- 目录：项目根目录；职责：记录 Batch211 queue progress 双账本 OCC 重构与验证证据。 -->

# Batch211：queue progress 双账本 OCC 提交

## 改动

- `rdma_queue_progress_candidate` 现在携带 snapshot 时的 `manager_epoch`、registry
  source 和可选 recovery source；这些 source 是非拥有引用，只用于 commit 前的身份复核。
- `queue_progress_snapshots()` 在 detached resource/recovery projection 前冻结上述证据，
  任何缺失 source 都 fail-closed 并清除 candidate。
- `commit_queue_progress()` 将 epoch、registry source、recovery source、resource/recovery
  validate 收束到同一个 `mutation_guard` 窗口；只有两份快照都通过才同步写回两本账，并在
  成功后推进 `publication_epoch`。
- candidate `new()/clear()` 会清除 OCC 字段；resource-manager test 的 shape 断言覆盖
  source/epoch 不会在 clear 后残留。

本批不改变 queue flush role cardinality、cleanup predecessor、SRQ SGB flush 前置、context
completion authority 或 backing 所有权；外部 clone/factory 仍在 guard 外执行。

## 验证

- `./scripts/run_vcs53.sh core rdma_resource_manager_test`
  - wrapper 返回 0
  - PROCESS PASS / LOGICAL PASS
  - UVM `INFO=3, WARNING=0, ERROR=0, FATAL=0`
- `python3 -m unittest tests.unit.test_task9_verification tests.unit.test_run_vcs53_sync`
  - 5/5 PASS
- `python3 tools/check_changed_sv_style.py --base HEAD`：PASS
- `git diff --check HEAD`：PASS
- `./scripts/run_vcs53.sh core regression`
  - 97/97 PROCESS PASS，80/80 LOGICAL PASS
  - 所有 UVM 汇总 pristine（WARNING/ERROR/FATAL 均为 0）
  - 日志：`/tmp/rdma_batch211_core_regression.log`
- `DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common ./scripts/run_vcs53.sh integration regression`
  - 10 个 integration test 全部执行并报告 pristine，退出码 0
  - 日志：`/tmp/rdma_batch211_integration_regression.log`

## 未关闭边界

QP 专用 `commit_qp_progress()` 尚未复用本批 source/epoch candidate；allocator/registry 跨
线程或跨进程完整互斥、manager 其它外部调用窗口、SRQ 全生命周期、跨 queue/engine 原子性、
SQD/SQE drain/flush、legacy descriptor、PCIe ordering/error/backpressure、Phase-1C F2
whole-plan 与最终 ownership 审计继续保持 OPEN。
