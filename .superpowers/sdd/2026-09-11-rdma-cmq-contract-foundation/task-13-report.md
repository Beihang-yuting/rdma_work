# Task 13 实现报告：增加 engine-owned submission journal storage

## 范围、基线与审批

- 隔离 worktree：
  `/home/ryan/workspace/ryan/rdma_work/.worktrees/rdma-cmq-contract-foundation`
- 分支：`feature/rdma-cmq-contract-foundation`
- Task 13 基线 `HEAD` / merge-base：
  `c37feaf353019227cd4bb2ea2fc6faaa362454ac`
- 唯一 requirements 来源：`task-13-brief.md`
- 实现范围严格限于：
  - `src/core/rdma_cmq_engine.sv`
  - `tests/unit/rdma_cmq_engine_test.sv`

实现前及最终候选均运行 Phase 1A approval checker。最终结果为 plan commit
`00ac20e8db79a92a9bd7bc7700355e6b8f4cc1d1`、plan blob SHA-256
`c521b5fe81473d922d1a466d8ecc885bf3b1c899086e9543b4445518e526280b`、
approver `ryan`，Task 8/9/17/18 四项门禁均为 `APPROVED`。

Task 13 采用 `progress.md` 中的 retained-profile binding ruling：engine 增加且
仅增加一张 private `journal_profile_by_batch[string]` 关联表。每行保存 journal
安装时 exact、non-owning profile service handle，仅供该 record 的 typed snapshot
与 query-time canonicalization；该行与 record 在既有 `engine_lock` 下原子同生同删，
并随 record 跨 reset、UNCONFIGURED 和 reprepare 保留。它不进入 V1 key/digest，
不授权 retry、proof 或 lifecycle，也不存在 current profile、profile name、carried
bytes 或 concrete profile fallback。缺失、name drift 或 seam 违约的 retained row
使查询以 null output 和非致命 `RDMA_SC_INVALID_STATE` 失败；未知 candidate
polymorph 则原子返回 `RDMA_SC_INVALID_ARGUMENT`。

## TDD RED 证据

先只加入 identity、storage、detached query、retained ticket 和 hostile-factory
契约测试，再通过指定 host 53 wrapper 运行：

```bash
SSHPASS=123 scripts/run_vcs53.sh core rdma_cmq_engine_test
```

命令退出 2。VCS 到达预期 missing-production 编译边界，仅报告四处缺少
`rdma_cmq_preallocated_publish_batch` / `rdma_cmq_preallocated_publish_item`
类型；没有独立测试语法或类型错误，也没有进入仿真。

## 实现结果

### 稳定 identity 与 prepare 生命周期

- `rdma_cmq_format_batch_key()` 校验完整 Function identity 及非零
  engine/incarnation/batch ID，并生成 brief 指定的固定宽度小写 canonical key；
  parent PF、VF index、BDF、global Function ID、Function UID、generation、reset
  epoch 以及 engine object identity 均进入 key。
- engine 在 `super.new()` 后一次性冻结零扩展的 `get_inst_id()`；
  `engine_incarnation`、batch、attempt 和 reset-proof counter 均从零开始并只发布
  `counter + 1`，reset/shutdown 不复用或清零。
- `prepare()` 在任何 Host-memory allocate/zero-write 前检查下一 incarnation overflow，
  只在 transport/runtime 的既有成功提交块推进 incarnation；所有 rollback/早退保留
  原值，第二个同 Function engine 也因 immutable instance ID 生成不同 key。
- 两个 engine-private preallocation value 直接保存后续 publication 所需的有序
  slot/entry/token/profile-format 值；它们不拥有 lock，也不是第二 ledger。

### Journal、索引与 fence

- engine 在既有 `engine_lock` 下拥有 `submission_journal`、ticket-to-batch index、
  `preallocated_publish_batches`、ruling 允许的 retained profile association，及
  fenced batch/reason；构造时初始化，configuration cleanup 不静默删除 retained
  journal 或稳定 counters。
- `_locked` helper 在写入前完成 capacity、collision、cardinality/order、preallocated
  row、ticket、profile format、item digest 和 batch digest 全部校验；record、每条
  ticket index、preallocated row 与 retained profile row 只在完整成功后原子发布。
  删除也在同一锁域验证并原子移除所有关联行。
- 安装与每次公开查询都经 exact profile seam 重新取得 polymorphic body canonical
  bytes，并独立重算 item/batch digest；不信任 carried bytes/digest。stored value、
  digest 或 polymorphic graph corruption 只产生非致命错误和 null output。
