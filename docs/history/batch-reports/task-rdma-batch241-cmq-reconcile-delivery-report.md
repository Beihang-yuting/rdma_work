# Batch241：CMQ reconcile 统一退出与状态交付

日期：2026-09-29；基线：`4c5b76a`；分支：`feature/rdma-structural-batch226`。
本批不合并、不推送；main 保持 `083e0d7`，既有缓存和外部依赖不修改。

## 改动与取舍

`reconcile_ticket()` 的 10 处解锁/返回合为单次 observation 段后的一个锁出口。
段内没有嵌套循环，`break` 只结束本次查询；不依赖 `status.ok()` 决定是否已完成，
因此合法的 Host-visible/PENDING operation failure 不会被当作查询结构错误。

原业务顺序保持：reset gate → 冻结 ticket → retained lookup → 仅当前 ACTIVE
pending 验证 runtime authority、expire/poll、重读 journal → 分类并交付。
普通终态、timeout/late/reset retained 证据仍不要求当前 runtime ACTIVE；查询
不消费 FIFO、不重试发布、不敲 doorbell、不等待 deadline。

`project_reconciled_journal_item_locked()` 的 Host-visible 与 current pending
共用一次 operation-status snapshot，先分别验证 NONE/PENDING phase 和 completion
形状；Host-visible 优先级和两种 null-snapshot 文案保留。终态仍走独立 completion
快照，成功后才设置 `terminal_known`；输出 operation status 与 completion 内部
status 分别复制，不能把值相同误当成应共享对象。同步修正该方法的失败说明：
嵌套 snapshot 拒绝保留原码，并非所有错误都强制映射为 INVALID_STATE。

没有新增方法、类、公开 API、实例字段、owner、账本或锁。入口 **146→140 行**，
projector **91→88 行**，相关 tokens **1,081→988**；engine **13,801→13,795 行**，
生产实际净减 **6 行**。本批主要降低退出/状态交付重复，不称为大规模收缩；新增
测试与文档量另计，不称为全仓净减。

## 对照测试与复审

新增独立 `rdma_cmq_reconcile_delivery_test`，复用 Batch240 的真实 submit/retained
图夹具，直接调用公共 reconcile，不调用内部 projector 或父类 run_phase。
共 **25 场景 / 63 次查询**：

- 15 类 lifecycle/拒绝场景：STAGED、PENDING_EFFECT、Host-visible、四种终态、
  当前 pending、reset release gate、null ticket、host 坏 phase、非 ACTIVE pending、
  缺索引、坏 deadline、CQ read 失败。
- 四种终态分别注入 payload null status/nonOK，共 8 例；Host-visible 的 required
  status 注入 null 和保留编码，共 2 例。
- 每例重复查询两次；10 类 snapshot 故障及 CQ read 故障修复后再查询。当前 pending
  另在真实 5ns deadline 到期后查询两次，只有第一次允许产生一条 timeout FIFO。

检查精确错误/operation 文案、terminal/completion 清理、detached status/ticket/
raw/payload、FIFO 不消费、Host-memory 访问边界、无 MMIO/attempt 推进和单次 submit；
重复调用及最终 try_get/shutdown 检查锁释放，10us watchdog 防泄漏。

初版将 X 注入 `rdma_status_code_e`，但该枚举底层是 `bit [4:0]`，X 被二态转换
为 0（OK），旧版正确返回了有效状态；测试预期不正确，两次查询产生两条断言错误。
仅将测试注入改为保留编码 `5'd31`，不改生产枚举或状态处理。初版 `baseline.log`
不是通过证据；有效修订基线使用 `baseline_fixed.log`，不声称覆盖不存在的 X 状态。
payload 的 null status 同样先由 snapshot 层转换为非空错误，不冒充顶层 helper
直接返回 null 的动态覆盖；原防御文案由固定基线对照保留。

