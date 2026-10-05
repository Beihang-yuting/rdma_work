# CMQ Batch 119：recovery action contract 与 reservation cardinality

本批继续基于已经完成局部结构提取的 queue-data engine，收敛
`recover_queue()` 的控制面拒绝、reservation-only abort 和 retry confirmation 顺序。
目标是让 recovery 在发生任何 ownership migration、reservation detach 或一次性 runtime
授权之前完成可观察的 action/evidence 判定；本批不扩大到外部 PCIe、Host-memory 或
`dpu_common` 契约。

## 实现边界

- `src/core/rdma_queue_data_engine.sv`
  - 在 `recover_queue()` 完成 handle validation 后、unclaimed admission、reservation
    query 和 claimed runtime handoff 之前校验 `action`。只接受
    `RDMA_QUEUE_RECOVERY_RETRY_PENDING` 与 `RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH`；其余
    值返回 `RDMA_SC_INVALID_ARGUMENT`。retry 还必须带
    `caller_confirmed_no_submit=1`，否则在任何 evidence migration 前返回同一错误。
  - reservation-only 分支先遍历全部由
    `collect_reservation_only_candidates()` 收集的 matching candidate，并为每个 candidate
    完成 `query_device_reservation()`。每个 `reservation_valid` 且带 snapshot 的 candidate
    都计入 cardinality，包括测试 alias 造成的重复引用；查询全部完成前不调用
    `detach_recovery_transaction()`。超过一个有效 snapshot 返回
    `RDMA_SC_INVALID_STATE`，并保留原 reservation/evidence。
  - claimed retry 先调用 runtime `query_pending()` 并检查 null、status 和
    `RDMA_QUEUE_MMIO_AMBIGUOUS`，只有拿到有效 pending snapshot 后才调用
    `runtime.recover()` 记录一次性 confirmation，再进入 `replay_pending()`。因此 query
    失败不会遗留一个后续路径可消费的 confirmation gate。
  - 保留 unclaimed handoff 优先级、claimed 多 runtime ambiguity、abort/detach 错误映射和
    replay 的既有生命周期；本批没有修改外部依赖或改变 attachment 的所有权模型。

- `tests/unit/rdma_queue_data_engine_device_publish_test.sv`
  - 在 device-publish recovery fault engine 中加入仅测试用的 reservation alias 注入/移除
    helper。alias 只借用原 CQ attachment 的 runtime/access 引用，不复制、不释放共享
    lifecycle 对象，断言完成后恢复原索引。
  - 扩展 unclaimed-kind authority 场景：重新 arm admission fault，调用未确认 retry，
    断言返回 `RDMA_SC_INVALID_ARGUMENT`、admission fault 计数不消耗，且公开 pending
    evidence 与调用前一致。
  - 扩展 reservation-only 场景：注入第二个 matching alias，断言 ambiguity 在任何
    detach 前返回、reservation index/wrap 保持不变，然后移除 alias 执行既有 abort/cleanup。
  - 删除不可实现的非法 enum X-cast 断言。`rdma_queue_recovery_action_e` 在
    `src/core/rdma_queue_runtime.sv` 中是 `typedef enum bit` 的 2-state 1-bit enum；VCS
    会把 X/Z cast 成可表示的合法值，无法构造可观察的非法枚举成员。未确认 retry 的
    preflight 断言覆盖了同一控制面拒绝点，并且能验证 admission/evidence 未发生迁移。

## 行为不变量与失败边界

- action/confirmation preflight 只改变拒绝时机，不改变合法 abort/retry 的返回值和
  ownership 语义；abort 不要求 caller confirmation，retry 必须显式确认 no-submit。
- reservation query 的 null status 或非成功 status 仍映射为
  `RDMA_SC_RECOVERY_REQUIRED` 并保留首错；若之后发现第二个有效 snapshot，也不会先
  detach 第一个 candidate。
- reservation-only retry 仍因没有可重放 image 返回 `RDMA_SC_RECOVERY_REQUIRED`；只有
  单一有效 reservation 的 explicit abort 才能进入 detach。
- `query_pending()` 返回 null、错误 status、null evidence 或 `AMBIGUOUS` 时，retry 在
  `runtime.recover()` 前失败；runtime confirmation 成功后 replay 的既有失败仍保留
  recovery evidence。

