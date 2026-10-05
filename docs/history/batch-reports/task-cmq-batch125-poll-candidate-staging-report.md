# CMQ Batch 125：CQ poll candidate staging seam 提取

本批继续基于 Batch124，把 `poll_cqe_once` 在首次 runtime mutation 之前的候选准备阶段
集中到一个受保护纯 function。该 seam 不 admission pending、不提交 CQ CI、不写 shadow/
MMIO、不释放 WQ；`enter_recovery_prepared()` 仍是 caller 中的首个 runtime mutation，
因此不会把 poll 的 live-CQE 契约与 recovery-only 的 frozen evidence 契约混在一起。

## 实现边界

- `src/core/rdma_queue_data_engine.sv`
  - 新增 `stage_cq_poll_candidate()`，集中执行 routed WQ attachment lookup、release
    range snapshot、completion status/result candidate、next cursor、prepared pending，
    以及 CQC shadow 或 legacy consumer-doorbell payload 的 caller-local preparation。
  - function 的输出包括 detached `next`、completion/pending/final status、shadow mode 和
    descriptor/status payload；`wqe_attachment` 仍是 engine attachment 的借用引用。所有
    output 在入口先清空，失败时返回确定性 non-fatal status，不发布半成品。
  - `poll_cqe_once()` 保留 CQ lookup/context authority、occupancy/read/decode/route、
    `enter_recovery_prepared()`、shadow/doorbell、CQ commit、CQ→WQ release 与最终
    completion。对跨 function class-handle 复制差异，caller 在 admission 前按 link、kind
    和完整 QP/SRQ incarnation 重新验证/查询 WQ attachment。

## 行为不变量与失败边界

- staging 只读取 runtime snapshot/query 并创建 detached 对象；不修改 cursor、ledger、
  pending runtime、Host-memory、MMIO 或 scheduler。空输入、空 attachment、空 release
  snapshot、factory/preparation null 或非成功均 fail-closed；release snapshot 为空时不
  索引最后一个 slot。
- `cq_shadow_required` 必须与入口 context authority 一致；shadow 模式必须携带完整
  pending shadow evidence，legacy 模式必须同时拥有 prepared descriptor 和 noalloc status，
  否则在 admission 前返回 `RDMA_SC_RECOVERY_REQUIRED`。
- caller 对 output WQ 引用执行完整 `same_handle_instance()` 校验；错误 incarnation 或
  simulator 丢失 output 时只按冻结 link/kind 重新 lookup，仍无法确认则不进入
  `enter_recovery_prepared()`。因此首个 runtime mutation 和原有
  shadow→commit→release 顺序保持不变。

## 验证

所有 VCS 仿真均通过 `ubuntu@10.11.10.53` 登录 bash 的
`SSHPASS=123 scripts/run_vcs53.sh core <test>` 执行；每项 wrapper rc 为 0，PROCESS/
LOGICAL PASS，UVM warning/error/fatal 为 `0/0/0`。

| 入口 | 结果 |
| --- | --- |
| `rdma_queue_data_engine_poll_test` | PASS；正常 CQ poll、empty polarity、cursor/result 与 retry 边界通过 |
| `rdma_queue_data_engine_device_publish_test` | PASS；prepared factory、shadow/commit/release ordering 与 fault evidence 通过 |
| `rdma_queue_data_engine_recovery_test` | PASS；poll-created consumer pending 的 recovery/release-only 幂等路径通过 |
| `rdma_queue_data_engine_post_test` | PASS；post、RQ/SRQ、CQ completion 与 poll/recovery 交界回归通过 |
| `git diff --check` | PASS |
| `python3 tools/check_changed_sv_style.py --base HEAD` | PASS |
| `python3 tools/check_queue_lifecycle.py` | PASS |
| `python3 tools/check_rdma_profile_names.py` | PASS |
| `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests.unit.test_cmq_gate_manifest` | 22 tests；OK |
| `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests.unit.test_sv_keyword_guards` | 3 tests；OK |
| `python3 tools/check_rdma_phase1a_approval.py` | PASS；所有 approval 仍为 APPROVED |
| `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests/unit -p 'test_*.py'` | 292 tests；OK |
| 全目录中文契约/文件头 scanner | 185 个 `.sv`、2 个 `.svh`，5,409 个 function/task（`.sv` 5,407、`.svh` 2），0 diagnostics |

Python 单元测试中的 synthetic git/CLI negative-path stderr 为既有预期输出；pytest 因环境
未安装不计入业务 GREEN。`pcie_work` 仍保持唯一外部阻断文本：
`external dependency is not approved: pcie_work`。

## 源码指纹

| 文件 | SHA-256 |
| --- | --- |
| `src/core/rdma_queue_data_engine.sv` | `07179f082e80ef1e853775ab5b231ba15df4176dd35031059d8543d4fe847a21` |
| `tests/unit/rdma_queue_data_engine_device_publish_test.sv` | `5ee2e400a4ee3eec3d58eefaf97aed5cb1f386cd145cf591f9d8546c56e078a0` |

相对 Batch124，本批只修改 queue-data source，diff 为 241/91（新增/删除）行；测试 fixture
保持不变。新增 staging function 与 caller 的 defensive gate 使 queue-data engine 的
method/comment 复审计数由 141 增至 142，全目录计数由 5,408 增至 5,409；这些计数只
说明局部职责边界，不代表整份结构重构或广义 Phase 1C F2 已完成。

## 遗留边界与 full-file review

- 现有正向 poll fixture 主要覆盖 RC SQ 与 URC shadow；RQ/SRQ 正向 poll、UD poll result/
  route、legacy descriptor branch（当前入口在 `context_backing == null` 时 fail-closed）
  仍 OPEN。engine-level 全局锁、poll/recovery 全阶段组合、CQ→WQ 跨队列并发、
  CEQ/AEQ malformed retry、SRQ 全量 lifecycle、device+consumer 组合、coordinator 更深
  所有权审计和 `pcie_work` 外部批准仍 OPEN。
- 提交前从文件头到 EOF 复审 `src/core/rdma_queue_data_engine.sv`，重点核对 staging
  function 的 output 初始化、snapshot/result/pending 所有权、WQ attachment incarnation
  relookup、context/shadow gate、首个 admission mutation、锁序与所有错误路径；未发现
  需要扩大到外部依赖或修改既有 ownership 契约的问题。
