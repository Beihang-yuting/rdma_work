# Batch242：CMQ wait 统一结束解锁

日期：2026-09-30；基线：`9d069b9`；分支：`feature/rdma-structural-batch226`。
本批不合并、不推送；main 保持 `083e0d7`，既有缓存和外部依赖不修改。

## 改动与取舍

`wait_for()` 的 **32 处解锁/返回**改为两层业务段中的 `break`，所有结束汇合到
唯一最终解锁。外层 `wait_session` 只执行一次准入；内层 `wait_iteration` 仍是原有
轮询。内层退出后没有其它动作，直接离开单次段，因此两层退出都只释放一次锁。
没有使用会影响其它调用的 `disable`，也没有增加 wait 状态旗标或 helper。

原来的中途 **put → 限时 delay → get → gate/identity 重验**仍保留；这是让其它
等待者和生命周期操作推进的窗口，不属于结束清理。`continue` 仍只触发下一轮
retained 观察；deadline 由真实 expiry 产生 completion，不凭时间伪造 timeout。
retained 普通交付可重复观察并删除匹配 FIFO 行，reset authority 竞争分支不消费
FIFO；legacy 无 journal 路径仍转移 FIFO 原对象并保持单次消费语义。

同步重写 wait 的三段功能/边界说明和内部中文设计注释，并修正 retained projector
旧说明：嵌套 snapshot 的非 OK 原码透传，不是全部改成 INVALID_STATE；原有 FIFO
消费先于 status copy，防御性的 copy 失败不会回滚 FIFO。本批没有更改 projector 正文。

方法 **358→331 行**，tokens **1,742→1,539**；engine **13,795→13,776 行**，
生产净减 **19 行**。213 方法声明、31 非 protected 声明及类壳/字段不变；没有
新增生产方法、owner、账本、锁或公开 API。新增测试和文档另计，不称为全仓净减。

## 对照测试与复审

新增独立 `rdma_cmq_wait_delivery_test`，从公开 `wait_for()` 进入；复用真实 submit
夹具，不调用内部 projector、不运行父类 run_phase。共 **31 场景 / 65 次调用**：

- 22 类 lifecycle、准入和等待窗口场景：七类 retained 状态、真实 timeout、入口
  gate/null ticket/host 坏 phase/非 ACTIVE pending/未知 ticket/坏 deadline/read
  故障；五类 100ps 等待期注入（gate/index/state/terminal/caller ticket）；legacy
  FIFO 成功和非 ACTIVE 拒绝。
- 四终态各注入 payload null status/nonOK，共 8 例；拒绝不消费 FIFO，修复后重试。
- 两个 waiter 同时等待一个真实 pending ticket，5ns 后分别获得独立 timeout 图，
  FIFO 最终为空，不新增 submit/attempt，也不互相取消。

普通场景重复调用，read/snapshot 故障修复后再调用；核对精确消息、时间、FIFO、
status/ticket/raw/payload 隔离和 legacy 对象转移。检查 Host-memory 访问范围、无
额外 MMIO、一次 submit、attempt 不变，以及 try_get/shutdown 的锁清理；10us
watchdog 捕获死锁。等待期 terminal 注入是 retained 图夹具，不冒称真实硬件 CQE；
gate 注入不冒称覆盖 reset 全事务或全部并发组合。

四项 Python 门禁固定两层循环/32 处退出、唯一等待让锁窗口、retained-first 与
重验顺序、retained/legacy 差异及测试注册；另在内存中注入 while/do/forever/repeat
四种额外循环，确认门禁拒绝，防止以后改变 break/continue 的目标。
按 begin/end 深度另行检查内层循环后没有动作，并注入一次尾部赋值确认拒绝，
保证内层 break 真正直达最终解锁，而不是只检查解锁调用总数。

固定 `9d069b9` 的完整方法对照：展开 32 个 break 为原解锁/返回，去掉单次段、
新增最终解锁和内层标签后，包含全部字符串的 token 与旧版完全一致。另 212 方法
正文、类壳/字段及 206 个其它既有 SV 文件不变，package/manifest 各只注册一个专项。
从 engine 文件头/所有权字段复核 ticket freeze、retained locate、expiry/poll、
FIFO 投影及让锁后授权链；完整复核新增测试、复用 probe 的注入/清理及注册。
目录契约扫描 **208 SV / 5,404 方法 / 零诊断**；扫描和本批局部语义复审不等于
全目录注释语义、全局并发或最终架构验收。

