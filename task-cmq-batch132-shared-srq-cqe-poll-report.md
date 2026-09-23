# CMQ Batch 132：shared-SRQ receive CQE 正向 poll 证据

本批继续基于 `feature/rdma-cmq-contract-foundation` 的重构后 queue-data engine，补齐
真实 shared SRQ receive CQE 的公开 `post_recv`→`publish_cqe`→`poll_cqe` 证据。生产
`src/core/rdma_queue_data_engine.sv` 不因本批测试覆盖而改变；测试只通过公开 executor、
queue-data engine API 和 fixture lifecycle 建立/销毁资源。

## 实现边界

- `rdma_queue_data_engine_poll_test.sv` 新增独立的
  `create_shared_srq_poll_route()` / `destroy_shared_srq_poll_route()`。helper 创建 owned
  SRQ、创建引用该 SRQ 的 RC QP、把 QP attach 到 fixture CQ，并在清理时严格执行
  QP link detach→SRQ engine attachment detach→SRQ destroy→基础 fixture cleanup。SRQ
  attachment 由 `attach_qp()` 隐式建立，不能只销毁 QP；清理 helper 即使成功标志尚未
  置位也会探测一次 SRQ detach，将明确的“queue is not attached”视为部分失败路径的
  幂等结果，同时保留其它 detach/destroy 错误。
- `make_cqe_for_outstanding_shared_srq_receive()` 构造
  `RDMA_CQE_VARIANT_RQ_SRFQ`、`rq_cqe=1`、`srfq=1`、`rqe_cpl=1` 的 detached CQE，
  并带上 `srfqe_index`、`srfqe_wrap`、QPN/WQE 坐标和 `wr_id`。SRFQ wire ID 使用
  SRQ resource 的 authoritative `local_srq_id`（调用方将该值作为 `srqn` 传入），
  而不是 manager registry 的 `handle.object_id`：前者是 SRFQ overlay 的硬件坐标，
  后者只是资源管理索引，二者在本 fixture 中不保证相等。helper 对 QPN 的 18-bit
  和 SRFQN 的 12-bit wire 范围执行 fail-closed 检查。
- `check_shared_srq_receive_cqe_e2e()` 通过真实 SRQ target 和引用 QP 执行
  `post_recv(target_h=SRQ, completion_qp_h=QP)`，公开发布 receive CQE，再从同一 CQ
  poll。断言 CQE variant/overlay、SRQ ledger release、SRQ/CQ occupancy 与 producer/
  consumer cursor、released request 的 SRQ/QP identity、基础 fixture 私有 RQ 保持
  空闲，以及第二次 poll 返回 `RDMA_SC_QUEUE_EMPTY`。
- 所有 early-disable 分支都保留独立的 `srq_created`、`srq_qp_created`、
  `srq_qp_attached`、`srq_attached` 证据；失败时仍按已建立资源的逆序尝试 cleanup，
  不把共享 CQ/PD 的基础 fixture cleanup 当作 SRQ attachment 的替代品。

## 验证

所有 VCS 仿真均在 `ubuntu@10.11.10.53` 的登录 bash 环境，通过
`SSHPASS=123 scripts/run_vcs53.sh core <test>` 执行。最终源码边界结果如下：

| 入口 | 结果 |
| --- | --- |
| `rdma_queue_data_engine_poll_test` | PROCESS PASS、LOGICAL PASS；UVM warning/error/fatal `0/0/0` |
| `rdma_queue_data_engine_post_test` | PROCESS PASS、LOGICAL PASS；UVM warning/error/fatal `0/0/0` |
| `rdma_queue_data_engine_recovery_test` | PROCESS PASS、LOGICAL PASS；UVM warning/error/fatal `0/0/0` |
| `rdma_queue_data_engine_device_publish_test` | PROCESS PASS、LOGICAL PASS；UVM warning/error/fatal `0/0/0` |

静态门禁在测试和文档最终落盘后重跑并记录：

- `git diff --check`；`python3 tools/check_changed_sv_style.py --base 453d25a`：PASS。
- 全目录中文文件头/函数-task 三段契约 scanner：185 个 `.sv`、2 个 `.svh`，共
  5,426 methods（`.sv` 5,424、`.svh` 2），0 diagnostics。
- `python3 -m unittest discover -s tests/unit -p 'test_*.py'`：292 tests，OK。
- manifest、keyword、queue/profile、Phase-1A 等既有辅助门禁保持 GREEN；本批不修改
  外部依赖。

## 源码指纹

以下 SHA-256 对应本报告所述最终源码边界；后续修改任一文件必须刷新本报告、计划和
覆盖矩阵中的证据。报告自身不列入表格，避免自引用 hash：

| 文件 | SHA-256 |
| --- | --- |
| `tests/unit/rdma_queue_data_engine_poll_test.sv` | `b1fb33f3ae5a9b1260ff4a6a6694183c025d3e60c4e2aabefe6d361de565b02a` |
| `docs/superpowers/plans/2026-09-17-rdma-structural-refactor.md` | `a1ea795c73de9e0dca93f1c158519a6862e50b5a00045f767f3e5bc0ab2a3468` |
| `docs/rdma-structural-refactor-coverage-matrix.md` | `953f2087f3b1535602eef5dff1a6b8c4f8599dcf513a791a17172c57c78d4952` |

## 开放边界

本批只关闭 shared-SRQ receive poll 的单路径正向证据，不宣称以下范围已经完成：UD
receive/replay、`publish_cqe()` 的 transport-aware variant consistency gate、legacy
descriptor 分支、poll/recovery 全阶段组合、CQ→WQ 跨队列并发、engine-level 全局锁、
snapshot 后 alias 审计、SRQ 全量公开 post/recovery lifecycle、device/consumer recovery
组合矩阵和最终全目录 ownership/注释审计。下一批可独立处理 publish variant consistency；
host-producer replay 在 reset epoch 变化但 generation 未变时的 route/epoch 复核不得混入
本批结论。

`pcie_work` integration 的阻断文本保持原文：
`external dependency is not approved: pcie_work`；未修改外部依赖，也未将阻断伪造为
业务失败或 GREEN。
