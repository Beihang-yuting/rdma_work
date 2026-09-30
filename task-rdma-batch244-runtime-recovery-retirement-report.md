# Batch244：Queue runtime 恢复结束状态清理归一

日期：2026-09-30；基线：`4718484`；分支：`feature/rdma-structural-batch226`。
本批不合并、不推送；main 保持 `083e0d7`，保留既有缓存，不修改外部依赖。

## 改动与边界

`complete_recovery_retry()`、`complete_consumer_recovery_noalloc()`、
`abort_recovery()` 和 `recover(ABORT_AND_DETACH)` 共用同类内的
`retire_recovery_locked(final_state)`。只集中四处相同的结束清理：清 pending
引用、reservation 有效位及引用、commit/release/retry 三个授权位，最后发布 state。

入口仍各自决定完成证据、拒绝优先级、ACTIVE/DETACHED、锁与 status 交付。
普通入口保持 acquire 的锁内 factory 回调及解锁后结果构造；noalloc 保持零对象
构造，先更新旧 pending 的 CQ release marker，再丢弃引用、解锁、原位写 status。
不推进或回滚 PI/CI，不修改 used、slot ledger、identity、route/epoch，不释放外部
backing。不把 configure、admission 失败回滚或 release 屏障撤销并入结束恢复。

四个方法各减少 6 行；新增一个 protected 无分配操作，无新增字段、owner、账本、
锁或 public API。包含文件头、设计依据与四入口注释的同步更新后，runtime
**3,797→3,795 行**，代码/字符串 tokens **19,025→18,947**。这是重复状态迁移
的集中维护，不称为大规模收缩；新增测试和文档另计，不声称全仓净减。

## 对照验证与复审

新增独立 `rdma_runtime_recovery_retirement_test`，不调用父 run_phase 或内部
清理，也不覆盖生产完成/中止方法。共 241 次被测结束调用：239 次末阶段/拒绝
fixture 调用，以及 2 次从真实 device publication、prepared admission、consumer
CI commit 到完成的公开流程。

- 四入口 × 三种 status factory（正常/null/错型）× 八组 gate × 成功/重复调用。
- SQ/RQ/SRQ host producer，CQ/CEQ/AEQ device producer 与 consumer 的完成入口。
- 缺 pending、错误 state、null/busy lock、缺 CQ release 拒绝/修复和 null status slot。
- 检查精确 code/message、noalloc 原槽身份、六项恢复字段、旧 pending 最终 release
  marker、未变的 queue handle/slot 身份及账本字段、route/epoch、PI/CI/used。
- 每次返回探测恰有一个锁 token，busy/null lock 为零；普通 factory 在锁内观察旧
  状态、解锁后观察最终状态，noalloc 全程零 factory；1us watchdog 防止挂死。

gate 组合和 reservation 残留由 test-only probe 注入，不把这些防御 fixture
解释为合法 admission 的自然迁移；锁忙采用同步占锁，不声称覆盖跨组件线程交错。
slot 检查包含嵌套对象身份，不声称本专项穷举所有嵌套 request/image 内容。

四项 Python 门禁固定共享操作的完整七项赋值、四入口及最终状态、CQ marker/
status 交付顺序与专项注册。另有六项内存破坏注入：丢 retry、提前发布 state、
额外解锁、中止误激活、漏 noalloc 委托、noalloc 新建 status，均须被门禁拒绝。

固定基线完整对照：把新 helper 展开回四个入口后，含字符串的全部 token 与旧版
一致；**71 个其它方法正文、75 个已有声明、58 public 声明、类壳/字段不变**。
**208 个其它既有 SV 文件**字节不变；package/core manifest 各只增加一个专项。
目录契约扫描为 **210 SV / 5,436 方法 / 零诊断**。

从 runtime 文件头、字段和生命周期入口复核相关 configure、admission、commit、
release gate、marker、证据投影、complete/abort/recover 方法及依赖，完整审阅
新专项与静态门禁。目录扫描和本批边界复审不等于全目录注释语义、全局并发或
最终 ownership 验收。兼容 protected 值转发和 CMQ 的不同发布策略不在本批删除。

## 验证状态

全部选定 suite 的 wrapper 真实退出码为 0；生产、专项和注册输入自送测起字节未变。

| 验证项 | 最终结果 |
| --- | --- |
| 旧生产专项 / 重构版 core 内专项 | 各完成 241 次结束调用，完成标记齐全 |
| core | 113 PROCESS / 96 LOGICAL，113 份 pristine；本批与既有十九组矩阵标记齐全 |
| CMQ | 28 PROCESS / 11 LOGICAL，28 份 pristine |
| integration / Host-memory / PCIe | 10 / 3 / 1，全通过 |
| 双环境 / 多 VF / 高流量 E2E | 各 1，全通过 |
| Python | 413/413，含新增四项门禁；另有六项静态破坏拒绝检查 |
| 驱动契约 | 203 tests、definitions、C oracle、1,088 项字段归属全通过 |
| 静态复审 | style（含暂存后）、lifecycle/profile/Phase-1A、完整方法/目录契约、diff 全通过 |

全部仿真的 UVM WARNING/ERROR/FATAL 为零。三组 E2E 各有 4 条既有编译告警：
2 FLWI、2 外部 net_packet SV-ANDNMD；其它 suite 无编译告警。
core 的 112/95→113/96 仅是新增专项注册，不表示旧矩阵的覆盖维度扩大。

所有 VCS 经 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 执行；
固定外部依赖只消费、不修改：

```text
HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem.audit.current
DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common
NET_PACKET_ROOT=/home/ubuntu/net_packet_latest
PCIE_WORK_ROOT=/home/ubuntu/workspace/pcie_work_audit.POaPmh
```

证据前缀 `/tmp/rdma_batch244_`；`baseline_inputs.sha256` 在生产修改前固定旧
runtime 与专项/注册输入，旧生产同步到远端并进入编译后才修改本地 runtime。
`sent_inputs.sha256` 固定重构版输入；审计核对旧生产对应 `4718484`，且专项和
注册与旧版送测字节相同。`audit.py`/`audit.log` 保存完整展开对照及目录契约；
`negative.py`/`negative.log` 保存六项破坏门禁。没有创建或删除本地 baseline 工作树。
有效日志为 `baseline.log`、`core.log`、`cmq.log`、`integration.log`、
`host_mem.log`、`pcie_work.log`、`e2e.log`、`e2e_multivf.log`、`e2e_traffic.log`
和 `driver_contract.log`；三个 `group_*.log` 保存全部 wrapper 零退出码。
`verify_logs.sh`/`verification_summary.log` 核对计数、矩阵标记、告警、退出码及
最终输入；`final_inputs.sha256` 固定交付源码、测试、注册与文档。

首次静态专项使用空白文本比较，因函数签名换行及 sanitizer 擦除字符串后的
空白而失败；已改用完整 token 对比和仅合并空白，未放宽字段/顺序约束。
新测试的软行宽/单行 return 提示已在送测前修正；不存在生产行为迁就测试的修改。

## 尚未关闭

CMQ submit/recovery/reset 编排与 protected 兼容层、queue-data/resource/lifecycle
整体结构、跨组件并发、SRQ 完整组合、SQD/SQE drain/flush、外部
ordering/error/backpressure、Phase-1C F2 whole-plan 和最终 ownership 审计仍开放。
两个重构计划保持 active。
