# Batch236：runtime 恢复提交授权同源

日期：2026-09-29；基线：`5a07c57`；分支：`feature/rdma-structural-batch226`。
本批不合并、不推送；main 保持 `083e0d7`，原缓存及外部依赖不改。

## 改动与业务边界

`enable_recovery_commit` 和 `enable_recovery_commit_noalloc` 原来分别维护相同的
MMIO/shadow 证据检查、错误优先级和一次性 retry confirmation 消费逻辑。现在由
同类 protected `enable_recovery_commit_locked` 实现唯一规则，返回 code/message；
不新增组件、字段、authority、账本或锁。两公开入口只保留各自的锁和状态交付：

- 普通入口仍经 `acquire_lock` 获取 token，持锁期间保留该步骤的 factory 回调；
  授权后归还 token，再通过原 nonfatal/fallback 构造最终 status。
- noalloc 入口仍先拒绝 null slot，再直接 `try_get`；共同规则不创建对象，解锁后
  原位写入 caller 的 status，布尔结果由同一 code 得出。
- 规则按无 pending/非 recovery、坏 published shadow、NONE/AMBIGUOUS、缺少
  confirmation 的顺序拒绝；不重做 admission 的完整枚举/identity/route 校验。
- 合法 published CQC shadow 无须消费 confirmation；普通 NO_SUBMIT/
  NOT_APPLICABLE 成功时消费它；SUCCESS 保留它。失败保留两个授权位原值，
  不把已经打开的 gate 自动关闭。这是基线语义，不是本批新增行为。

生产文件 **3,814→3,797 行，净减 17 行**；授权相关 tokens **526→312**。
methods 74→75 是同类增加一份共同规则，不增加公开接口；58 public、74 个原声明、
实例字段和 class graph 不变，另 72 个方法正文 token 相同。
不以测试/报告行数计入生产收缩，也不把局部同源宣称为整个 runtime 已完成重构。

## 对照测试与复审

新增独立 `rdma_runtime_commit_gate_test`，只继承既有断言和公开 CQ fixture，
不调用父 run_phase。新 test 已在 core/package 各注册一次：

- 两入口 × 五种 MMIO evidence × 四种 shadow 状态 × 两种 confirmation ×
  两种初始 gate，共 160 个组合；每个连续调用两次，共 **320 次**。
- 两入口各覆盖缺 pending、错误 runtime state、null lock、真实并发占锁、解锁后
  复用，以及正常/null/错型 factory 的成功与拒绝，共 **22 次**。
- null status slot **1 次**，两入口各走公开 device reserve/commit → prepared
  admission → gate → CI commit → complete 的真实 CQ 流程，共 **2 次**。

合计 **345 次调用**，有 1us watchdog。每次矩阵调用检查原始 code/text、脏 status
字段归零、授权位及锁状态；observer 检查普通路径两次回调的位置和授权快照、
busy 时的一次回调、noalloc 的零回调。重复调用验证 no-submit confirmation
不能重复消费，并固定失败不改旧 gate。测试 probe 只用于构造公开 admission
不可达的防御状态，不能用这些 fixture 证明无效 evidence 可以从正常入口进入。

首次旧版编译发现错型 fixture 试图构造抽象 `uvm_object`；改用既有具体
`rdma_queue_runtime_wrong_factory_object`，并修正两处单行 if-return 和一处长行。
未修改预期或生产规则。修订基线 345 次全部通过，UVM 0/0/0；最终测试与该次送测
字节一致。失败的首次编译日志单独保留，不当作成功证据。

六项 Python 结构门禁固定唯一授权规则、无分配边界、两种交付窗口、诊断优先级
和专项注册。固定基线审计将旧版两个方法的解锁/状态交付归一化后，与新共同规则
逐 token 对照；所有条件、诊断、读写顺序相同。公开入口的锁准入前缀与原版相同，
终端仍先解锁后交付，动态 factory observer 提供独立运行证据。

从 runtime 文件入口复审了 configure/authority、resize staging、两种 producer、
consumer CI、WQE release、prepared admission、MMIO/shadow marker 和 recovery
收尾。同步纠正相关注释中遗漏 shadow 成功路径及声称 reservation accessor 会
额外检查方向的描述；不改这些方法实现。其余 200 个既有 src/tests-unit SV 文件
字节不变；package 和 manifest 各仅增加一项。
目录契约扫描为 **202 SV files / 5,370 methods / 零 diagnostics**；自动扫描、
既有文件证据及本批语义复审不等于全部目录最终可读性/并发验收。

## 验证状态

最终验证全部通过；每组 wrapper 真实退出码为 0，送测输入哈希一致。

| 验证项 | 最终结果 |
| --- | --- |
| 修订旧版基线 / 重构版专项 | 各 1 PROCESS / 1 LOGICAL，均完成 345 次授权调用 |
| core | 105 PROCESS / 88 LOGICAL，105 份 pristine UVM 报告；新矩阵与既有十一组矩阵标记齐全 |
| CMQ | 28 PROCESS / 11 LOGICAL，28 份 pristine UVM 报告 |
| integration / Host-memory / PCIe | 10 / 3 / 1，全通过 |
| 双环境 / 多 VF / 高流量 E2E | 各 1，全通过 |
| Python | 377/377；专项六项及 manifest 子集再次通过 |
| 驱动契约 | 203 tests、definitions、C oracle、1,088 项字段归属检查全通过 |
| 静态复审 | style、lifecycle、profile、Phase-1A、固定基线等价/目录契约、diff 全通过 |

所有上述 suite 的 UVM WARNING/ERROR/FATAL 均为零。三项 E2E 各有 4 条既有编译
告警（2 FLWI、2 外部 net_packet SV-ANDNMD），其它 suite 编译告警为零；没有
为消除外部告警修改依赖。core 因新增专项由 104/87 增至 105/88，不把注册增长
误称为旧用例覆盖增加；也不把编译成功代替测试完成。

所有 VCS 均通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 执行。
使用既有锁定依赖，外部 suite 仍由 Make preflight 校验：

```text
HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem.audit.current
DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common
NET_PACKET_ROOT=/home/ubuntu/net_packet_latest
PCIE_WORK_ROOT=/home/ubuntu/workspace/pcie_work_audit.POaPmh
```

本机日志均在 `/tmp`，前缀 `rdma_batch236_`：首次失败为 `baseline.log`，修订旧版
为 `baseline_fixed.log`；重构版为 `focused.log`、`core.log`、`cmq.log`、
`integration.log`、`host_mem.log`、`pcie_work.log`、`driver_contract.log`、
`e2e.log`、`e2e_multivf.log`、`e2e_traffic.log`。各组 wrapper 真实退出码在
`group_{baseline,baseline_fixed,core,cmq,external,e2e}.log`，以修订基线组为准。
静态证据为 `python.log`、`style.log`、`lifecycle.log`、`profile.log`、
`phase1a.log`、`audit.log`；原始/修订基线和最终送测哈希分别为
`baseline_inputs.sha256`、`baseline_fixed_inputs.sha256`、`final_inputs.sha256`。
最终复核见 `style_final.log`（零输出）、`boundary.log`、`manifest.log` 及
`verification_summary.log`（计数、矩阵、告警、退出码、哈希全部 PASS）。

## 仍开放

完整 producer/consumer/resize 业务编排、SRQ 生命周期、跨 queue/owner 原子性、
外部 ordering/error/backpressure、detached doorbell plan、Phase-1C F2、包依赖
DAG 和全项目最终验收仍 OPEN。项目计划保持 active；本批只是恢复授权规则同源。
