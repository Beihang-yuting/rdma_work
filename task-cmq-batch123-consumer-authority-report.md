# CMQ Batch 123：consumer recovery authority preflight 提取

本批继续基于 Batch121 的 consumer recovery task，进一步把只读 route/evidence authority
查询从 shadow、doorbell、CQ commit、WQ release 和 completion 副作用阶段中分离。改动
重排 `rdma_queue_data_engine.sv` 的已有分支，并在 helper 入口补充 fail-closed geometry
门禁；正常入口仍不改变 `pending_next_cursor()` 的三分支共用 admission gate、错误优先级、
pending evidence 或外部对象所有权。

## 实现边界

- `src/core/rdma_queue_data_engine.sv`
  - 新增受保护的 `validate_consumer_recovery_authority()`，集中校验 consumer pending
    的 kind/handle/image geometry、runtime route/epoch、CQ completion target、routed QP
    incarnation、SQ/RQ/SRQ route、WQ attachment 和未完成 release range。
  - helper 输出 `link` 与 `wqe_attachment` 的借用引用；只执行 runtime route/epoch、
    `qp_links`、attachment lookup 和 `validate_release_range()` 查询，不写 pending、
    cursor、ledger、Host-memory、MMIO 或 scheduler，也不取得 QP/SRQ/WQ 生命周期所有权。
    成功时复用最后一个只读查询的 status，避免额外 success-status factory 分配。
  - `replay_consumer_pending()` 保留 attachment/pending/next null gate，并在任何
    shadow/doorbell/commit/release 之前调用 authority helper；后续副作用阶段的顺序和
    原错误 evidence 保持不变。

## 行为不变量与失败边界

- `pending_next_cursor()` 仍在 `replay_pending()` 中先于 device/host/consumer dispatch；
  authority helper 不接收或重新计算 `next`，因此 stale cursor 不会绕过共用 admission。
- attachment/pending 为空、runtime 为空、attachment/pending `entry_size` 为零、depth
  为零、cursor/next index 越界或 cursor×entry_size 溢出，以及其他 evidence shape 不完整，
  均返回 `RDMA_SC_INVALID_STATE`；route/epoch 查询 null 或 stale
  继续映射为原 status/`RDMA_SC_STALE_GENERATION`；非空非成功 status 原样返回。
- CQ completion target、QP key/link/handle、SQ/RQ/SRQ route、WQ lookup 和 release-range
  的 null/non-ok 分支保留原消息与 `INVALID_STATE`/`STALE_GENERATION` 优先级；CEQ/AEQ
  携带 CQ-only marker 仍在任何副作用前拒绝。
- helper 成功只代表 authority 查询完成，不代表 shadow/doorbell 已发布、CQ cursor 已
  commit 或 WQE 已释放；这些阶段继续由 `replay_consumer_pending()` 单独负责。

## 验证

所有 VCS 仿真均通过 `ubuntu@10.11.10.53` 的登录 bash 环境执行，入口为
`SSHPASS=123 scripts/run_vcs53.sh core <test>`。每项均满足 wrapper rc=0、PROCESS PASS、
LOGICAL PASS，且 UVM warning/error/fatal 为 `0/0/0`。

| 入口 | 结果 |
| --- | --- |
| `rdma_queue_data_engine_device_publish_test` | PASS；device publish/recovery、CQ shadow、route and release fault seams 通过 |
| `rdma_queue_data_engine_recovery_test` | PASS；consumer/producer/device recovery、route/epoch 与 evidence gate 通过 |
| `rdma_queue_data_engine_post_test` | PASS；post、RQ/SRQ、CQ completion 与 recovery 交界回归通过 |
| `git diff --check` | PASS |
| `python3 tools/check_changed_sv_style.py --base HEAD` | PASS |
| `python3 tools/check_queue_lifecycle.py` | PASS |
| `python3 tools/check_rdma_profile_names.py` | PASS |
| `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests.unit.test_cmq_gate_manifest` | 22 tests；OK |
| `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests.unit.test_sv_keyword_guards` | 3 tests；OK |
| `python3 tools/check_rdma_phase1a_approval.py` | PASS；全部 approval 保持 APPROVED |
| `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests/unit -p 'test_*.py'` | 292 tests；OK；synthetic git/CLI negative-path stderr 为预期输出 |
| 当前源码全目录 scanner | 185 个 `.sv`、2 个 `.svh`，共 5,407 个 function/task（`.sv` 5,405、`.svh` 2）、0 diagnostics |

pytest 因环境缺少 pytest 未执行，不记为业务失败或 GREEN。`pcie_work` 仍按既有边界保持唯一阻断文本：
`external dependency is not approved: pcie_work`。

## 源码指纹

| 文件 | SHA-256 |
| --- | --- |
| `src/core/rdma_queue_data_engine.sv` | `08c68da05c4bac6f475a676ba1f949722d8555d495f884deb27215c182153bd8` |
| `tests/unit/rdma_queue_data_engine_device_publish_test.sv` | `5ee2e400a4ee3eec3d58eefaf97aed5cb1f386cd145cf591f9d8546c56e078a0` |

相对 Batch122 提交，本批只修改 queue-data source，diff 为 97/50（新增/删除）行；新增
内容主要是 authority preflight 的契约注释、输出引用和 caller 分派，删除内容是原
`replay_consumer_pending()` 中被搬移的同一查询分支，不把行数变化宣称为完整 consumer
recovery 复杂度收口。

## 遗留并发与范围风险

- route/epoch query、QP/WQ lookup、release-range validation 与后续副作用之间仍没有
  engine-level 全局原子锁；并发 registration/recovery 的窄窗口保持 OPEN。
- CEQ/AEQ consumer retry 的 malformed pending 直接矩阵、跨队列 CQ→WQ release、完整
  SRQ lifecycle 与 device+consumer 组合 fault 尚未形成独立公开 fixture。
- Phase 1C F2、coordinator 跨线程/跨进程锁、manager 外部调用窗口补偿、全目录后续
  ownership 审计和 `pcie_work` 外部依赖锁仍 OPEN。

## Full-file review

提交前已从文件头到 EOF 复审 `src/core/rdma_queue_data_engine.sv`，重点核对 authority
helper 的 null/runtime/geometry fail-closed 门禁、caller 的输出 handle 生命周期、route/epoch/
QP/SRQ 错误优先级、pending cursor admission、shadow/doorbell/commit/release 顺序、复位边界、
中文三段函数注释和稀疏排版；
未发现需要扩大到外部依赖或修改既有 ownership 契约的问题。