- `query_submission_journal()`、`query_submission_journal_by_ticket()` 与
  `query_submission_fence()` 均直接构造非空 status、只取得 `engine_lock`，并仅发布
  完整 detached snapshot。ticket query 先验证 detached ticket shape，再用稳定 key
  查 index 并与 journal item 做全值相等校验，不调用 current-runtime ticket authority
  seam，因此旧 ticket 在 reset 后及新 incarnation ACTIVE 后仍可诊断查询。

### 非致命 detached snapshot graph

- 六个 brief 指定的 top-level snapshot seam 均清空 output、直接构造一个
  `rdma_cmq_nonfatal_snapshot_context`，再显式复制完整 graph；实现未使用通用 UVM
  `copy()/clone()/do_copy()`、fatal `rdma_cmq_clone_*` 或 raw factory construction。
- command body 和 completion decoded payload 只由 retained profile 的 typed snapshot
  seam 复制；未知类型、null status/output、自别名、错 subtype 或 value drift 均返回
  稳定的非致命错误，绝不发布 partial graph。
- context 保留 graph 内 repeated-node alias：command owner 与 item owner、ticket 与
  completion ticket、status 与 completion status 在 snapshot 内仍为同一节点，同时
  与 source 全部脱离。
- adapter-owned mapping 通过 `snapshot_release_authority()` 取得 detached opaque
  authority，再 direct-snapshot nested handles、显式复制每个 public mapping field，
  并用 `release_authority_status()` 和 value/alias 检查验证等价性；未用 base slicing、
  public-field digest 或 current runtime mapping 代替私有 release authority。

## Mapping fixture 问题定位与修正

首轮 production 实现已正确要求 mapping snapshot 同时满足 private release authority、
public value 相等和 graph detachment，但测试 fixture 最初提供的 retained mapping 没有
按 adapter authority contract 构造，导致六个 storage/query 场景在 fixture/安装边界
失败，而非 journal/reset 状态机缺陷。

`build_journal_fixture()` 现从 prepared live mapping 调用
`snapshot_release_authority()` 取得同 concrete type 的 opaque authority，独立快照
`function_h` / `owner_h`，逐项复制所有 public mapping 字段，再通过
`release_authority_status()`、public-value equality 与 alias checks 验证。两个 fixture
item 共享这一已验证 detached mapping，既覆盖 repeated-node alias，也不把 adapter
私有 allocation identity 伪造成公共 scalar。未放宽 production journal 或 reset 语义。

## 测试覆盖与 GREEN 证据

新增测试覆盖：

- exact literal canonical key、完整 Function identity 各字段扰动、同 Function 两个
  engine instance、同 incarnation 多 batch，以及 reset/reprepare 后稳定 ID 不复用；
- incarnation/batch/attempt/reset-proof 四个 `64'hffff_ffff_ffff_ffff` overflow，
  其中 prepare overflow 必须发生在任何 Host-memory/scheduler 调用之前；
- 两 item journal/preallocation 的原子安装与删除、duplicate batch/ticket、cardinality
  mismatch、partial preallocation 和 unknown candidate polymorph 的失败原子性；
- batch/ticket/fence 查询、每层 nested value mutation 后二次查询不变、polymorphic
  body/payload 的 value equality、source detachment 与 graph 内 alias preservation；
- missing/drifted retained profile、profile canonicalization rejection、stored value/
  digest/polymorph corruption，以及 reset 后 UNCONFIGURED 与新 profile/new incarnation
  ACTIVE 时仍只调用原 exact profile 查询旧 quarantined record；
- outer graph 与全部支持 polymorph 的 hostile raw-factory override、zero factory calls、
  zero caught fatal，以及 result/recovery-request/reset-proof 的完整或 null 发布契约。

production fixture 修正后通过一次 fresh host-53 GREEN；注释同步完成后又运行一次
最终 fresh GREEN。两次命令均退出 0，最终仿真在 `10114000 ps` 完成，结尾为：

```text
UVM_WARNING : 0
UVM_ERROR : 0
UVM_FATAL : 0
UVM report is pristine: warning=0 error=0 fatal=0
```

最终 run 的 report catcher 同时确认 caught/demoted warning、error、fatal 全部为零；
历史 SIGSEGV 未复现。

## 静态门禁、范围核对与全文件复审

当前候选相对 Task 13 基线已运行：

```bash
git diff --check
python3 tools/check_changed_sv_style.py \
  --base c37feaf353019227cd4bb2ea2fc6faaa362454ac
python3 tools/check_rdma_phase1a_approval.py
```

