# Task 14 实现报告：认证 pre-MMIO arm capability

## 范围与基线

- worktree：`/home/ryan/workspace/ryan/rdma_work/.worktrees/rdma-cmq-contract-foundation`
- 分支：`feature/rdma-cmq-contract-foundation`
- 基线：`e8040839321781952c52844c4f6c455736c8fd2c`
- requirements：`task-14-brief.md`
- 实现文件：
  - `src/core/rdma_cmq_engine.sv`
  - `tests/unit/rdma_cmq_engine_test.sv`

Task 14 未修改外部依赖、`hw/`、model 或 codec。Phase 1A approval checker
保持 plan commit `00ac20e8db79a92a9bd7bc7700355e6b8f4cc1d1`、plan blob
SHA-256 `c521b5fe81473d922d1a466d8ecc885bf3b1c899086e9543b4445518e526280b`、
approver `ryan`，Task 8/9/17/18 required gate 均为 `APPROVED`。

## TDD RED

先只加入 observer API、valid/forged/stale/duplicate callback 和原子状态断言，未加入
production 定义；随后在 VCS53 运行：

```bash
SSHPASS=123 scripts/run_vcs53.sh core rdma_cmq_engine_test
```

命令退出 2。VCS 在预期 missing-production 边界报告
`rdma_cmq_mmio_arm_observer` 未定义；没有独立测试语法错误，也未进入仿真。

## 实现

- 在完整 engine 声明前加入 forward declaration 和
  `rdma_cmq_mmio_arm_observer`；callback extern 实现在 engine class 结束后，避免
  incomplete-type 调用。
- observer 保存 non-owning engine handle 与冻结的 capability/batch/attempt/
  incarnation。`configure()` 只允许成功一次；访问器均为 non-virtual read-only
  projection；未配置或 null owner callback 只发布稳定错误，绝不解引用 null。
- engine 新增 `arm_observers[string]`。认证同时要求 configured、owner exact handle、
  registry exact object identity、batch key、attempt 和 engine incarnation 与 retained
  journal 完全匹配；只知道相同字符串不能获得 authority。
- `arm_submission_for_mmio()` 在调用方已持 `engine_lock` 的前提下运行。所有 record、
  preallocation、profile format、item、slot/token/key 冲突与 batch 内重复检查在任何
  mutation 前完成；合法路径只安装预建 slot 句柄和 registry/token 索引、推进
  `publish_seq`、更新 item/batch 为 `PUBLISH_AMBIGUOUS`、发布
  `MMIO_MAYBE_VISIBLE`/`COMPLETION_PENDING`，再原子消费 capability 与
  preallocation 行。
- 合法 arm 路径没有 `new`、factory、clone/copy、格式化、wait、时间控制、semaphore/
  lock 操作，也不调用 scheduler、transport、profile/service 或 adapter。
- journal row-set invariant 允许且仅在 `observer_armed=1` 时缺失已消费的
  preallocation，使 arm 后 retained record 仍可 query/remove；未 arm 且缺行仍按
  `INVALID_STATE` 拒绝。

## 测试覆盖

- 已持 `engine_lock` 时调用 authentic observer，证明没有锁重入或时间推进；scheduler
  调用数与 profile service 调用数保持不变。
- 逐 item 验证 exact preallocated slot handle 被转移到 slot、command、entry 三类
  runtime index，token 被占用，cursor 只推进到预建 final sequence。
- 覆盖 copied strings 但非登记 identity、已撤销 identity、wrong batch、wrong attempt、
  wrong incarnation、missing preallocation、stale lifecycle、unconfigured/null owner、
  null observer 和 duplicate callback。
- 所有拒绝分支精确捕获一条 ID=`RDMA_CMQ_MMIO_ARM_INVALID`、message=
  `CMQ MMIO arm capability is invalid`，并比较真实 authoritative batch 的 journal、
  cursor、registry 基数、profile format 和 item/batch mutable evidence 不变。
- arm 后再次通过公开 journal query 验证 retained snapshot 可读，再通过真实删除入口
  验证 consumed-preallocation record 可移除。

## GREEN 与静态门禁

最终候选在 2026-09-13 运行 fresh VCS53：

```bash
SSHPASS=123 scripts/run_vcs53.sh core rdma_cmq_engine_test
```

命令退出 0；10 个预期非法调用被 catcher 捕获，demoted fatal/error/warning 均为零；
仿真在 `10115000 ps` 完成，最终摘要为：

```text
UVM_WARNING :    0
UVM_ERROR :    0
UVM_FATAL :    0
UVM report is pristine: warning=0 error=0 fatal=0
```

最终候选同时运行：

```bash
git diff --check
python3 tools/check_changed_sv_style.py \
  --base e8040839321781952c52844c4f6c455736c8fd2c
python3 tools/check_rdma_phase1a_approval.py
```

三项均退出 0；changed-SV checker 无诊断，approval 四项 required gate 全部
`APPROVED`。

## 全文件复审与 concerns

已从 header 到 EOF 复审两份 staged SV 文件：production 8976 行、159 个
function/task；test 17665 行、371 个 function/task。文件头以及共 530 个方法的紧邻
“功能 / 输入输出及副作用 / 失败边界”中文注释审计均为 0 finding；同时复核了
authority/object identity、表所有权、reset/clear 生命周期、journal/preallocation
行一致性、arm 原子 mutation、错误路径、callback re-entry、test fixture cleanup 和
run list。

全文件 case 审计在 production 为 0 finding；test 的 15 个 case-style finding 与
Task 14 基线数量完全一致，均在本次 diff 外，按小提交边界未混入修复。VCS 仍报告
既有 `context` keyword compatibility warning，以及未触及 mock 的既有 TEIF warning；
它们未形成 runtime UVM severity。本任务范围无已知功能 concern。