四项 Python 门禁固定单锁出口/10 个 break/无内层循环、retained-first 和单次
expire/poll 后重读、单一非终态 snapshot/Host-visible 优先及专项注册。
最终复审补齐内层 `while/do` 的显式拒绝，避免只禁 `for/foreach/forever` 留下缺口；
在内存中分别注入两种内层循环，确认均被该门禁拒绝。该补充只影响 Python 静态
门禁，不改变送测 SV 输入，负向证据为 `loop_gate_negative.log`。
固定 `4c5b76a` 审计展开单次段与 10 个 break 后，完整公共方法逐 token 相同；
对 projector 只允许明确列出的 host/pending guard 归并和共用快照变换，完整方法
包含所有诊断字符串通过对照。213 方法声明、31 非 protected 声明、另外 211 方法
正文、类壳/字段及 205 个其它既有 SV 文件不变。

从 engine 文件入口和所有权字段复核 lookup/identity、expiry/poll、retained status/
completion snapshot 及输出交付链；完整复核新增测试、复用 probe 的注入/清理和注册。
目录契约扫描 **207 SV / 5,396 方法 / 零诊断**；扫描及本批局部语义复审不等于
全目录注释语义、全局并发或最终架构验收。

## 验证状态

全部验证完成，各有效 wrapper 真实退出码为 0，最终送测输入哈希一致。

| 验证项 | 最终结果 |
| --- | --- |
| 修订旧版 / 重构版专项 | 各 1 PROCESS / 1 LOGICAL，25 场景 / 63 查询完成标记齐全 |
| core | 110 PROCESS / 93 LOGICAL，110 份 pristine 报告；本批及既有十六组矩阵标记齐全 |
| CMQ | 28 PROCESS / 11 LOGICAL，28 份 pristine 报告 |
| integration / Host-memory / PCIe | 10 / 3 / 1，全通过 |
| 双环境 / 多 VF / 高流量 E2E | 各 1，全通过 |
| Python | 401/401，含新增四项出口/投影门禁；另有两项内层循环负向检查 |
| 驱动契约 | 203 tests、definitions、C oracle、1,088 项字段归属检查全通过 |
| 静态复审 | style（含新增文件暂存后）、lifecycle/profile/Phase-1A、固定基线/目录契约、diff 全通过 |

所有最终 suite 的 UVM WARNING/ERROR/FATAL 均为零。三组 E2E 各保留 4 条既有
编译告警（2 FLWI、2 外部 net_packet SV-ANDNMD），其它 suite 编译告警为零。
core 因新专项注册从 109/92→110/93，不把注册增长称为旧矩阵覆盖扩大。

所有 VCS 均通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 执行；
固定依赖如下，未修改依赖仓库：

```text
HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem.audit.current
DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common
NET_PACKET_ROOT=/home/ubuntu/net_packet_latest
PCIE_WORK_ROOT=/home/ubuntu/workspace/pcie_work_audit.POaPmh
```

本机证据前缀 `/tmp/rdma_batch241_`。修订基线来源 detached `4c5b76a` 临时工作树
`/tmp/rdma_batch241_baseline.oRLo41`（核对仅含本批测试和注册后已清理，可由
`4c5b76a` 加本批测试/注册重建，日志保留）；`baseline_fixed_inputs.sha256` 固定旧生产、
新专项和复用 probe 字节，`final_inputs.sha256` 固定重构版送测输入。
`audit.py` / `audit.log` 保存结构对照和目录契约；各 suite/group 日志记录报告及
wrapper 真实退出码。有效 suite 日志为 `baseline_fixed.log`、`focused.log`、
`core.log`、`cmq.log`、`integration.log`、`host_mem.log`、`pcie_work.log`、
`driver_contract.log`、`e2e.log`、`e2e_multivf.log` 和 `e2e_traffic.log`；
`group_baseline_fixed.log`、`group_core.log`、`group_cmq.log`、`group_external.log`
均记录零退出码。`python.log`、`style.log`、`style_staged.log`、`lifecycle.log`、
`profile.log` 和 `phase1a.log` 保存静态结果；`verify_logs.sh` 统一核对最终报告数、
矩阵标记、告警类别、退出码和哈希，`verification_summary.log` 最终为 PASS。

## 尚未关闭

本批只收束 reconcile 的锁和状态交付；CMQ 整体规模、submit/recovery/reset 编排、
protected 兼容层、更广 queue-data/resource/lifecycle 结构、跨组件并发、SRQ 完整
组合、SQD/SQE drain/flush、外部 ordering/error/backpressure、Phase-1C F2 whole-plan
及最终 ownership 审计仍未关闭。两个重构计划继续 active。
