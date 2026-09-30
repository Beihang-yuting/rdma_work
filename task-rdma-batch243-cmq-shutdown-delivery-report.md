# Batch243：CMQ shutdown 统一释放失败处理与锁出口

日期：2026-09-30；基线：`40e6c52`；分支：`feature/rdma-structural-batch226`。
本批不合并、不推送；main 保持 `083e0d7`，已有缓存与外部依赖不修改。

## 改动与边界

`shutdown()` 把 release null/非 OK 的重复 authority 保留合为一个分支，释放结果
直接使用 output status，不再经过临时 `release_status`。七处提前解锁/返回收为
单次业务段中的六处退出，最终只解锁一次；没有嵌套循环或 `disable`。

准入 → best-effort 取消 → 丢弃三个交付 FIFO → 原方式释放 backing → 清配置的
顺序不变。释放仍在原锁内；null 先保留 authority 再创建诊断，非 OK 返回 adapter
原 status 对象。缺 authority 分支仍使用原默认释放模式；成功和 UNCONFIGURED
幂等关闭均清配置。retained journal 不删除，也不因 shutdown 产生 isolation proof。

没有新增生产方法、字段、owner、账本、锁或公开接口。完整修订 shutdown 的三段
说明及内部设计注释；修正 `retain_release_authority()` 旧说明中虚构的代际拒绝和
旧 reset 调用关系；补明 `reset_observed()` 释放成功后 CAS 漂移会清 alias 并
POISONED，而非所有失败都保留原 runtime。这两个方法正文没有修改。

方法 **75→63 行**，tokens **362→309**；engine **13,776→13,773 行**，生产净减
**3 行**（含同步完善的注释）。这是局部重复收敛，不称为整个 CMQ 架构已精简完成；
新增验证与文档另计，不称为全仓代码净减。

## 对照验证与复审

新增独立 `rdma_cmq_shutdown_delivery_test`，不运行父类 run_phase，不覆盖生产
shutdown/cancel/retain。30 场景、每例 3 次公开 shutdown，共 90 次调用：

- PREPARED、ACTIVE、QUIESCED、POISONED × 普通/opaque release × 成功/null/非 OK，24 例。
- UNCONFIGURED 幂等、空引擎/ACTIVE gate、保留枚举、缺 adapter、缺 mapping，6 例。

PREPARED 使用真实 prepare；其他非空场景真实 prepare/activate/submit 后注入目标
状态，QUIESCED/POISONED 注入不等于覆盖其全部自然迁移。检查精确诊断、status
对象身份、锁内 adapter 回调、调用前 FIFO 丢弃、失败保留原 mapping/adapter/mode/
last_poison、allocation 活跃/释放状态、修复重试与幂等无额外 I/O。用两次 try_get
检查每次返回恰好一个锁 token，回调时零 token；10us watchdog 防止挂死。
retained 行身份/数量、attempt、PUBLISH_CONFIRMED 状态与无 reset proof 均需保持。
缺 authority 的恢复仅为测试专用 seam，不声称生产能自动找回丢失引用。

四项 Python 门禁固定单次段/六个退出、准入/取消/FIFO/release 顺序、原释放方式
与 null-only 状态构造、公开专项注册。另在内存注入四种循环、release 提前和丢失
opaque 位，六种破坏均被拒绝。防御性的 cancel null/非 OK 分支由完整方法对照
保留；本专项不声称能用普通 fixture 动态触发其全部 hostile factory 路径。

固定 `40e6c52` 做完整方法对照：显式展开合并失败分支/临时变量、六个退出和单次段
后，含诊断字符串的 token 与旧版完全一致。其余 **212 方法正文**、213 方法声明、
31 非 protected 声明、类壳/字段及 **207 个其它既有 SV 文件**不变。
package/manifest 各只注册一个专项。

从 engine 文件头与所有权字段复核 cancel、clear/retain、rollback、reset release
及 shutdown 的完整相关方法，完整检查新测试和复用 fixture/mock 的调用与清理。
目录契约扫描 **209 SV / 5,419 方法 / 零诊断**；扫描和本批边界复审不等于全目录
注释语义、全局并发或最终 ownership 验收。

## 验证状态

全部仿真和驱动 wrapper 真实退出码为 0；结果如下。最终测试相对送测版只调整注释
和参数列表换行，完整代码/字符串 token 一致，其余冻结输入字节不变。

