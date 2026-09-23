# CMQ Batch 120：device-producer recovery task 提取

本批继续基于已完成 host-producer recovery 提取的 queue-data engine，收敛
`replay_pending()` 中 device-producer 分支的 DMA 与 recovery 责任边界。改动只重排
既有阶段，不改变 runtime ledger、reservation、route/epoch、backing 或外部依赖的所有权。

## 实现边界

- `src/core/rdma_queue_data_engine.sv`
  - 新增受保护的 `replay_device_producer_pending()` task，承接原
    `replay_pending()` 中 device-producer 的完整路径：detached pending 查询、route/epoch
    查询、device reservation/queue-incarnation/geometry 校验、冻结 image 复制、
    `write_device()`、write-attempt marker、device readback、recovery commit gate、
    producer commit 与 completion。
  - `replay_pending()` 继续先校验 attachment/evidence 和 `pending_next_cursor()`，随后
    仅按 `pending.device_producer` 选择 helper，host-producer 仍进入
    `replay_host_producer_pending()`，consumer 仍保留在 caller；原分支顺序和
    `status` 返回方式保持不变。
  - helper 不重新 reserve cursor、不从当前 queue/request 推导 image，也不把
    `write_device()` 替换为 host `write_and_verify()`。写入、readback、commit gate、
    producer commit 或 completion 失败时仍保留原 recovery evidence 与 reservation。

## 行为不变量

- `pending_next_cursor()` 仍在 device/host/consumer 分支选择前执行，stale next cursor
  不能进入任何 backing 或 runtime mutation。
- device pending 的 query 顺序仍为 pending → route/epoch → reservation → authority
  校验；identity、route/epoch、reservation 或 geometry 失配均在首次 device write 前
  返回 `RDMA_SC_RECOVERY_REQUIRED`。
- `write_device()` 未明确进入 backend 时记录 `RDMA_QUEUE_MMIO_NO_SUBMIT`；已经进入
  backend 但 readback/commit 失败时记录 `RDMA_QUEUE_MMIO_NOT_APPLICABLE`，不推进新的
  cursor，也不自动重试未知硬件结果。
- helper 只持有 attachment/runtime/access 的借用引用；它不删除 attachment、释放
  backing、改写外部 mapping，也不复制 runtime mutable ledger。

## 验证

所有 VCS 仿真均在 `ubuntu@10.11.10.53` 的登录 bash 环境通过
`SSHPASS=123 scripts/run_vcs53.sh core <test>` 执行。三项均满足 wrapper rc=0、PROCESS
PASS、LOGICAL PASS，UVM warning/error/fatal 为 `0/0/0`。

| 入口 | 结果 |
| --- | --- |
| `rdma_queue_data_engine_device_publish_test` | PASS；device-publish fault/recovery、reservation、readback 与既有 hostile factory 场景通过 |
| `rdma_queue_data_engine_recovery_test` | PASS；producer/device/consumer recovery 与 evidence gate 通过 |
| `rdma_queue_data_engine_post_test` | PASS；post、RQ/SRQ、CQ completion 与 recovery 交界回归通过 |
| `git diff --check` | PASS |
| `python3 tools/check_changed_sv_style.py --base HEAD` | PASS |
| `python3 tools/check_queue_lifecycle.py` | PASS |
| `python3 tools/check_rdma_profile_names.py` | PASS |
| 逐文件中文 method/comment 与文件头复审 | `rdma_queue_data_engine.sv` 138 个 function/task、device-publish test 122 个 function/task；均 0 diagnostics，均从文件头复审至 EOF |

manifest/keyword/Phase-1A/Python 292 门禁已在本批 source-only 提取后的当前工作树重跑并
通过。pytest 因环境缺少 pytest 不记为业务失败或 GREEN。`pcie_work` 的唯一阻断文本保持：
`external dependency is not approved: pcie_work`。

## 源码指纹

| 文件 | SHA-256 |
| --- | --- |
| `src/core/rdma_queue_data_engine.sv` | `82448a308771ebb33ac45f19f0d9499706904f70bd244ac09a5ea6717b7c000c` |
| `tests/unit/rdma_queue_data_engine_device_publish_test.sv` | `5ee2e400a4ee3eec3d58eefaf97aed5cb1f386cd145cf591f9d8546c56e078a0` |

相对 Batch119 提交，本批只修改 source，diff 为 187/154（新增/删除）行；新增行主要是
helper 的契约注释与局部变量，删除行是 caller 中被搬移的同一 device-producer 分支，
不把行数变化宣称为完整 recovery 复杂度收口。

## 遗留边界

- consumer recovery 仍在 `replay_pending()` caller 内，CQ route、WQ release、shadow
  publication 和 completion release 的全阶段拆分尚未完成。
- `query_pending()`/route/reservation 与后续 device write 之间仍没有 engine-level 全局
  并发锁；`query_pending()` 与 runtime confirmation 的窄窗口风险由 Batch119 保留。
- 完整 SRQ、跨队列并发、device/consumer recovery 全阶段组合、Phase 1C F2、coordinator
  跨线程/跨进程锁、manager 外部调用窗口补偿和 `pcie_work` 外部依赖锁仍 OPEN。

## Full-file review

提交前已从文件头到 EOF 复审 `src/core/rdma_queue_data_engine.sv`，重点核对新 helper
与 caller 的局部变量生命周期、DMA 方向、reservation/route/epoch 错误优先级、
readback/commit evidence、中文三段函数注释和空行格式；未发现需要扩大到外部依赖或
修改既有 ownership 契约的问题。
