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
