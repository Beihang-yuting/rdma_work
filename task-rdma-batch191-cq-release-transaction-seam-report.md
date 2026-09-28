# Batch191：CQ→WQ release transaction seam

日期：2026-09-24

## 变更

`rdma_queue_data_engine` 的 live CQ poll 与 consumer recovery retry 原先各自实现
`begin_consumer_release_noalloc()`、WQ release、`finish_consumer_release_noalloc()` 和
失败 evidence 记录。两条路径的锁序和状态语义相同，却容易在 gate 清理、失败状态或
MMIO evidence 映射上发生漂移。

本批新增 `execute_consumer_wqe_release()`，以 detached pending、CQE 或冻结
completion index/wrap 为输入，统一执行该事务骨架；caller 仍决定 poll/recovery 的
业务阶段和 shadow/doorbell evidence，runtime 仍是唯一 mutable owner。原有
`release_consumer_pending_wqe()` 保留为 recovery 兼容入口，只委托公共 task，未改变
public API、CQ→SQ/RQ/SRQ 锁序、错误优先级或资源生命周期。

同时将 release-order policy 的未知 runtime kind 测试改为稳定的范围外 enum sentinel。
VCS 对 `enum'(X)` 会在赋值时规范化为第一个枚举值，无法作为可观察的 unknown fixture；
`3'd7` 能稳定覆盖 policy 的 fail-closed 分支。

## 验证

- `scripts/run_vcs53.sh core rdma_queue_runtime_test`：PROCESS/LOGICAL PASS，UVM
  warning/error/fatal 为 `0/0/0`。
- `scripts/run_vcs53.sh core rdma_queue_data_engine_poll_test`：PROCESS/LOGICAL PASS，
  UVM `0/0/0`。
- `scripts/run_vcs53.sh core rdma_queue_data_engine_recovery_test`：PROCESS/LOGICAL PASS，
  UVM `0/0/0`。
- `scripts/run_vcs53.sh core rdma_queue_event_route_consume_test`：PROCESS/LOGICAL PASS，
  UVM `0/0/0`；包含 routed consumer fault/override fixture。
- `python3 -m unittest discover -s tests/unit -p 'test_*.py'`：293/293 PASS。
- `python3 tools/check_changed_sv_style.py --base HEAD`：PASS。
- `git diff --check`：PASS。

完整 core/integration/host-memory 回归、最终 ownership 审计和项目级计划仍按
coverage matrix 的 OPEN 项执行，不能由本批 focused GREEN 推导为整项重构完成。