## 提交

- subject：`feat(cmq): authenticate the pre-MMIO arm transition`
- commit：`ed3d2575e583e8403e2252676992e0be287a16b0`

## Fix round：reviewer 测试证据补强

### 范围与减法

- 基线：`ed3d2575e583e8403e2252676992e0be287a16b0`。
- 仅修改 `tests/unit/rdma_cmq_engine_test.sv`；production 最终与基线完全一致。
- 删除 fix-round 早期的四层 capture carrier、derived observer probe、
  capture/match 大方法、duplicated fixture、A/B debug marker 和额外 tick。
  最终 diff 为 `569 insertions / 131 deletions`；新增结构只包含窄
  scheduler probe、preallocation value comparator和exact-row predicate，没有并行
  ledger schema。Task 13 原有的必要 `#1ns` 保持不变。

### Reviewer findings 逐项修法

1. 非法 callback 的 authoritative state 改为 lossless 证据组合：每次回调后
   同时走 public batch query 和两个 ticket query，复用
   `expect_journal_snapshot()` 对照独立 source graph，并运行 production journal
   invariant/digest/profile pipeline。窄 `preallocated_publish_value_matches()` 逐值比较
   batch/item/slot/ticket/expected 完整投影；`mmio_arm_fixture_rows_match()`
   以已知 key、cardinality 和 exact handle 检查 journal/preallocation/profile/
   observer/ticket rows。runtime 空表、32 个 token incarnation、全部 cursor/counter
   与 profile service count 也逐项检查。duplicate 路径额外检查 retained
   journal/profile exact row 及已转移 slot/command/entry exact handles。
2. allocation oracle 改为在 callback 紧邻两侧直接比较
   `uvm_object::get_inst_count()`，并保留每项 exact preallocated slot handle
   转移断言。`$time`、unified adapter trace 与 profile service count 也在同一
   窗口前后取样。
3. engine 实际安装 `rdma_cmq_mmio_arm_scheduler_probe`。probe 通过 inherited
   `lock_for(function_uid, global_function_id)` 取得 production exact Function
   semaphore，engine probe 持有真实 `engine_lock`后同步调用 base authentic
   observer。回调前后两把锁均不可再取；退出后分别以两次
   `try_get()` 证明恰好恢复一个 token，并原样归还检查所取 token。
   该 seam 不调用 `submit_observed()`，因此不进入 scheduler MMIO worker path；
   Task 11 仍独立覆盖真实 callback-before-MMIO 顺序。

### TDD / mutation 证据

第一次 compact candidate 在 VCS53 稳定运行但退出 2：测试自身只将
stale batch 改成 `STAGED`，item 仍为 `PENDING_EFFECT`，production invariant 正确
拒绝该不一致 fixture，产生 6 个 `MMIO_ARM_STALE_STATE_QUERY_*` 错误。
修正为 batch/items 同步的 `HOST_VISIBLE_NOT_PUBLISHED` 后，同一命令
首次 GREEN，exit 0。

随后在 production `arm_submission_for_mmio()` 的合法 commit 前临时加入一次
`rdma_status` 构造并丢弃，再运行同一测试命令。仿真稳定退出 2，
唯一未捕获错误为：

```text
UVM_ERROR ... [MMIO_ARM_CALLBACK_BOUNDARY]
valid callback allocated, waited or re-entered a service
UVM_ERROR :    1
```

临时 production mutation 随即恢复，`git diff --exit-code --
src/core/rdma_cmq_engine.sv` 退出 0。最终候选重新执行：

```bash
SSHPASS=123 scripts/run_vcs53.sh core rdma_cmq_engine_test
```

命令退出 0，仿真在 `10115000 ps` 结束；catcher 精确捕获 10 个预期
invalid-callback errors，demoted fatal/error/warning 均为 0，最终摘要：

```text
UVM_WARNING :    0
UVM_ERROR :    0
UVM_FATAL :    0
UVM report is pristine: warning=0 error=0 fatal=0
```

### 静态门禁与 header-to-EOF 复审

最终候选执行：

```bash
python3 tools/check_rdma_phase1a_approval.py
python3 tools/check_changed_sv_style.py \
  --base ed3d2575e583e8403e2252676992e0be287a16b0
git diff --check
```

三项均退出 0；approval 保持 plan commit `00ac20e8db79a92a9bd7bc7700355e6b8f4cc1d1`、
blob SHA-256 `c521b5fe81473d922d1a466d8ecc885bf3b1c899086e9543b4445518e526280b`，
Task 8/9/17/18 全部 `APPROVED`。

已从 header 到 EOF 复审唯一 touched SV：
`tests/unit/rdma_cmq_engine_test.sv` 共 18103 行、374 个 function/task。
文件头的目录/职责/依赖/所有权与生命周期完整；374 个方法的紧邻
“功能 / 输入输出及副作用 / 失败边界”全文审计为 0 finding。同时复核
exact authority/identity、表 cardinality、对象所有权、双锁 token 恢复、
callback 无分配/无时间推进/无外部调用、非法路径、fixture cleanup、run list
与稀疏排版，未发现新问题。

VCS 仍只报告基线已有的 `context` keyword compatibility warning 和
未触及 mock 的 TEIF warning；它们不形成 runtime UVM severity。

### Fix commit

- subject：`test(cmq): strengthen pre-MMIO arm evidence`
- body：`Full-file review: all staged SV files reviewed header-to-EOF; AGENTS.md findings resolved.`
