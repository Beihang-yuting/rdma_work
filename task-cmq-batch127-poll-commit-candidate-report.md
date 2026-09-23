# CMQ Batch 127：CQ poll live mutation/commit seam 提取

本批基于 Batch126，把 `poll_cqe_once()` 在 detached candidate staging 和 WQ identity
relookup 之后的副作用阶段提取为独立 task。目标是让 CQ poll 的首次 runtime mutation、
MMIO/consumer commit、CQ→WQ release 和最终 completion publish 保持一个可审查的顺序边界，
同时继续把 frozen-recovery 路径与 live-CQE 路径分开。

## 实现边界

- `src/core/rdma_queue_data_engine.sv`
  - 新增受保护 `commit_cq_poll_candidate()`，接管
    `enter_recovery_prepared()`、CQC shadow/legacy doorbell、MMIO evidence、
    `enable_recovery_commit_noalloc()`、CQ consumer commit、CQ→WQ
    `begin/release/finish`、failure evidence、`complete_consumer_recovery_noalloc()`
    和最终 result publish。
  - `poll_cqe_once()` 只保留 CQ occupancy/read/decode/route、
    `stage_cq_poll_candidate()`、staged-output 检查与 admission 前的 QP/SRQ 完整
    identity relookup，然后调用 commit helper；原有 virtual
    `publish_cqc_shadow()`、`submit_consumer_doorbell()`、`commit_cq_consumer()` 和
    `release_cq_wqe()` seam 均保持可覆盖。
  - helper 使用 caller 冻结的 `cqe/link/pending/result` 非拥有引用，不取得
    attachment、queue、backing 或 handle 的生命周期所有权；不重新解析可变 CQE/route，
    也不与 Batch124 的 frozen `release_consumer_pending_wqe()` 合并。

## 不变量与明确边界

- `enter_recovery_prepared()` 仍是 live poll 首个 runtime mutation；成功 admission 后
  只沿同一 pending/failure-status continuation 前进，不能由 caller 重建或重试前序阶段。
- shadow/doorbell→CQ consumer commit→CQ→WQ release→recovery completion 的顺序不变；
  release 失败始终先完成 bilateral `finish_consumer_release_noalloc()`，再记录 recovery
  evidence，result 保持 null。
- shadow publication 返回 null status 时保留既有行为，由外层 `poll_cqe()` wrapper
  将 null attempt 归一化为 `INVALID_STATE`；doorbell/commit/release 的具体错误继续写入
  预建 noalloc slot。该 task 不承诺 engine-level 全局锁或跨队列原子性。
- Batch126 resolver 的 target authority/geometry 门禁仍在 release-range snapshot 之前，
  因而 target 不完整与 range 错误同时出现时以 fail-closed target 错误为首错；这是有意
  的 authority-first 边界，不宣称旧错误优先级完全不变。

## 验证

所有 VCS 仿真均通过 `ubuntu@10.11.10.53` 登录 bash 的
`SSHPASS=123 scripts/run_vcs53.sh core <test>` 执行；最终源码边界结果如下：

| 入口 | 结果 |
| --- | --- |
| `rdma_queue_data_engine_poll_test` | PROCESS PASS、LOGICAL PASS；UVM warning/error/fatal `0/0/0` |
| `rdma_queue_data_engine_post_test` | PROCESS PASS、LOGICAL PASS；UVM `0/0/0` |
| `rdma_queue_data_engine_recovery_test` | PROCESS PASS、LOGICAL PASS；UVM `0/0/0` |
| `rdma_queue_data_engine_device_publish_test` | PROCESS PASS、LOGICAL PASS；UVM `0/0/0` |
| `git diff --check` | PASS |
| changed-SV style / queue lifecycle / profile names | PASS |
| CMQ manifest + SV keyword guards | 25 tests；OK |
| Phase-1A approval | PASS；四项保持 APPROVED |
| Python unit tests | 292 tests；OK |
| 全目录中文契约/文件头 scanner | 185 个 `.sv`、2 个 `.svh`，5,411 个 function/task（`.sv` 5,409、`.svh` 2），0 diagnostics |

Python 单元测试中的 synthetic git/CLI negative-path stderr 属于既有预期输出；pytest 因
环境依赖未安装不计入业务 GREEN。`pcie_work` 仍保持唯一外部阻断文本：
`external dependency is not approved: pcie_work`。

## 源码指纹

| 文件 | SHA-256 |
| --- | --- |
| `src/core/rdma_queue_data_engine.sv` | `136dc926b1d20a08c753a6c7d53808129bd6bd2e7a022c415980a62b3667363a` |
| `docs/rdma-structural-refactor-coverage-matrix.md` | `28682384e44c4c9d7c7417c75f22eec50fb9e6f4127e20c1c97a38966e9c26a3` |
| `docs/superpowers/plans/2026-09-17-rdma-structural-refactor.md` | `472e9f1a485fe1fe5a50623ea63b7bffad14ee2fc5957d6d89c5a08f9c30685c` |

相对 Batch126，本批新增一个 commit task，queue-data engine 的 method/comment 复审计数
由 143 增至 144，全目录由 5,410 增至 5,411；该计数只描述局部职责边界，不代表
structural refactor、广义 Phase 1C F2 或公开 RQ/SRQ/UD poll 已完成。

## 遗留边界与 full-file review

- 已从 `rdma_queue_data_engine.sv` 文件头复审至 EOF，确认 helper 的参数所有权、
  admission/commit/release 顺序、null-status 传播、failure evidence 和 caller result
  发布边界与实现一致；未修改外部依赖或 runtime ledger 所有权。
- RQ/SRQ 与 UD 正向 poll、legacy descriptor branch、CQ route/epoch admission、
  engine-level 全局锁、poll/recovery 全阶段组合、CQ→WQ 跨队列并发、CEQ/AEQ malformed
  retry、SRQ 全生命周期、device+consumer 组合、coordinator 更深所有权审计和 `pcie_work`
  外部批准仍 OPEN。
- 计划与覆盖矩阵继续保持 `active`，不能标记为 `complete`。
