# Batch148：host-producer commit/recovery route 收缩

日期：2026-09-22。工作树：`feature/rdma-cmq-contract-foundation`。

本批把 Batch144/145/147 之后仍分散在 `post_send()`、`post_recv()` 和
`replay_pending()` 的 producer 副作用边界继续收束；不改变 queue runtime、外部
Host-memory/PCIe adapter 或 `dpu_common` 的所有权。

## 代码收缩

- `snapshot_attachment_route_epoch()` 统一读取 attachment runtime 锁存的 route/reset
  epoch，并与当前 binding identity 比较；旧的
  `validate_attachment_route_epoch()` 仅作为兼容转发，避免 caller 自己拼接快照、valid
  位和 authority 判断。
- `reserve_host_producer_cursor()` 将 SQ、私有 RQ 和 shared SRQ 的 route/epoch admission
  与 producer reservation 收束为一个无外部 I/O 的入口，并把成功 reservation 时的
  route/epoch 冻结给后续 pending evidence。
- `validate_host_producer_reservation_window()` 在 reservation 返回后、首次 WQE/Host
  memory 副作用前再次复核 route/epoch；失败时清空本地 cursor，不创建伪造 pending。
- `commit_host_producer_ledger()` 成为 host producer ledger 的唯一 engine-level 调用
  seam，统一 null status 归一化；runtime 仍是 PI/used/slot ledger 的唯一所有者。
- `admit_host_producer_recovery()` 与 `install_host_producer_recovery()` 统一 recovery
  admission、pending 安装和 status 归一化。WQE/readback 失败保持 `NO_SUBMIT`，doorbell
  或 ledger commit 失败保持 `AMBIGUOUS`；pending 始终覆盖为 reservation 冻结的
  route/epoch。
- `complete_host_producer_tail()` 统一 WQE write/readback、next cursor、producer
  doorbell、ledger commit 和 detached result 构造。next/result 使用 nonfatal raw factory，
  queue handle 使用 fail-closed clone，避免 commit 已成功后仅因 result/status factory
  失败而产生二次 fatal 或错误回滚。
- SQ external-SGB 已写入但 WQE gate 失败的路径也通过同一 recovery installer 构造
  `NO_SUBMIT` pending，保留已写 SGB 的 evidence 与原始失败优先级。

本批不把上述 seam 宣称为跨组件原子事务：外部 adapter 生命周期仍由外部环境管理，
runtime ledger 仍由 attachment.runtime 管理，engine 只保存非拥有引用和 detached
evidence。

## 新增故障契约

`tests/unit/rdma_queue_data_engine_final_fix_test.sv` 新增 commit-fault probe，并将
`rdma_queue_host_producer_commit_failure_test` 加入
`scripts/run_queue_lifecycle_regression53.sh`。WQE/readback、DMA/MMIO barrier 和
doorbell 成功后注入 ledger commit 失败时，测试确认：

- result 为空，PI/CI/used 不推进；
- pending 保存 cursor、next cursor、image、request、冻结 route/epoch；
- MMIO evidence 为 `AMBIGUOUS`，不会伪造已确认提交；
- 只能通过公开 `RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH` 收敛。

`rdma_queue_data_engine_recovery_test.sv` 另增 stale-replay fixture：SGB 已写、WQE
尚未写出时翻转 reset epoch，pending 保留旧 epoch；retry replay 被拒绝且不增加
Host-memory/PCIe I/O，最终同样只能走公开 abort。CQE fixture 明确设置 RC/SQ 的
`srfq` 和 `variant`，避免测试数据绕过 publish variant/topology gate。

## 验证证据

全部 VCS 命令通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 中执行：

| 入口 | 结果 |
| --- | --- |
| `rdma_queue_data_engine_post_test` | PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_queue_data_engine_recovery_test` | PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_queue_data_engine_poll_test` | PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_queue_data_engine_device_publish_test` | PROCESS/LOGICAL PASS；UVM `INFO=220/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_queue_host_producer_failure_final_fix_test` | PROCESS/LOGICAL PASS；UVM `INFO=27/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_queue_host_producer_commit_failure_test` | PROCESS/LOGICAL PASS；UVM `INFO=8/WARNING=0/ERROR=0/FATAL=0` |

当前 `src/core/rdma_queue_data_engine.sv` SHA-256 为
`ca11b30a716b7672b8a648457475dc45cd122f33107b879e0c40738bddb1b509`。
全目录中文 function/task 与文件头复审（`src/`、`tests/`、`sim/`）覆盖 185 个
`.sv`、2 个 `.svh`，共 5,460 个 method（`.sv` 5,458、`.svh` 2），0 diagnostics。

本地门禁均通过：`git diff --check`、changed-SV style、profile naming、queue lifecycle、
Phase-1A approval、manifest/keyword Python tests，以及完整 `tests/unit` Python
回归 292/292。完整 `scripts/run_queue_lifecycle_regression53.sh` 已在 53 机启动，
其最终 core/integration 汇总以该命令的 PROCESS/LOGICAL 和严格 UVM 摘要为准，不能
用 focused 结果替代。

## 保留边界

本批只收束 host-producer 的局部 admission、recovery evidence、commit/result tail 和
stale replay 证据。reservation 后仍可能发生的跨线程 route 变化、`query_pending()` 与
`runtime.recover()` 的并发窗口、跨队列 CQ→WQ release、SRQ 全生命周期、legacy
descriptor 分支、UD receive/replay 扩展矩阵、外部 PCIe error/ordering 组合以及
engine-level 全局锁和最终 ownership 审计仍开放。计划必须继续保持 `active`，不得将
focused 或本批回归结果解释为整份结构重构完成。
