# CMQ Batch 128：CEQ/AEQ poll consumer commit seam 提取

本批基于 Batch127，把 `poll_ceqe_once()` 与 `poll_aeqe_once()` 在 detached event
candidate、pending 和 consumer doorbell preparation 完成之后的重复副作用阶段提取为
受保护 task。目标是让两类事件队列共享同一条 admission、MMIO evidence、CI commit 和
recovery completion 顺序，同时保持各自的 route/secondary-owner 语义与 CQ 专用 WQE
release 边界。

## 实现边界

- `src/core/rdma_queue_data_engine.sv`
  - 新增 `commit_event_poll_candidate()`，集中承载
    `enter_recovery_prepared()`、consumer doorbell、MMIO evidence 归一化、
    `enable_recovery_commit_noalloc()`、`commit_cq_consumer()`、failure evidence、
    `complete_consumer_recovery_noalloc()` 和最终 route-miss/result publish。
  - `poll_ceqe_once()` 继续负责 CEQE read/decode、CQN route miss、event status/result
    candidate、pending 与 descriptor preparation；`poll_aeqe_once()` 继续负责 AEQE
    epoch gate、ecode class、CQ flush 双 owner、event candidate 与 pending preparation。
  - helper 只消费 caller 冻结的 attachment/cursor/pending/result 引用，不取得 queue、
    backing、route handle 或 event model 的生命周期所有权；`deliver_found=0` 时确认
    ring entry 但保持 result 为 null。CQ poll 的 CQ→WQ bilateral release 不进入该 helper。

## 保持的不变量

- `enter_recovery_prepared()` 仍是 CEQ/AEQ live poll 的第一个 runtime mutation；之后
  只能沿同一 `pending.failure_status` continuation 前进，不能由 caller 重建 descriptor
  或重发已提交的 doorbell。
- doorbell submit → MMIO evidence → consumer CI commit → recovery completion 的顺序和
  `NO_SUBMIT`/`AMBIGUOUS`/`SUCCESS` 证据语义不变；null/incomplete scheduler success
  继续归一化到预建 noalloc status slot。
- CEQ/AEQ route miss 仍是可确认的 stale/unknown event：codec/owner 校验成功后推进
  consumer，但丢弃 payload；真实 decode、route、result 或 pending preparation 失败仍
  保留 ring entry，不进入 helper。
- helper 不与 Batch124 的 frozen consumer-release task 或 Batch127 的 live CQ poll
  commit task 合并；事件队列没有 CQ completion target/WQE release 阶段。

## 验证

所有 VCS 仿真均通过 `ubuntu@10.11.10.53` 登录 bash 的
`SSHPASS=123 scripts/run_vcs53.sh core <test>` 执行；当前源码边界结果如下：

| 入口 | 结果 |
| --- | --- |
| `rdma_queue_data_engine_poll_test` | PROCESS PASS、LOGICAL PASS；UVM warning/error/fatal `0/0/0` |
| `rdma_queue_event_route_consume_test` | PROCESS PASS、LOGICAL PASS；UVM `0/0/0` |
| `rdma_aeqe_route_test` | PROCESS PASS、LOGICAL PASS；UVM `0/0/0` |
| `rdma_aeqe_f5_e2e_test` | PROCESS PASS、LOGICAL PASS；UVM `0/0/0`（含 F5 双路/width fixture） |
| `rdma_queue_data_engine_recovery_test` | PROCESS PASS、LOGICAL PASS；UVM `0/0/0` |
| `git diff --check` | PASS |
| changed-SV style | PASS（`python3 tools/check_changed_sv_style.py --base HEAD`） |
| 全目录中文契约/文件头 scanner | `src/` + `tests/`：185 个 `.sv`、2 个 `.svh`，5,412 个 function/task，0 diagnostics |

Python `pytest` 仍受环境缺少 pytest 包阻断，未把该环境状态计为业务 GREEN；
`pcie_work` 唯一外部阻断文本继续保持：
`external dependency is not approved: pcie_work`。

## 源码指纹

| 文件 | SHA-256 |
| --- | --- |
| `src/core/rdma_queue_data_engine.sv` | `287d924336a5ec4512948ab434df605df2eafc33bb21f01721b8a2bf2459c567` |
| `docs/rdma-structural-refactor-coverage-matrix.md` | `443687482588da672a9b169915b496a2af651351395f04b295ff9e65092f8d0e` |
| `docs/superpowers/plans/2026-09-17-rdma-structural-refactor.md` | `20ee0bbf273f047123e12a49d8dcb5b96667d9fa7b4c4efdeaa792355dc5c5f3` |

相对 Batch127，本批在 queue-data engine 新增一个共享 event-commit task，删除 CEQ/AEQ
两份重复的约 80 行副作用块；该局部计数不代表 RQ/SRQ/UD 正向 poll、legacy descriptor、
malformed retry、staged WQ 二次 geometry/role revalidation、engine-level 全局锁、跨队列
并发或整个 structural refactor 已完成。

## 遗留边界与 full-file review

- 已从 `src/core/rdma_queue_data_engine.sv` 文件头复审至 EOF，确认新 task 的输入快照、
  noalloc status、MMIO evidence、failure continuation、route-miss result 语义与 CEQ/AEQ
  caller 的职责边界一致；未修改外部依赖或 runtime ledger 所有权。
- RQ/SRQ 与 UD 正向 poll 端到端矩阵、legacy descriptor branch、CEQ/AEQ malformed
  retry、staged WQ 二次 geometry/role hostile fixture、poll/recovery 全阶段组合、
  engine-level 全局锁、CQ→WQ 跨队列并发、SRQ 全生命周期、device+consumer 组合和最终
  ownership 审计仍 OPEN；计划继续保持 `active`。