三条命令均退出 0；diff/style 无诊断，approval checker 的四项 required gate 均为
`APPROVED`。最终 path review 确认仅两份 brief 指定的 SV 文件包含实现改动，另随
提交保存本报告；没有 `hw/`、`src/model/`、`src/codec/` 或外部依赖改动。

已从 header 到 EOF 复审两份 Task 13 SV 文件：

- `src/core/rdma_cmq_engine.sv`：8416 行；检查 header、稳定 identity、prepare 原子
  commit、journal/index/profile row 同锁事务、digest/profile seam、detached graph、
  cleanup/reset 生命周期和所有失败路径。
- `tests/unit/rdma_cmq_engine_test.sv`：16368 行；检查 fixture、故障注入、每项
  identity/storage/query/hostile-factory 断言、run list 与最后运行的 fatal catcher。

对两文件共 502 个 function/task 执行邻近三段注释结构审计，文件 header 均覆盖
目录定位、职责、依赖、所有权和生命周期。新增 production journal 路径没有
`.clone()`、`.copy()`、`do_copy()`、`type_id::create`、`rdma_cmq_clone_*` 或新增
semaphore；`journal_profile_by_batch` 只有初始化、invariant/collision、原子安装删除
和 retained-query 的 ruling-approved use。全文件 checker 另报 15 个 Task 13 diff
之外的 legacy case-style finding，按小提交边界未混入本次功能提交。

## 自审与 Concerns

Task 13 范围内无已知功能 concern。retained profile association 是 ruling 明确批准的
non-owning semantic capability，每个 live journal batch 增加一个 handle row；外部
profile lifecycle 必须继续满足 retained record 的查询期契约。Task 14-18 将消费本任务
建立的预分配 storage 与稳定 identity，本任务不提前实现 arm/publication/retry/proof/
routing 行为。

完整 core 编译仍显示非阻断 compiler compatibility diagnostic：Task 13 brief 固定
snapshot seam 及其测试使用的 `context` 标识符触发 KUAI，未触及的
`rdma_queue_host_mem_submitter_test.sv` 仍有既有 KUAI，
`rdma_mock_control_plane.sv` 仍有既有 function-call-task TEIF。它们不计入 runtime
UVM severity；最终目标 UVM summary 保持 pristine。

## 提交

- 指定提交标题：`feat(cmq): add engine-owned submission journal storage`
- 提交包含两份 Task 13 SV 文件和本实现报告；commit hash 以最终提交输出为准。

## Fix round 1：review findings 与 RED

独立 review 的四项 Important finding 均先由测试复现，再修改 production：

- mutable lifecycle evidence 缺少完整 invariant；
- retained ticket 的非 key 字段损坏会被错分为 caller error，null Function handle
  还会在形成 key 时触发 null-object access；
- record、preallocation、profile 与 ticket index 的单行 orphan 未统一视为
  retained invariant corruption；
- hostile-factory 场景只实际经过五种受支持 command body 中的 object-ID 分支。

Fix-round RED 仍使用唯一允许的 host-53 命令：

```bash
SSHPASS=123 scripts/run_vcs53.sh core rdma_cmq_engine_test
```

该次命令退出 2：batch state corruption 被旧实现接受为 OK；retained ticket 的
shape-valid 非 key 漂移被错报为 caller `INVALID_ARGUMENT`；随后 null Function handle
在 `command_key()` 路径触发 NOA；profile orphan 分别落入 `RESOURCE_BUSY` 或普通
missing-key 分类。五 body matrix 已编译，但因前述 deliberate null-ticket failure 未运行
到末尾，因而同时保留了原 review 指出的 coverage gap。

## Fix round 1：实现与测试闭环

- `validate_submission_record_locked()` 现在由 install 与每次 query 共用，逐 batch/item
  校验 state/effect/phase enum、batch reducer、recovery classifier、nonlegacy owner
  attempt 关系，以及 required completion 的 ticket/status canonical alias。
- 新增 null-safe 的 per-key row-set parity 与全局 ticket-target audit；allocate、install、
  remove 及 query 都在普通 collision/missing 分类前拒绝 partial retained row。
- ticket query 先审计 retained graph 并生成完整 detached candidate，确认 stored side
  完整后才与 caller ticket 做 full-value compare，避免 retained corruption 被误归责给
  caller。
