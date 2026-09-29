# Batch240：CMQ execute 单一观测结果出口

日期：2026-09-29；基线：`43b40b5`；分支：`feature/rdma-structural-batch226`。
本批不合并、不推送；main 保持 `083e0d7`，既有缓存和外部依赖不修改。

## 改动与边界

`execute_observed()` 原有五段 builder/失败回退收为一个锁内交付出口：

| retained 证据 | 业务选择 |
| --- | --- |
| STAGED / PENDING_EFFECT | 立即快照，observation 为 INVALID_STATE，保留未决诊断 |
| HOST_VISIBLE_NOT_PUBLISHED | 检查无终态，再快照 Host-visible 证据 |
| 已有正常/超时/晚到/reset 终态 | 直接快照，不消费 FIFO、不等待 |
| armed pending | 解锁 wait，重新取锁并按同一 ticket 定位 retained 行 |
| wait 后无终态 | 以 INVALID_STATE 快照现有行；缺行时不调用 builder，回退 submitted |

分支仅选择三个调用期值：observation code、诊断文案及 null-snapshot 诊断。
共享出口按原顺序分配 detached 图；失败仍返回原 delegated submitted，仅更新
observation status。operation status/effect/phase 不由 wait 的临时输出覆盖。
零 identity envelope、lookup/authority 早拒绝、Host-visible terminal guard 和
malformed lifecycle 的原错误优先级、锁释放位置均保留。

没有新增 helper、类、公开 API、实例字段、owner 或账本。方法 **219→180 行**，
tokens **1,036→851**；engine **13,837→13,801 行**，生产实际净减 **36 行**。
测试及报告新增量单独计，不称为全仓代码净减。

## 对照测试与复审

新增独立 `rdma_cmq_execute_observation_test`，从公共 execute 进入：16 个生命周期/
委托场景，加四种终态各两种 payload 快照故障，共 **24 例**。真实 submit 建立
ACTIVE runtime 和 journal；probe 仅在委托返回边界注入 retained 状态或旧快照，
execute/build/wait 均为生产实现。测试覆盖立即返回、真实 5ns timeout、reset
release gate 拒绝 wait、wait 解锁后的索引丢失、Host-visible 畸形 phase、旧 attempt、
初次 lookup 失败、null/合法 PRE/畸形 PRE envelope，以及 payload null status/nonOK。
验证各分支诊断、retained 优先、结果分离和 completion 内部 alias、单次 submit、
无意外等待与锁释放；各例撤销注入后真实 shutdown，10us watchdog 防锁泄漏。
payload 返回 null status 会先被快照层转为非空错误，本矩阵不把它误记为 builder
直接返回 null 的覆盖；五种 null-snapshot 防御文案由固定基线对照和静态门禁保留。

初版正常/晚到完成 fixture 漏构造必需 raw CQE，旧版在两个运行中各报 6 条错误，
均指向这两个场景。检查 completion shell 契约后只修正测试：补齐 64-byte canonical
raw image；timeout/reset 继续允许 raw null。没有为测试改变生产行为。
`baseline.log` 和 `baseline_final.log` 不作为通过证据；有效修订基线使用
`baseline_fixed.log` 及对应输入哈希。

四项 Python 门禁固定唯一 builder/null guard/回退、锁外 wait 后重定位、五组独立
诊断及专项注册。固定 `43b40b5` 审计精确替换五段重复尾部为策略赋值、合并互斥
分支并加入唯一尾部，整个方法逐 token 相同（保留字符串）；公共 null-item guard
在前四条路径由既有非空门禁保证恒不触发，不增加回调或时序。
原 **213 声明 / 31 非 protected 声明**、另 **212 方法正文**、类壳/字段及
**204 个其它既有 SV 文件**保持不变，package/manifest 各只注册一个新测试。

从 engine 文件入口和所有权字段复核了 submit→lookup/identity→lifecycle→wait→
snapshot 的调用链，以及 snapshot context 的 null/raw/payload/alias 契约；完整
复核新测试/probe 和注册变更。目录契约扫描为 **206 SV / 5,392 方法 / 零诊断**。
扫描及本批局部语义复审不等于全目录注释语义、全局并发或最终架构验收。

## 验证状态

全部验证完成，各有效 wrapper 真实退出码为 0，最终送测输入哈希一致。

| 验证项 | 最终结果 |
| --- | --- |
| 修订旧版 / 重构版专项 | 各 1 PROCESS / 1 LOGICAL，24-case 完成标记齐全 |
| core | 109 PROCESS / 92 LOGICAL，109 份 pristine 报告；本批及既有十五组矩阵标记齐全 |
| CMQ | 28 PROCESS / 11 LOGICAL，28 份 pristine 报告 |
| integration / Host-memory / PCIe | 10 / 3 / 1，全通过 |
| 双环境 / 多 VF / 高流量 E2E | 各 1，全通过 |
| Python | 397/397，含新增四项出口门禁 |
| 驱动契约 | 203 tests、definitions、C oracle、1,088 项字段归属检查全通过 |
| 静态复审 | style（含新增文件暂存后）、lifecycle/profile/Phase-1A、固定基线/目录契约、diff 全通过 |

所有最终 suite 的 UVM WARNING/ERROR/FATAL 均为零。三组 E2E 各保留 4 条既有
编译告警（2 FLWI、2 外部 net_packet SV-ANDNMD），其它 suite 编译告警为零。
core 因新专项注册从 108/91→109/92，不把注册增长称为旧矩阵覆盖扩大。

所有 VCS 均通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 执行，
固定依赖如下，未修改依赖仓库：

```text
HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem.audit.current
DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common
NET_PACKET_ROOT=/home/ubuntu/net_packet_latest
PCIE_WORK_ROOT=/home/ubuntu/workspace/pcie_work_audit.POaPmh
```

本机证据前缀 `/tmp/rdma_batch240_`。修订基线来源 detached `43b40b5` 临时工作树
`/tmp/rdma_batch240_baseline.MuMHjU`（核对仅含本批测试和注册后已清理，可由
`43b40b5` 加本批测试/注册恢复，日志保留）；`baseline_fixed_inputs.sha256` 固定旧生产及
最终专项字节，`final_inputs.sha256` 固定重构版送测输入。`audit.py` / `audit.log`
保存受控结构变换和目录契约审计，suite 与 group 日志记录报告及 wrapper 真实退出码。
有效 suite 日志为 `baseline_fixed.log`、`focused.log`、`core.log`、`cmq.log`、
`integration.log`、`host_mem.log`、`pcie_work.log`、`driver_contract.log`、
`e2e.log`、`e2e_multivf.log` 和 `e2e_traffic.log`；`group_baseline_fixed.log`、
`group_core.log`、`group_cmq.log`、`group_external.log` 均记录零退出码。
`python.log`、`style.log`、`style_staged.log`、`lifecycle.log`、`profile.log` 和
`phase1a.log` 保存静态结果。`verify_logs.sh` 统一核对最终报告数、矩阵标记、
告警类别、退出码和哈希，`verification_summary.log` 最终为 PASS。

## 尚未关闭

本批只收缩 execute 观测交付重复；CMQ 整体规模、submit/recovery/reset 编排、
protected 兼容层、更广 queue-data/resource/lifecycle 结构、跨组件并发、SRQ 完整
组合、SQD/SQE drain/flush、外部 ordering/error/backpressure、Phase-1C F2 whole-plan
及最终 ownership 审计仍未关闭。两个重构计划继续 active。
