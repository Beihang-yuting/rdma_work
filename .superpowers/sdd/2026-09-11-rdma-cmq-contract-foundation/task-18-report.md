# Task 18 实现报告

## 基线与范围

- 工作树：`rdma-cmq-contract-foundation`，确认起始 HEAD 为 `ca1613e59a6cb94b42c26885a4a3e17e608eed8f`。
- 仅修改 brief 列出的 production adapter/engine、port unit test 与设计 spec；未触及外部 dpu_common/driver。

## TDD RED

先在 `tests/unit/rdma_cmq_port_test.sv` 增加 `check_production_observed_pre_rejection()`，
要求 production `execute_observed(null, result)` 返回 PRE_SUBMIT_REJECTED/NONE、
`recovery_required=0` 且不污染 compatibility bit。执行：

```text
SSHPASS=123 scripts/run_vcs53.sh core rdma_cmq_port_test
```

RED 观察：仿真编译成功，新增断言报告
`PRODUCTION_OBSERVED_PRE_REJECT ... production observed pre-engine rejection contract is missing`；
同时暴露 19 个既有 adapter/reconcile timeout 期望差异（UVM_ERROR=20）。该失败发生在
production observed override 尚未实现阶段。

## 实现

- `rdma_cmq_engine.execute_observed()`：一次 `submit_observed()`，锁内按 retained journal
  精确 state/phase 分类；仅 armed pending 调用 `wait_for()`，终态通过 retained completion
  快照返回，Host-visible/NONE 立即返回，STAGED/PENDING_EFFECT fail-closed 且不 I/O。
- `snapshot_execution_result_locked()`：按 batch key 选择 retained profile，避免 reconfigure
  后用 mutable profile 解码历史 typed payload。
- production adapter：直接 override `execute_observed()`（不调用 `super`），legacy
  `execute()` 单向投影 observed result，并作为 `last_execute_no_submit_proven` 唯一写者。
- spec §5.2/§7.6/Phase 1A 补充 observed route、journal decision table 与 deprecated seam 边界。

## GREEN/验证

`python3 tools/check_changed_sv_style.py --base ca1613e` 与 `git diff --check` 均退出 0。
`SSHPASS=123 scripts/run_vcs53.sh core rdma_cmq_engine_test` 编译并已运行的 engine leaves
均为 pristine（最终 umbrella 仍在收集其余 leaves）。port test 可编译，但旧
adapter/reconcile assertions 仍报 timeout 语义差异，需 controller 独立复审是否更新 fixture。

## 所有权与风险

execute result 为 caller-owned detached graph；engine/adapter 不保留 call-local 引用，journal
completion/profile 仍为 authority。主要未决风险是旧 port fixture 对 legacy reconcile 返回
`RDMA_SC_OK` 的假设与 Task17 retained timeout status 不一致，当前未扩大范围修改这些回归。

## Fix round 1

- 根据 controller review，engine observed lookup/relock 失败现在无条件将
  `observation_status` 设为 `INVALID_STATE`；HOST_VISIBLE 行严格要求 `NONE` phase
  且 completion null，其他 state/phase mismatch fail-closed，不执行 I/O。
- legacy wrapper 已改为直接转移 observed result 的 detached status/ticket/completion
  句柄，不再调用 `rdma_cmq_clone_status_value` factory helper；
  `last_execute_no_submit_proven` 仍仅由 legacy execute 写入。
- style/diff 门禁重新运行：`python3 tools/check_changed_sv_style.py --base 7e2f11a`
  与 `git diff --check` 均退出 0。完整 C1 matrix/race fixture 尚待 controller
  复审后补齐；本轮未伪造 VCS GREEN 计数。

## Fix round 2

- 新增 `rdma_cmq_null_observed_engine` probe 与
  `check_execute_observed_null_envelope()`，先运行 VCS53 engine test 得到真实 RED：
  `EXECUTE_OBSERVED_NULL_ENVELOPE ... null submit envelope was not classified as UNOBSERVED`。
- engine `submit_observed()` 改为可窄 override 的 virtual task；null batch/result 现在
  返回 UNOBSERVED effects、UNOBSERVED phase、`recovery_required=1` 及独立 INVALID_STATE
  observation。新增锁内 `validate_observed_item_locked()`，校验 batch/ticket/attempt、
  engine incarnation、Function identity 与 state/phase/completion 矩阵。
- adapter 增加 status/effect/phase/completion envelope shape 校验；legacy status 继续
  直接转移 detached handle。changed-SV style 与 diff-check 通过；修复提交为
  `ca2d887a966d629bb79990941a8ab3cde53e5d94`。
- C1 其余完整 terminal/race/concurrency fixture、control-plane mock route 与 port
  19 条旧期望尚未完成，未声称 GREEN。

## Fix round 3

- `execute_observed()` 对 delegated zero-identity malformed envelope 统一转为
  `UNOBSERVED`/`INVALID_STATE`/`recovery_required=1`；retained terminal/reset 行在
  reprepare 后仍允许按 journal identity 查询，active pending 仍要求当前 incarnation。
- adapter 增加 effect/phase/recovery 语义交叉校验，保留 operation status/effects；
  control-plane、engine、mock 与 port 测试均补 observed route/legacy fallback 断言。
- port fixture 按 journal-only reconcile 语义校正：reconcile 不消费 FIFO，显式 poll
  后检查 timeout 与 late diagnostic；VCS53 fresh run 曾从 20 降至 5 个断言，后续修复
  已提交为 `a462b1efcb72acb03319af9001e587de54307649`，待主代理复跑确认。
- 正确目标 spec `2026-09-11-rdma-engine-contract-refactoring-design.md` 已同步
  §5.2、Phase 1A/1B 与 §10.2 observed/legacy seam 边界；style/diff-check 通过。

