# CMQ Batch 115：post_recv receive-target resolution 提取

本批继续基于重构后的 queue-data engine 收敛职责边界。`post_recv()` 原先把
completion-QP 选择、QP link 查找、SRQ link identity 校验、RQ/SRQ attachment lookup
和真正的 producer posting 混在同一 task 中；这些查找本身不需要 runtime mutation，
却和 reserve/write/doorbell/commit 阶段交错，增加了审阅失败优先级和生命周期边界的
成本。本批只提取只读 target-resolution seam，不恢复旧的大体量实现，也不修改外部
依赖。

## 实现边界

- `src/core/rdma_queue_data_engine.sv`
  - 新增受保护的 `resolve_receive_target()`，集中选择 SRQ 的
    `completion_qp_h` 或 private RQ 的 `target_h`，按完整 handle
    kind/Function/object/generation 查找 `qp_links`。
  - SRQ 路径仍先检查 `link.srq_h` 非空，再用 `same_handle_instance()` 比较
    request 冻结的 SRQ incarnation；失配继续返回原有
    `receive completion QP is not attached to the target SRQ` 错误，不触碰 runtime。
  - helper 只解析 `attachments` 中的 RQ/SRQ 借用引用，并输出冻结的
    `runtime_kind`；不执行 owner 校验、route/epoch 校验、producer reservation、
    Host-memory I/O、doorbell 或 ledger commit。
  - `post_recv()` 主流程现在清晰地按
    `validate → resolve target → owner/route/epoch → reserve → encode/write →
    doorbell → commit` 组织；pending recovery 也复用同一 `runtime_kind`，消除了
    三处重复的 RQ/SRQ 条件表达式。
  - null status、空 link、空/不完整 attachment 均在 helper 边界 fail-closed；输出
    引用在失败时保持为空。engine 仍只持有 attachment/link 的非拥有引用。

## 行为不变量

- `snapshot.validate()` 仍先于 target lookup；completion-QP 未 attach、SRQ link
  incarnation 失配和目标 ring 未 attach 的错误优先级保持不变。
- owner、binding route/reset epoch、cursor reservation、WQE write/readback、
  producer doorbell、runtime ledger commit 的顺序与副作用未改变。
- RQ 与 SRQ 使用各自 attachment namespace；同一 QP 的 SQ/RQ 不共享 offset 或
  runtime ledger。失败 target lookup 不推进 cursor、不写 Host-memory、不发 MMIO。
- helper 不取得 QP、SRQ、mapping、runtime 或 backing 的所有权；外部生命周期仍由
  resource/lifecycle 层负责。

## 验证

所有 VCS 仿真均在 `ubuntu@10.11.10.53` 登录 bash 环境执行。

| 入口 | 结果 |
| --- | --- |
| `rdma_queue_data_engine_post_test` | rc=0；PROCESS/LOGICAL PASS；UVM WARNING/ERROR/FATAL=0/0/0；既有 private-RQ、owner/route/epoch、empty-RQE 与 post/readback 场景通过 |
| `rdma_queue_data_engine_recovery_test` | rc=0；PROCESS/LOGICAL PASS；UVM WARNING/ERROR/FATAL=0/0/0 |
| `rdma_rq_engine_test` | rc=0；PROCESS/LOGICAL PASS；UVM WARNING/ERROR/FATAL=0/0/0；RQ facade 的 foreign-handle、inactive binding、stale generation/epoch 和 null-status delegate 门禁通过 |
| 公开 UD temporary probe（验证后删除） | rc=0；PROCESS/LOGICAL PASS；UVM 0/0/0；1-byte inline、1-SGE、2-SGE `post_send()` 分别提交到 SQ index 0/1/2，最终 producer=3/used=3/pending=0；注入首次 512-byte SGB write 失败后 `recover_queue(RETRY_PENDING)` 重放至少 2 次 SGB write + 1 次 64-byte SQ write，最终 producer=1/used=1/pending=0 |
| `python3 tools/check_changed_sv_style.py --base HEAD` | PASS |
| `git diff --check` | PASS |

临时公开 UD probe 只用于关闭 Batch114 暴露的公开 API 证据缺口，已从
`tests/unit/rdma_queue_data_engine_post_test.sv` 完整删除，不作为长期测试入口或
广义 F2 完成证明。`rdma_queue_codec_test`、`rdma_sq_codec_test` 已在同一
zero-byte 修复后的 HEAD 重跑并通过（UVM 0/0/0）。

## 源码指纹与遗留边界

- `src/core/rdma_queue_data_engine.sv` SHA-256：
  `c1a06e1bd1327746d23e40de93383f908c9c0543b8e4ea03ad53756528b00e58`
- 计划状态继续为 `active`；本批关闭的是 receive target-resolution 的局部结构 seam，
  不宣称 SRQ 全量公开 post/recovery lifecycle、跨线程/跨进程 coordinator 并发、
  manager 外部调用窗口补偿、Phase 1C F2 whole-plan authority 或外部 `pcie_work`
  锁已完成。
- `pcie_work` 的阻断文本仍必须保持：
  `external dependency is not approved: pcie_work`。