## 验证

所有 VCS 仿真均通过 `ubuntu@10.11.10.53` 的登录 bash 环境执行，入口为
`SSHPASS=123 scripts/run_vcs53.sh core <test>`。每项均满足 wrapper rc=0、PROCESS PASS、
LOGICAL PASS，且 UVM warning/error/fatal 为 `0/0/0`。

| 入口 | 结果 |
| --- | --- |
| `rdma_queue_data_engine_device_publish_test` | PASS；未确认 retry 不消耗 admission/evidence；reservation-only 多 matching 在 detach 前返回 ambiguity |
| `rdma_queue_data_engine_recovery_test` | PASS；confirmed/unconfirmed retry、ambiguous evidence 与 recovery failure 路径通过 |
| `rdma_queue_data_engine_post_test` | PASS；post、RQ/SRQ 与既有 writer/recovery 约束通过 |
| `git diff --check` | PASS |
| `python3 tools/check_changed_sv_style.py --base HEAD` | PASS |
| `python3 tools/check_queue_lifecycle.py` | PASS |
| `python3 tools/check_rdma_profile_names.py` | PASS |
| `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests.unit.test_cmq_gate_manifest` | 22 tests；OK |
| `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests.unit.test_sv_keyword_guards` | 3 tests；OK |
| `python3 tools/check_rdma_phase1a_approval.py` | PASS；全部 approval 保持 APPROVED |
| `python3 -m unittest discover -s tests/unit -p 'test_*.py'` | 292 tests；OK；synthetic git/CLI negative-path stderr 为预期输出 |
| 逐文件中文 method/comment 复审 | `rdma_queue_data_engine.sv` 137 个 function/task、device-publish test 122 个 function/task；均 0 diagnostics，均从文件头复审至 EOF |

pytest 因环境缺少 pytest 未执行，不记为业务失败或 GREEN。`pcie_work` 仍按既有边界
保持唯一阻断文本：`external dependency is not approved: pcie_work`。

## 源码指纹

以下哈希对应本报告所描述、尚未提交的 Batch119 source/test 字节；文档修改不会改变这
两个文件的指纹。

| 文件 | SHA-256 |
| --- | --- |
| `src/core/rdma_queue_data_engine.sv` | `d8848a9b73178a47ae8d2b55850ce286361798a8fb95b52cf9fe9d773ab9a93d` |
| `tests/unit/rdma_queue_data_engine_device_publish_test.sv` | `5ee2e400a4ee3eec3d58eefaf97aed5cb1f386cd145cf591f9d8546c56e078a0` |

当前 source/test diff 为 68/32 与 140/7（新增/删除）行；增量主要来自契约注释、测试
fixture 和边界断言，不把行数变化宣称为完整复杂度收口。

## 遗留并发与范围风险

- `query_pending()` 与 `runtime.recover()` 仍是两个非原子调用；在两次调用之间存在窄
  窗口，尚未有 engine-level 全局并发锁。
- claimed attachment 与 reservation-only candidate 扫描都没有 engine-level 全局锁；
  并发修改 `attachments` 的行为仍需后续契约。
- host-produced SQ/RQ/SRQ candidate 的 reservation query 仍可能返回既有
  `RDMA_SC_INVALID_STATE`，本批没有扩大该边界。
- unclaimed admission 成功后若发现重复 claimed runtime，ownership migration 可能已经
  发生；本批保持原先 handoff 优先级，没有引入回滚事务。
- 完整 SRQ、跨队列并发、device/consumer recovery 全阶段组合尚未关闭；Phase 1C F2、
  coordinator 跨线程/跨进程锁、manager 外部调用窗口补偿和 `pcie_work` 外部依赖锁仍
  OPEN。

## Full-file review

提交前已从文件头到 EOF 复审 `src/core/rdma_queue_data_engine.sv` 与
`tests/unit/rdma_queue_data_engine_device_publish_test.sv`，逐个核对目录职责、借用引用
生命周期、action/evidence/retry 错误路径、复位/状态迁移、测试清理和中文三段函数注释。
未发现需要扩大到外部依赖或修改既有 ownership 契约的问题。
