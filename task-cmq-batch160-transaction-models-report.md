# Batch160：CMQ transaction models 物理拆分

日期：2026-09-24。基线：`94ba894`（Batch159 已合并到 `main`）。工作树：
`feature/rdma-cmq-structural-phase2-batch160`。

## 目标与边界

本批从 CMQ engine 顶部移出只描述事务值和 staging 图的类型，开始 Phase 2 的物理职责
拆分。新增 `src/core/rdma_cmq_engine_transaction_models.sv`，包含：

- `rdma_cmq_slot_state_e` 和 `rdma_cmq_format_batch_key()`；
- slot record、preallocated publish item/batch；
- reset item/batch/candidate；
- `rdma_cmq_mmio_arm_observer` 及其完整中文契约；
- observed submit、recovery、expiry、generation-cancel 的 staging struct。

`rdma_cmq_engine` 继续是 lock、runtime slot/registry、submission journal、fence、counter
和 transport facade 的唯一可变所有者。新文件不访问 engine protected 字段，也不复制任何
账本；observer 仍只保存 engine 的非拥有引用，并通过原有 `extern` callback 回到 engine。
`rdma_core_pkg.sv` 在 scheduler/transport 之后、engine 之前 include 新文件，保持先定义后
使用和 UVM factory 注册顺序。

## 实际收缩

从 `src/core/rdma_cmq_engine.sv` 迁出 transaction value/staging 定义，并把 ring geometry
纯校验和 terminal-transition staging 进一步收束为公共能力：engine 从基线 14,270 行降至
当前 13,785 行；本批追加把正常 CQE 与 late completion 重复的 journal transition staging/
commit 收束为 `commit_polled_journal_transition_locked()`，并把 predecessor/terminal
纯值校验移入 kernel；observed/wait 的四处终态 phase 枚举再统一为
`rdma_cmq_completion_phase_has_terminal_evidence()`。新增 transaction-model 502 行、
transaction-kernel 237 行。expiry timeout
和 generation cancel 原本完全相同的 staging struct 已合并为
`rdma_cmq_terminal_transition_candidate_stage_t`，两种 policy 仍由 caller 决定候选内容。
状态机、提交/完成/恢复/复位方法和 protected seam 未改动。测试 manifest 增加静态契约，
确保 ring geometry 只在 kernel 定义、engine 只调用两次，且旧的两套 stage typedef 不回归。

## 追加收缩：polled completion journal seam

正常 `CMQ_SLOT_PUBLISHED` 完成和 `CMQ_SLOT_TIMED_OUT_QUARANTINED` late 完成仍保留各自
的 completion/diagnostic 构造、FIFO 交付、token 释放和 slot 终态；两者只共享
`commit_polled_journal_transition_locked()` 的 exact retained-item staging/commit。
该 helper 不访问 FIFO、registry、token 或 slot，确保 journal 先提交、交付后发布的
原有顺序不变，也没有引入第二个 mutable owner。manifest 静态契约要求 helper 唯一定义、
两处分支调用且 `commit_polled_completion_locked()` 不再直接绕过该 seam。

## 追加收缩：journal transition predecessor classifier

将 `stage_runtime_journal_transition_locked()` 中 completion、timeout、late 和 reset
共用的 state/phase 前驱表移至 `rdma_cmq_transition_predecessor_valid()`。该函数只比较
冻结枚举和 completion presence，不读取 journal、slot 或 engine lock；engine 继续负责
ticket/slot/journal invariant、reset authority 及后续 mutation。timeout tombstone 不会
被 generation cancel 误当作仍存活的 published predecessor。

observed submit 与 wait/reconcile 的 retained completion 交付又统一使用
`rdma_cmq_completion_phase_has_terminal_evidence()`，只集中四种终态 phase 的枚举分类；
各 caller 仍分别检查 completion handle、submission state、ticket authority 和 alias，未
扩大 helper 的 ownership 或生命周期边界。

## 验证

- `git diff --check`：通过。
- changed-SystemVerilog style checker：通过。
- `python3 tests/unit/test_check_changed_sv_style.py`：12/12 通过。
- `python3 tests/unit/test_cmq_gate_manifest.py`：23/23 通过。
- `PYTHONPATH=. python3 tests/unit/test_sv_keyword_guards.py`：3/3 通过。
- 全目录中文契约复审：191 个文件（189 `.sv`、2 `.svh`）、5,496 个 function/task，
  hard diagnostics=0；新增 journal seam 的函数注释和重复 case 约束均通过。
- VCS53 登录 bash：`scripts/run_vcs53.sh core rdma_cmq_engine_models_test` 编译并
  PROCESS/LOGICAL PASS，UVM warning/error/fatal 为 0/0/0。
- 结构拆分前主线 CMQ gate：11/11 logical、18/18 engine process，严格 UVM
  warning/error/fatal 为 0/0/0，作为本批行为基线。
- 最终 transaction-kernel/staging 合并后 VCS53 core wrapper：18/18 process、1/1
  logical，UVM warning/error/fatal 为 0/0/0。
- 最终合并前的完整 CMQ gate：11/11 logical、18/18 engine process，字段变异证据
  通过，UVM warning/error/fatal 为 0/0/0。
- 终态 phase helper 加入后完整 CMQ gate 再次复跑：11/11 logical、18/18 engine process，
  driver field mutation PASS，严格 UVM warning/error/fatal 为 0/0/0；focused
  `rdma_cmq_engine_models_test` 同样 PASS。
- 补充静态门禁：`PYTHONPATH=. python3 tests/unit/test_check_rdma_field_ownership.py`
  61/61、`PYTHONPATH=. python3 tests/unit/test_check_rdma_phase1a_approval.py` 15/15、
  `python3 tests/unit/test_check_rdma_profile_names.py` 103/103、外部依赖锁 7/7 通过。

## 后续

对照 `rdma-driver-0.1.34` 的 `xtrdma_sc_cmq_post_sq`、CQ owner/wrap 消费和
`xtrdma_get_cqe_common_info` 业务锚点，后续不再按 observed/recovery/reset 各建一套
transaction class。当前 kernel 已统一 ring cursor、index/wrap geometry、occupancy、
CQ owner 和 terminal-transition staging；journal locator、completion/timeout/late
与 reset epoch 仍由 engine owner 逐步收束。三个入口只提供 policy/admission 差异。
驱动的 SQE/CQE/doorbell 字段继续由 profile 持有，项目增加的 batch 单 doorbell、software
command ID、retained journal 和 observed evidence 作为软件增强保留。

完整 CMQ gate、全目录中文契约 scanner 和源码指纹应在下一个可审查提交前继续刷新。
计划继续保持 `active`。
