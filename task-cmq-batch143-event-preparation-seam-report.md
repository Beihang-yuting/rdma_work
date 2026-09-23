# Batch143：CEQ/AEQ prepared-consumer continuation seam

日期：2026-09-22。工作树：`feature/rdma-cmq-contract-foundation`。

本批 `src/core/rdma_queue_data_engine.sv` 当前源码 SHA-256：
`20b260200fb20c41074678cfe48c27c2a628fce1988d6ef70867ef2d5754f6ab`。

## 实现边界

`poll_ceqe_once()` 与 `poll_aeqe_once()` 在各自完成 image decode、owner/route
解析和 detached result candidate 后，原先分别维护同一段 prepared-consumer 尾逻辑：
构造 pending、准备 consumer doorbell descriptor/noalloc status，然后才进入
`commit_event_poll_candidate()`。本批提取 `prepare_event_poll_continuation()`，只收束
这段无副作用 staging：

- 保持 CEQ 的 `route_found` 和 AEQ 的 `deliver_found` 在各自 caller 中决定 payload
  是否交付，route miss 仍会确认事件但返回 `result=null`；
- 保持 `prepare_consumer_pending()` 的输入、`RDMA_QUEUE_RUNTIME_SQ` kind、cursor/image
  snapshot 和错误优先级不变；
- 保持 `prepare_consumer_doorbell()` 的 descriptor/noalloc status ownership，失败时
  不进入 scheduler；
- helper 不执行 attachment lookup、peek/read/decode/route/result clone，不写
  Host-memory/MMIO，不推进 CI/used，不建立 recovery evidence，也不调用
  `enter_recovery_prepared()`；`commit_event_poll_candidate()` 仍是两条入口的唯一
  runtime mutation/consumer commit 边界。

## 验证

以下 VCS 仿真在 `ubuntu@10.11.10.53` 登录 bash、最终源码边界执行：

| 入口 | 结果 |
| --- | --- |
| `rdma_queue_event_route_consume_test` | PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_aeqe_route_test` | PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |

`rdma_queue_data_engine_final_fix_test` 未列入当前 `core` factory/manifest，未将其无效
入口请求计入验证结果；该命令只产生了预期的 UVM `INVTST`，不代表源码失败。

静态门禁：`git diff --check`、`python3 tools/check_changed_sv_style.py --base HEAD`、
profile naming、queue lifecycle checker 和 Python unit 292/292 `OK` 均通过。全目录
中文契约 scanner 使用 `sanitize_source`/`method_ranges`/`check_method_comments`/
`check_file_header` 扫描 `src/`、`tests/`、`sim/` 的 185 个 `.sv` 与 2 个 codec `.svh`，
共 5,437 methods（`.sv` 5,435、`.svh` 2），0 diagnostics。

## 保留的边界

本批只关闭 CEQ/AEQ prepared pending/doorbell staging 的重复职责，不把 CEQ route
命中误作 AEQ payload delivery，也不合并 CQ poll 的 WQE release。CEQ/AEQ malformed
retry、doorbell failure 后 recovery exactly-once、SRQ 全生命周期、legacy descriptor、
跨队列并发、engine-level 全局锁及最终 ownership 审计仍开放；计划继续保持 `active`。