- candidate 与 stored corruption matrix 覆盖上述每类 mutable evidence；stored ticket
  的合法 shape 非 key 漂移及 null Function handle 均通过 batch/ticket 两个公开 API
  断言 `INVALID_STATE` + null output。
- 单一共享 storage fixture 在真实 remove 后确认四表为空，再逐次只播种 record、
  preallocation、profile 或 ticket-index 一行；为复现旧 batch key 临时回拨的
  incarnation/batch/attempt/proof counter 在每个窗口后精确恢复。
- hostile 场景在安装永久 override 前构造 QPC、object-ID、MR-deregister、OCC-flush
  与 empty 五种 source graph；override 生效后逐行执行 install、batch query 与 remove，
  并在 object-ID 行删除前执行 ticket query。每轮立即清空本地 row/snapshot 引用，末尾
  断言四张 retained 表均为空。

## VCS teardown SIGSEGV 定位与隔离

功能断言完成后，未推进时间槽的组合场景曾在 `run_phase` 已打印
`JOURNAL_DEBUG after hostile` 和 `JOURNAL_DEBUG after drop` 后发生 VCS runtime
SIGSEGV。捕获日志为 `task-13-fix-vcs53-debug.log` 与
`task-13-fix-vcs53-mutable-bad.log`；两份 stack annotator 都显示 `No context
available`，且进程在 objection 已释放后的 teardown 阶段退出，而非 DUT transaction
或 UVM assertion 路径。

二分隔离分别运行 storage 半段和 hostile-factory 半段时均为 GREEN；只有两组复杂
automatic fixture 在同一 simulation time slot 连续销毁、同时永久 raw-factory override
生效时复现 teardown SIGSEGV。最终在 storage engine 已 shutdown 且四张 retained 表
明确为空后加入一个有中文设计说明的 test-only `#1ns` quiescence boundary，使 VCS 在
安装永久 override 前完成上一 fixture graph 的回收。该 tick 位于所有 live DUT
transaction、timeout 和 retained authority 之外，不改变 production 行为或协议时序。

去除全部 `JOURNAL_DEBUG` 与实验代码后的完整命令连续两次退出 0，均在
`10115000 ps` 完成，UVM warning/error/fatal 为 `0/0/0`，并打印
`UVM report is pristine`。当前 fix-round 候选的 fresh acceptance run 结果在最终提交前
的验证小节补充。

## Fix round 1 全文件复审补充

当前文件长度为 production 8650 行、test 17100 行。对两份文件从 header 到 EOF
重新执行 502 个 function/task 的邻近三段中文注释审计，文件 header 与所有方法均为
零 finding；同时复核了 journal 所有权/生命周期、四表同锁事务、reset/reprepare
保留、query 错误映射、hostile cleanup 和 run list。15 个 legacy case-style finding
均由 Task 13 基线之前的提交引入且不在本次 diff，按小提交边界继续不混入。

review 的 scheduler/transport 可观察计数建议保持为 deferred minor：production
`prepare()` 在 incarnation overflow 后立即返回，早于 transport candidate 构造；
`rdma_cmq_transport::configure()` 只保存非拥有 scheduler 引用，并不调用 scheduler
API。现有测试已断言 Host-memory call 数为零、runtime output 为 null、engine state 与
incarnation 不变；增加 `submit_calls == 0` 对 prepare 正常路径同样恒真，不能提供额外
有效区分。该项不改变本轮四项 Important finding 的闭环。

本附录按 fix-round 要求只保留为 controller evidence，最终 fix-round commit 仍只
stage 两份 Task 13 SV 文件。

## Fix round 1 fresh acceptance

最终提交前于 2026-09-13 12:29（Asia/Shanghai）再次原样运行：

```bash
SSHPASS=123 scripts/run_vcs53.sh core rdma_cmq_engine_test
```

命令退出 0；VCS compile/elaborate/link 完成后，`rdma_cmq_engine_test` 在
`10115000 ps` 结束。report catcher 的 demoted/caught warning、error、fatal 全部为零，
最终 severity 为 `UVM_WARNING=0`、`UVM_ERROR=0`、`UVM_FATAL=0`，wrapper 输出
`UVM report is pristine: warning=0 error=0 fatal=0`。

同一最终候选还 fresh 运行 approval checker、以 `4efa9e0` 为 base 的 changed-SV
style checker、`git diff --check`、SV path scope、debug residue 及新增 production
forbidden-construction scan；全部退出 0 或无匹配。SV scope 仍严格只有
`src/core/rdma_cmq_engine.sv` 与 `tests/unit/rdma_cmq_engine_test.sv`。