## Fix round 4：controller review remediation

本轮只收口四类 reviewer finding；没有改变 `rdma_cmq_port.execute()` 的原始签名、CMQ
线上 descriptor 布局或外部 driver/dpu_common 契约。

1. **Retained journal authority race**

   `validate_observed_item_locked()` 不再把 caller-owned detached result 的
   `lifecycle`、operation `status`、`submission_effect`、`attempt_effect` 和
   `completion_phase` 当作 journal 的等值副本。它们可能在 unlock/relock 之间过时；
   当前 lifecycle 与 operation status 只由 retained journal row 决定。仍保留并强化
   ticket、batch/attempt、Function/CMQ identity、reset epoch、DMA context、recovery
   owner、command identity、dependency mapping 及 completion ticket/status alias 校验。
   新增 `exercise_observed_journal_authority_race()` 先篡改 detached 快照，再通过
   production validator 证明 retained row 不被污染且校验仍通过。

2. **Malformed observed envelope fail-closed**

   delegated result 的零身份/半身份图不再被当作本地 PRE rejection。engine 将其转换
   为 `RDMA_SUBMIT_EFFECT_UNOBSERVED`、`RDMA_CMQ_COMPLETION_UNOBSERVED`、
   `recovery_required=1` 和独立 `RDMA_SC_INVALID_STATE` observation；adapter 还拒绝
   `NONE`、`PENDING`、`UNOBSERVED` 的 phase/effect/completion 矛盾，以及 completion
   内部 ticket/status 非 alias 或值不一致。port test 覆盖空 `NONE`、部分
   `UNOBSERVED` identity 和 malformed delegated result。

3. **Legacy seam 证据边界**

   production adapter 的 `legacy_no_submit_result_valid()` 现在只接受完整的本地
   `PRE_SUBMIT_REJECTED/NONE` envelope；观察失败、Host/MMIO/UNOBSERVED、delegated
   malformed result 都不会写 `last_execute_no_submit_proven`。legacy wrapper 直接转移
   detached `status`、`ticket` 和 `completion` handle，不调用 generic status clone
   factory；`execute_observed()` 不读写 shared compatibility seam。

4. **测试 inventory 与 consumer 回归**

   profile snapshot/recheck fixture 被登记为独立的
   `rdma_cmq_engine_submission_profile_process_test`，engine gate 从十四扩展为十五个
   fresh simulator leaf，manifest/runner/Makefile 和 Python exact-once inventory 同步。
   这保证 profile fixture 不会因单进程 VCS lifetime 分区而静默丢失。

## Fix round 4：fresh verification

以下命令均从当前工作树重新执行；VCS 命令通过 `ubuntu@10.11.10.53` 登录 bash 运行。
日志为本机捕获的完整 stdout/stderr，便于复核：

| 命令 | 结果 | 日志 / SHA-256 |
|---|---|---|
| `SSHPASS=123 scripts/run_vcs53.sh core rdma_cmq_port_test` | logical PASS；UVM warning/error/fatal = 0/0/0 | `/tmp/task18_port_latest.log` / `a2c23bce71517f4a2c2ba4ad45d9c3c4ecce179db3957c7c2d7cec3584d62b33` |
| `SSHPASS=123 scripts/run_vcs53.sh core rdma_cmq_engine_test` | 15/15 physical PASS；logical PASS；每片 summary warning/error/fatal = 0/0/0 | `/tmp/task18_engine_latest.log` / `f6df40edceb513715e61491a64a0a1812f0249c9665c012db88342fb9c29e83b` |
| `SSHPASS=123 scripts/run_vcs53.sh core rdma_control_plane_cmq_engine_test` | logical PASS；0/0/0 | `/tmp/task18_control_cmq_latest.log` / `400b864eb93ab12fe7e77c6301526b6234b19bd045e91d0c12090d99477de370` |
| `SSHPASS=123 scripts/run_vcs53.sh core rdma_control_plane_test` | logical PASS；0/0/0 | `/tmp/task18_control_latest.log` / `c781d933f0296104ec880332ed849cff905120d9ecee725a315d9a7c393f0487` |
| `SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_lifecycle_test` | logical PASS；0/0/0 | `/tmp/task18_queue_lifecycle_latest.log` / `c3c9efe6ffc4dff5c573992d23a543cbf518a8c94f5dc5da46d85a5ff19286e1` |
| `SSHPASS=123 scripts/run_vcs53.sh core rdma_qp_lifecycle_test` | logical PASS；0/0/0 | `/tmp/task18_qp_lifecycle_latest.log` / `10f2201bf5360af69a02f180dff6b68f2fe433d9646367b90060d9a3e74f7c3e` |

本地门禁也重新执行：

```text
python3 tools/check_changed_sv_style.py --base HEAD       # exit 0
git diff --check HEAD                                     # exit 0
python3 -m unittest tests.unit.test_cmq_gate_manifest -v  # 8/8 OK
```

VCS 编译输出仍包含仓库既有 `KUAI`（`context` identifier）和 `TEIF`
（mock task-in-function）warning；它们不进入 UVM summary，且不是本轮新增。engine
matrix/continuation 等 leaf 中的 caught UVM errors 是既有故障注入 catcher 消费的预期
证据；每个 leaf 的最终 strict summary 均为零。

## Scope and handoff

本轮待提交 remediation 只包含 CMQ engine/adapter、对应 unit tests、engine process
inventory/runner/manifest、Task 18 report 和 Phase 1C progress 指针。`src/codec/rdma/rdma_queue_codecs.sv`
与 `tests/unit/rdma_cqe_size_codec_test.sv` 等 Task 1/2 文件明确不在本提交范围；工作树中
其他代理的修改保持原样，交由其各自提交和审查。