## 验证状态

全部验证完成，各 wrapper 真实退出码为 0，最终源码匹配 final 输入哈希；
初次送测与最终中文注释版的代码 token 完全一致，其余哈希清单内输入字节相同。

| 验证项 | 最终结果 |
| --- | --- |
| 旧版 / 重构版 / 最终注释版专项 | 各 1 PROCESS / 1 LOGICAL，31 场景 / 65 调用完成标记齐全 |
| core | 111 PROCESS / 94 LOGICAL，111 份 pristine 报告；本批及既有十七组矩阵标记齐全 |
| CMQ | 28 PROCESS / 11 LOGICAL，28 份 pristine 报告 |
| integration / Host-memory / PCIe | 10 / 3 / 1，全通过 |
| 双环境 / 多 VF / 高流量 E2E | 各 1，全通过 |
| Python | 405/405，含新增四项门禁；另有四类循环和一项轮询后动作负向检查 |
| 驱动契约 | 203 tests、definitions、C oracle、1,088 项字段归属检查全通过 |
| 静态复审 | style（含新增文件暂存后）、lifecycle/profile/Phase-1A、固定基线/目录契约、diff 全通过 |

所有最终 suite 的 UVM WARNING/ERROR/FATAL 均为零。三组 E2E 各保留 4 条既有
编译告警（2 FLWI、2 外部 net_packet SV-ANDNMD），其它 suite 编译告警为零。
core 因新专项注册从 110/93→111/94，不把注册增长称为旧矩阵覆盖扩大。

所有 VCS 均经 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 执行；
固定依赖如下，未修改外部仓库：

```text
HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem.audit.current
DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common
NET_PACKET_ROOT=/home/ubuntu/net_packet_latest
PCIE_WORK_ROOT=/home/ubuntu/workspace/pcie_work_audit.POaPmh
```

本机证据前缀 `/tmp/rdma_batch242_`。旧版临时工作树
`/tmp/rdma_batch242_baseline.TKZ6Cl` 为 detached `9d069b9`，仅含本批专项/注册；
核对后已清理，可由该提交和新测试/注册重建，日志保留。`baseline_inputs.sha256`
固定旧生产及测试输入；`sent_inputs.sha256` 固定初次重构送测输入，随后仅翻译了
wait 内部注释。直接读取正在运行的远端 core 输入，确认其字节匹配 sent hash，
且与最终 engine 的全部代码 token 相同；其余哈希清单内输入字节相同，证据为
`comment_equivalence.log`。`final_inputs.sha256` 固定最终中文注释版。

`audit.py`/`audit.log` 保存受控结构对照和目录契约；suite/group 日志分别保存
报告及 wrapper 真实退出码，`loop_gate_negative.log` 保存四类循环拒绝证据，
`post_loop_negative.log` 保存轮询后插入动作的拒绝证据。
有效 suite 日志为 `baseline.log`、`focused.log`、`focused_final.log`、`core.log`、
`cmq.log`、`integration.log`、`host_mem.log`、`pcie_work.log`、`driver_contract.log`、
`e2e.log`、`e2e_multivf.log` 和 `e2e_traffic.log`；`group_baseline.log`、
`group_focused_final.log`、`group_core.log`、`group_cmq.log` 和 `group_external.log`
记录全部零退出码。`python.log`、`style.log`、`style_staged.log`、`lifecycle.log`、
`profile.log` 和 `phase1a.log` 保存静态结果。最终 `verify_logs.sh` 统一核对报告数、
矩阵标记、告警、退出码、注释等价及最终哈希，`verification_summary.log` 为 PASS。

## 尚未关闭

本批只收束等待结束清理；CMQ 整体规模、submit/recovery/reset 编排、protected
兼容层、更广 queue-data/resource/lifecycle 结构、跨组件并发、SRQ 完整组合、
SQD/SQE drain/flush、外部 ordering/error/backpressure、Phase-1C F2 whole-plan
及最终 ownership 审计仍未关闭。两个重构计划继续 active。
