# CMQ Batch 124：consumer recovery CQ→WQ release seam 提取

本批继续基于 Batch123 的 consumer recovery authority preflight，只重排 recovery 路径中
已经完成 CQ consumer commit 后的 CQ→WQ release 阶段。poll 路径仍使用 live `cqe`、
`cq_shadow_required` 和自己的参数契约，本批没有把两条路径强行合并。

## 实现边界

- `src/core/rdma_queue_data_engine.sv`
  - 新增受保护 task `release_consumer_pending_wqe()`，集中执行
    `begin_consumer_release_noalloc()`、以 pending 冻结的 `completion_index`/
    `completion_wrap` 调用 `release_cq_wqe()`、null status 归一化、
    `finish_consumer_release_noalloc()` 和 release 失败 evidence 记录。
  - task 只接收 caller 已完成 authority 校验的 `attachment`、`pending` 与
    `wqe_attachment` 借用引用；`pending.failure_status` 继续作为预建 noalloc
    continuation slot。成功时由 runtime 推进 WQ CI/used，失败时保持 recovery evidence，
    不取得 CQ、WQ、QP 或外部 Host-memory 生命周期所有权。
  - `replay_consumer_pending()` 现在只保留 release seam 的调用和 status gate；shadow/
    doorbell、CQ consumer commit、最终 `complete_consumer_recovery_noalloc()` 的顺序不变。
    `pending_next_cursor()` 仍由 `replay_pending()` 在阶段分派前统一执行。

## 行为不变量与失败边界

- begin gate 拒绝时直接返回其 noalloc status，不触碰 release ledger；release 返回 null
  时归一化为 `RDMA_SC_INVALID_STATE`，再执行 bilateral finish 以避免活动 gate 遗留。
- release 成功后才允许 recovery completion；finish 失败仍以 noalloc status 收束。
  release 失败按 pending 的 `consumer_shadow_required` 选择 `RDMA_QUEUE_MMIO_NO_SUBMIT`
  或 `RDMA_QUEUE_MMIO_SUCCESS` evidence，并保留原失败 status；不会重复释放同一 frozen
  completion range。
- null `attachment`、`pending`、`wqe_attachment`、任一 runtime 或
  `pending.failure_status` 均 fail-closed 为 `RDMA_SC_INVALID_STATE`。helper 不重新解析
  CQE、不推导 WQ 方向，也不改变 poll 的 live-CQE release 语义。

## 验证

所有 VCS 仿真均通过 `ubuntu@10.11.10.53` 登录 bash 的
`SSHPASS=123 scripts/run_vcs53.sh core <test>` 执行；每项 wrapper rc 为 0，PROCESS/
LOGICAL PASS，UVM warning/error/fatal 为 `0/0/0`。

| 入口 | 结果 |
| --- | --- |
| `rdma_queue_data_engine_device_publish_test` | PASS；consumer release、CQ shadow/doorbell、failure evidence 与 ordering fault seams 通过 |
| `rdma_queue_data_engine_recovery_test` | PASS；consumer/producer/device recovery、route/epoch 与 release gate 回归通过 |
| `rdma_queue_data_engine_post_test` | PASS；post、RQ/SRQ、CQ completion 与 recovery 交界回归通过 |
| `git diff --check` | PASS |
| `python3 tools/check_changed_sv_style.py --base HEAD` | PASS |
| `python3 tools/check_queue_lifecycle.py` | PASS |
| `python3 tools/check_rdma_profile_names.py` | PASS |
| `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests.unit.test_cmq_gate_manifest` | 22 tests；OK |
| `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests.unit.test_sv_keyword_guards` | 3 tests；OK |
| `python3 tools/check_rdma_phase1a_approval.py` | PASS；所有 approval 仍为 APPROVED |
| `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests/unit -p 'test_*.py'` | 292 tests；OK |
| 全目录中文契约/文件头 scanner | 185 个 `.sv`、2 个 `.svh`，5,408 个 function/task（`.sv` 5,406、`.svh` 2），0 diagnostics |

Python 单元测试中已有 synthetic git/CLI negative-path 的预期 stderr；pytest 因环境未安装
不计入业务 GREEN。`pcie_work` 仍保持唯一外部阻断文本：
`external dependency is not approved: pcie_work`。

## 源码指纹

| 文件 | SHA-256 |
| --- | --- |
| `src/core/rdma_queue_data_engine.sv` | `a8a10f345ccc0f7ec208288d5c5c27a1ba737bc45f9518b1d35f8c451d34f581` |
| `tests/unit/rdma_queue_data_engine_device_publish_test.sv` | `5ee2e400a4ee3eec3d58eefaf97aed5cb1f386cd145cf591f9d8546c56e078a0` |

相对 Batch123，本批只修改 queue-data source，diff 为 81/41（新增/删除）行；测试 fixture
保持不变。新增 task 使 queue-data engine 的 method/comment 复审计数由 140 增至 141，
全目录计数由 5,407 增至 5,408；行数和计数变化只说明局部职责边界，不代表整份结构
重构或广义 Phase 1C F2 已完成。

## 遗留边界与 full-file review

- 本批只关闭 recovery-only CQ→WQ release 的局部职责 seam；engine-level 全局锁、poll/
  recovery 全阶段组合、CQ→WQ 跨队列并发、CEQ/AEQ malformed retry、SRQ 全量公开
  lifecycle、device+consumer 组合 recovery、coordinator 更深所有权审计和 `pcie_work`
  外部批准仍 OPEN。
- 提交前从文件头到 EOF 复审 `src/core/rdma_queue_data_engine.sv`，重点核对新增 task
  的三段中文契约、begin/release/finish 双边 gate、noalloc status 生命周期、frozen
  completion target、failure evidence、锁序与 caller completion 顺序；未发现需要扩大
  到外部依赖或修改既有 ownership 契约的问题。
