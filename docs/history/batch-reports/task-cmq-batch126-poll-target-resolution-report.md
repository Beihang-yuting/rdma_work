# CMQ Batch 126：CQ poll completion target resolution seam 提取

本批继续基于 Batch125，把 `stage_cq_poll_candidate()` 中 SQ/RQ/SRQ completion target
选择与 attachment authority 检查提取为独立只读 seam。该批不改变 poll 的 live-CQE
提交顺序，也不把 recovery-only 的 frozen evidence 路径重新混入正向 poll。

## 实现边界

- `src/core/rdma_queue_data_engine.sv`
  - 新增受保护 `resolve_cq_poll_wq_target()`，按冻结 CQE 的 `rq_cqe` 和 QP link
    选择 SQ、私有 RQ 或共享 SRQ。
  - helper 集中执行目标 handle kind、attachment lookup、runtime/access/depth、
    64-byte WQE geometry、runtime kind/backing role 以及完整
    `same_handle_instance()` incarnation 检查；输出仍是 engine-owned attachment 的
    非拥有借用引用。
  - `stage_cq_poll_candidate()` 继续负责 release-range snapshot、completion/pending、
    next cursor 和 shadow/doorbell detached preparation；`poll_cqe_once()` 继续保留
    simulator 兼容的完整 QP/SRQ relookup、`enter_recovery_prepared()` 首个 runtime
    mutation，以及 shadow/doorbell→CQ consumer commit→CQ→WQ release→completion 顺序。

## 不变量与明确边界

- resolver 只读 attachment index 和冻结 route，不 reserve/snapshot WQE ledger，不建立
  pending，不推进 cursor，不写 Host-memory，不提交 MMIO，也不取得 queue/backing 的
  生命周期所有权。
- send-CQE 分支只需要 QP/SQ target；未被选中的 `link.srq_h` 不参与该次 target
  authority，因此其 kind 不在 send 分支重复校验。`cqe.qp_h`/wire QPN、CQ route/epoch
  仍由 caller 的 decode/route admission 负责，resolver 不替换既有首错顺序。
- 本批没有新增 hostile resolver 专用 fixture；现有公开 poll 流程覆盖真实 RC SQ，
  post/recovery/device-publish 回归覆盖 attachment/runtime 生命周期交界。RQ/SRQ 与
  UD 正向 poll 的端到端矩阵仍需后续独立证据，不能把 helper 的分支整理误报为全量覆盖。

## 验证

所有 VCS 仿真均通过 `ubuntu@10.11.10.53` 登录 bash 的
`SSHPASS=123 scripts/run_vcs53.sh core <test>` 执行；最终 poll 源码边界结果如下：

| 入口 | 结果 |
| --- | --- |
| `rdma_queue_data_engine_poll_test` | PROCESS PASS、LOGICAL PASS；UVM warning/error/fatal `0/0/0` |
| `rdma_queue_data_engine_post_test` | PROCESS PASS、LOGICAL PASS；UVM `0/0/0`（最终门禁源码） |
| `rdma_queue_data_engine_recovery_test` | PROCESS PASS、LOGICAL PASS；UVM `0/0/0`（最终门禁源码） |
| `rdma_queue_data_engine_device_publish_test` | PROCESS PASS、LOGICAL PASS；UVM `0/0/0`（最终门禁源码） |
| `git diff --check` | PASS |
| changed-SV style / queue lifecycle / profile names | PASS |
| CMQ manifest + SV keyword guards | 25 tests；OK |
| Phase-1A approval | PASS；四项保持 APPROVED |
| Python unit tests | 292 tests；OK |
| 全目录中文契约/文件头 scanner | 185 个 `.sv`、2 个 `.svh`，5,410 个 function/task（`.sv` 5,408、`.svh` 2），0 diagnostics |

四项 queue-data wrapper 均已在同一最终源码边界重新执行；post、recovery、device-publish
分别于 01:31:53、01:36:13、01:39:27（Asia/Shanghai，2026-09-22）完成，新增的
resolver kind/depth/64B geometry 门禁未改变既有错误优先级或提交顺序。

Python 单元测试的 synthetic git/CLI negative-path stderr 属于既有预期输出；pytest 因
环境依赖未安装不计入业务 GREEN。`pcie_work` 仍保持唯一外部阻断文本：
`external dependency is not approved: pcie_work`。

## 源码指纹

| 文件 | SHA-256 |
| --- | --- |
| `src/core/rdma_queue_data_engine.sv` | `5246713232f8b1e443078aac899c063d2e0ee0923180faebed485286fe5f2991` |
| `docs/rdma-structural-refactor-coverage-matrix.md` | `f4341689db7a506c92a4f624386c00eac53d6589451b24674d6445b497a12168` |
| `docs/superpowers/plans/2026-09-17-rdma-structural-refactor.md` | `61b52e8d5dc36831b3ec0d28c1c3231bfdae2a68bd3b5660e43a908743b2eab8` |

相对 Batch125，本批只改变 queue-data source 与两份结构文档，新增一个 target resolver
method；queue-data engine 的 method/comment 复审计数由 142 增至 143，device-publish
test 保持 122，全目录由 5,409 增至 5,410。该计数只描述局部职责边界，不代表整份
structural refactor、广义 Phase 1C F2 或公开 RQ/SRQ/UD poll 已完成。

## 遗留边界与 full-file review

- 已从 `rdma_queue_data_engine.sv` 文件头复审至 EOF，确认 resolver 的输出初始化、
  target kind/role、完整 incarnation、entry geometry、失败状态与 caller relookup
  保持一致；未修改外部依赖或 runtime ledger 所有权。
- RQ/SRQ 与 UD 正向 poll、legacy descriptor branch（当前 `context_backing == null`
  时入口仍 fail-closed）、CQ route/epoch admission、engine-level 全局锁、poll/recovery
  全阶段组合、CQ→WQ 跨队列并发、CEQ/AEQ malformed retry、SRQ 全生命周期、device+
  consumer 组合、coordinator 更深所有权审计和 `pcie_work` 外部批准仍 OPEN。
- 计划和覆盖矩阵继续保持 `active`，不能标记为 `complete`。
