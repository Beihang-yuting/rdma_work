# CMQ Batch 130：私有 RQ receive CQE 正向 poll 覆盖

本批继续基于 `feature/rdma-cmq-contract-foundation` 的重构后 queue-data engine，补齐
私有 RQ receive CQE 经公开 `publish_cqe()`→`poll_cqe()` 的最小端到端正向证据。改动仅
位于 `tests/unit/rdma_queue_data_engine_poll_test.sv`，不修改生产 queue-data engine、
codec、外部依赖或生命周期 owner；计划和覆盖矩阵仍保持 `active`。

## 实现边界

- `make_cqe_for_outstanding_receive()` 根据已成功 `post_recv()` 的 detached result、QP
  route 和 CQ producer polarity 构造 CQE model。它显式设置 `rq_cqe=1`、
  `RDMA_CQE_VARIANT_RQ_SRFQ`、`rqe_cpl=1`、`RDMA_WR_RECV`、QPN、WQE index/wrap、
  `wr_id` 与成功 ecode，并通过 cloned QP handle 保留 route/incarnation 证据。helper
  只分配/填充 CQE model，不读取或写入 CQ backing，不推进 runtime，也不取得外部资源
  生命周期；输入证据不完整时返回非成功 status 和 null model。
- `check_private_rq_receive_cqe_e2e()` 创建带 CQ context shadow 的 lifecycle fixture，
  按 `post_recv`→查询 RQ occupancy→查询 CQ polarity→构造 RQ/SRFQ CQE→公开
  `publish_cqe`→公开 `poll_cqe` 的顺序执行。所有 API 的 status、result 和 detached
  image 都在发布下一阶段前检查；任一中间阶段失败通过 named flow 退出，最后仍由
  `needs_cleanup()`/`cleanup()` 释放 fixture-owned CQ、QP、RQ、SQ、PD 和 Function
  资源。
- poll 结果断言 `RDMA_WR_RECV`、`rq_cqe`、`RDMA_CQE_VARIANT_RQ_SRFQ`、`rqe_cpl`、
  QPN、WQE index/wrap、`wr_id`、单个成功 released slot 及其 index/wrap/status；随后
  读取 RQ/SQ/CQ occupancy，确认只释放 RQ、SQ 保持未使用、CQ 已消费，并检查 RQ/CQ
  producer/consumer index+wrap 收敛到一格后的状态。第二次 poll 必须返回
  `RDMA_SC_QUEUE_EMPTY` 且不发布 completion。

`srfqn`/`srfqe_*` 在本 fixture 中保持默认零值，因为它覆盖的是私有 RQ 而不是共享
SRQ；本批不把默认 overlay 字段夸大为完整 non-zero SRFQ 生命周期证据。`byte_len` 是
detached 软件字段，CQE wire 使用 `payload_len`，因此没有加入 decode 后的 `byte_len`
断言；这避免把模型提示字段误当成 wire contract。

## 验证

所有 VCS 仿真均在 `ubuntu@10.11.10.53` 登录 bash 环境通过
`SSHPASS=123 scripts/run_vcs53.sh core <test>` 执行。四个 queue-data wrapper 均在
当前工作树完成编译和运行：

| 入口 | 结果 |
| --- | --- |
| `rdma_queue_data_engine_poll_test` | PROCESS PASS、LOGICAL PASS；UVM warning/error/fatal `0/0/0` |
| `rdma_queue_data_engine_post_test` | PROCESS PASS、LOGICAL PASS；UVM `0/0/0` |
| `rdma_queue_data_engine_recovery_test` | PROCESS PASS、LOGICAL PASS；UVM `0/0/0` |
| `rdma_queue_data_engine_device_publish_test` | PROCESS PASS、LOGICAL PASS；UVM `0/0/0` |

本批静态门禁记录如下：

| 门禁 | 结果 |
| --- | --- |
| `git diff --check` | PASS |
| `python3 tools/check_changed_sv_style.py --base 2666c4c` | PASS |
| 全目录中文契约/文件头 scanner | 185 个 `.sv`、2 个 `.svh`，5,418 methods（`.sv` 5,416、`.svh` 2），0 diagnostics |
| queue/profile、manifest、SV keyword、Phase-1A、Python 292 | PASS（manifest 22/22、keyword 3/3、Python 292/292） |

## 源码指纹

以下 SHA-256 对应本批报告写入时的当前工作树；后续若再修改任一文件，应和计划、覆盖
矩阵及本报告一起刷新：

| 文件 | SHA-256 |
| --- | --- |
| `src/core/rdma_queue_data_engine.sv` | `481c650da99d72e4d58d173a7e023074f81e19c24fb1a98265de8dd23dbfb1c7` |
| `tests/unit/rdma_queue_data_engine_poll_test.sv` | `b38b60e47c220cfdb541d4472428e40aacfbcf2b30550e519675dfe9e6c44389` |
| `docs/rdma-structural-refactor-coverage-matrix.md` | `1a9759581ec142d74583c2e0cffed784e2d72e690c1613af70d03bafb0a35077` |
| `docs/superpowers/plans/2026-09-17-rdma-structural-refactor.md` | `9d26197f5efe098511e0e303e5de3bd1069d0ad1b68d05d848e040542fb78286` |

相对 Batch129，本批新增两个 test method（一个 CQE factory function、一个正向场景
task），不引入生产行为变化；全目录 method 计数从 5,416 增至 5,418。

## 遗留边界与复审

- 本批只覆盖私有 RQ 的单一 `RDMA_CQE_VARIANT_RQ_SRFQ` 正向 receive poll；SRQ 全生命
  周期、UD send/receive variant、其他 RQ/SRQ overlay、legacy descriptor 分支仍未覆盖。
- `poll_cqe_once()` 的 staged-output hostile canonical relookup、snapshot 后 runtime
  alias、poll/recovery 全阶段组合、CQ→WQ 跨队列并发和 engine-level 全局锁仍需独立
  fixture/设计证据；本批的 occupancy/cursor 断言不替代这些并发或恢复契约。
- selector class-handle 跨 function 的 simulator 保真性、最终全目录 ownership/注释
  审计以及 Phase 1C F2 全量 `sge_num` canonical-authority 收口仍开放；计划不可标记为
  `complete`。
- `dpu_common` 仍是 Host/PF-VF/BDF/BAR/global Function ID/topology 的唯一 authority；
  本批只消费 fixture 冻结 route。`pcie_work` 阻断文本保持原文：
  `external dependency is not approved: pcie_work`；未修改任何外部依赖。

已从新增 test 文件入口复审至 EOF，确认 helper/task 的三段中文契约注释、status/输出
失败边界、named cleanup epilogue、RQ/SQ/CQ ledger 所有权及 detached model 生命周期
与实现一致；计划和覆盖矩阵已同步记录 Batch130，仍保持 `active`。