| 验证项 | 最终结果 |
| --- | --- |
| 旧版专项 / 重构版 core 内专项 / 注释版独立专项 | 各完成 30 场景 / 90 次公开调用，完成标记齐全 |
| core | 112 PROCESS / 95 LOGICAL，112 份 pristine 报告；本批及既有十八组矩阵标记齐全 |
| CMQ | 28 PROCESS / 11 LOGICAL，28 份 pristine 报告 |
| integration / Host-memory / PCIe | 10 / 3 / 1，全通过 |
| 双环境 / 多 VF / 高流量 E2E | 各 1，全通过 |
| Python | 409/409，含新增四项门禁；另有六项静态破坏拒绝检查 |
| 驱动契约 | 203 tests、definitions、C oracle、1,088 项字段归属检查全通过 |
| 静态复审 | style（含暂存后）、lifecycle/profile/Phase-1A、完整方法/目录契约、diff 全通过 |

全部最终 suite 的 UVM WARNING/ERROR/FATAL 为零；三组 E2E 各保留 4 条既有
编译告警（2 FLWI、2 外部 net_packet SV-ANDNMD），其它 suite 无编译告警。
core 从 111/94→112/95 是新增专项注册，不解释为既有矩阵覆盖扩大。

所有 VCS 均经 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 执行，
固定依赖不修改：

```text
HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem.audit.current
DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common
NET_PACKET_ROOT=/home/ubuntu/net_packet_latest
PCIE_WORK_ROOT=/home/ubuntu/workspace/pcie_work_audit.POaPmh
```

证据前缀 `/tmp/rdma_batch243_`；旧版临时工作树为 detached `40e6c52` 的
`/tmp/rdma_batch243_baseline.ha5W96`，只加入同一专项/注册；核对哈希及脏文件范围后
已清理，可由固定提交与本批测试重建，日志保留。`baseline_inputs.sha256` 记录旧生产
与专项；`sent_inputs.sha256` 记录初次完整送测输入。复审后仅修订新测试四处说明，
包括 restore 会同时恢复 mapping/adapter；`test_before_comments.sv` 保留原测试，
审计核对其原哈希、全部代码/字符串 token 等价及其它冻结输入字节不变。
`final_inputs.sha256` 固定最终文本。独立专项已运行四处注释修订版；最后仅将
超 100 列的 prepare_defaults 参数列表换行，清除 style 软提示，未再次仿真。
审计确认该格式变更不改变任何代码/字符串 token，最终 Python/static 再次通过。

有效 suite 日志为 `baseline.log`、`focused.log`、`core.log`、`cmq.log`、
`integration.log`、`host_mem.log`、`pcie_work.log`、`e2e.log`、`e2e_multivf.log`、
`e2e_traffic.log` 和 `driver_contract.log`；`group_baseline.log`、
`group_focused.log`、`group_core.log` 和 `group_external.log` 记录全部零退出码。
`audit.py`/`audit.log` 保存受控结构对照、目录契约和注释/格式等价；
`negative.py`/`negative.log` 保存六项破坏门禁；`verify_logs.sh` 与
`verification_summary.log` 统一检查报告数、矩阵标记、告警、退出码及最终哈希。

首次编译发现测试引用了不存在的枚举/attempts 成员；随后发现测试 opcode 不属于
fixture profile，以及 journal 预期误用 PENDING_EFFECT、非法状态值 99 被截断为
合法枚举。均在测试中修正，没有为了测试改生产行为。初始失败日志分别保存在
`baseline_compile_failed.log`、`baseline_fixture_failed.log`、
`baseline_expectation_failed.log` 和 `focused_expectation_failed.log`，不计通过。
首次统一日志检查因上述 100 列软提示未满足“style 日志为空”而拒绝；换行后重查，
没有忽略提示或放宽门禁。
Phase-1A 使用普通代码提交检查模式；误调用仅用于单独审批制品的 `--staged` 模式
被其“索引只能含审批制品”规则拒绝，不计通过，也没有修改审批文件或放宽规则。
早期 external 编排的 E2E 名称有误，已在进入这些测试前停止编排并按实际注册名
重启整组；`integration_early.log`/`group_external_early.log` 不计最终验收。

## 尚未关闭

CMQ 的 submit/recovery/reset 编排、protected 兼容层与整体规模，更广的 queue-data/
resource/lifecycle 结构、跨组件并发、SRQ 完整组合、SQD/SQE drain/flush、外部
ordering/error/backpressure、Phase-1C F2 whole-plan 和最终 ownership 审计仍未关闭。
两个重构计划继续 active。
