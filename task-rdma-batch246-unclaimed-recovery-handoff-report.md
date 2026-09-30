# Batch246：queue-data 未接管恢复证据移交阶段

日期：2026-09-30；基线：`b3d84de`；分支：`feature/rdma-structural-batch226`。
不合并、不推送，main 保持 `083e0d7`；保留既有缓存，不修改外部依赖。

## 改动与业务边界

`recover_queue` 按“控制面校验 → 未接管证据移交 → claimed/reservation-only 定位
→ 中止或授权重放”阅读。把原 unclaimed 块完整收为同类 protected 同步方法
`handoff_unclaimed_device_recovery`，没有新组件、持久字段、锁、owner 或公开接口。

新阶段返回 bit 表示 caller 是否继续，不替代业务 status。`found`、`status` 使用
ref 保留 caller 槽和对象身份；没有表项时不改这两个槽，也不分配成功状态。
pair 完整性与 attachment identity 校验、virtual admission、reservation/state 查询、
detach 的顺序与全部诊断保持原样。只有成功接管或 fallback abort 成功才成对删表；
fallback abort 立即结束，成功接管继续 claimed 扫描，不能丢掉 engine-owned
attachment 的第一 authority。失败状态仍按原分支传播，不新增自动 retry。

移出的局部变量只在该同步阶段使用；初始化均为无回调常量赋值，仍在 key 计算和
admission 前完成。删除原来只声明、从未引用的 `candidate`。控制面 action/确认
门禁仍在移交前；pending 查询、AMBIGUOUS 拒绝、runtime 一次性授权及 replay
仍由主入口按原顺序执行，runtime/backing 生命周期不变。

入口 **201→126 行，942→536 code/string tokens**；含中文说明的生产文件
**9,855→9,883 行，47,350→47,413 tokens**，方法 **139→140**。这批是完整业务
阶段的可读性整理，生产净增 28 行，不称为总代码收缩或整体框架重构已完成。

## 专项与复审

新增 `rdma_unclaimed_recovery_handoff_test`，只调用旧的公开 `recover_queue`，
不直接测试新阶段，也不复跑父测试。复用 runtime 单测的身份/route/断言；使用
真实 configure、activate、reservation、查询、cancel、admission 与 abort。
仅在原有 virtual admission seam 返回注入错误/null，或真实接管后持锁阻断 retry
的 pending 查询。test-only subclass 安装合成索引及坏状态，不改生产可见性。

共 **104 次恢复调用**：

- 16 种 fault × admission 错误/null × abort/确认 retry/未确认 retry = 96 次。
  包括配对表缺失/null、runtime 缺失、generation 换代、无表项 reservation-only、
  pending cursor 缺失/不符、QUIESCING、reservation 已取消、runtime/resize 锁忙、
  主 attachment 索引缺失及错误 host-produced 方向。
- 4 次 raw reservation cursor factory null/错型故障。
- 真实接管后的 claimed abort、重复 abort，以及成功接管后 query_pending 锁忙、
  释放锁后的 claimed abort，共 4 次。

矩阵比较精确 code/message、admission 次数、接管时 pair 仍存在、pair 对象身份、
attachment 保留/删除、PI/CI/used 和 runtime token 数；真实接管分支另外检查最终
状态及不重复 admission。不把合成 fixture 当成自然 device publish，也不宣称
覆盖所有 route/epoch/factory/null-status 或并发调度组合；既有发布和全链路回归
承担对应业务覆盖。

四项 Python 门禁固定同类阶段/ref、控制门禁先后、证据成对删除和独立注册。
六项只在内存的破坏注入（丢 ref、未确认 retry 绕过、忽略阶段终止、提前删表、
半删 pair、fallback abort 继续）全部被拒绝，不修改生产源码。

固定 `b3d84de` 完整方法对照：内联新阶段，恢复原 return 与精确列举的局部声明/
初始化后，**整个 recover_queue 的代码和诊断字符串 token 一致**。139 个已有
声明、27 public、类壳/字段不变，其余 138 个方法 token 一致；210 个其它既有
SV 文件字节不变，package/manifest 各只增加一个专项注册。

从 engine 文件头、成员所有权、原 evidence 生成/admission、detach 原子窗口、
claimed 扫描、reservation-only、三方向 replay 及 runtime 查询/授权/结束路径复审
上下文。目录契约扫描 **212 SV / 5,469 方法 / 零诊断**；这不是全目录中文注释
语义与所有并发场景的最终审计，也不关闭整体 ownership 验收。

## 验证状态

全部最终选定 suite 的 wrapper 真实退出码均为 0。

| 验证项 | 最终结果 |
| --- | --- |
| 旧生产 / 重构版 core 专项 / 注释终版专项 | 各完成 104 次公开恢复调用，完成标记齐全 |
| core | 115 PROCESS / 98 LOGICAL，115 份 pristine；本批及既有二十一组矩阵标记齐全 |
| CMQ | 28 PROCESS / 11 LOGICAL，28 份 pristine |
| integration / Host-memory / PCIe | 10 / 3 / 1，全通过 |
| 双环境 / 多 VF / 高流量 E2E | 各 1，全通过 |
| Python | 初轮与最终静态门禁均 421/421，四项新门禁及六项静态破坏通过 |
| 驱动契约 | 203 tests、definitions、C oracle、1,088 项字段归属全通过 |
| 静态复审 | style（含暂存后）、lifecycle/profile/Phase-1A、完整方法/目录契约、diff 均通过 |

全部仿真 UVM WARNING/ERROR/FATAL 均为零；三组 E2E 各有 4 条既有编译
告警：2 FLWI、2 外部 net_packet SV-ANDNMD，其它 suite 无编译告警。
core 的 114/97→115/98 仅是新增一个专项，不表示既有组合矩阵维度扩大。

所有 VCS 经 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 执行。
外部依赖仅消费、不修改：

```text
HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem.audit.current
DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common
NET_PACKET_ROOT=/home/ubuntu/net_packet_latest
PCIE_WORK_ROOT=/home/ubuntu/workspace/pcie_work_audit.POaPmh
```

证据前缀 `/tmp/rdma_batch246_`。`baseline_inputs.sha256` 固定旧生产和最终专项/
注册，`sent_inputs.sha256` 固定重构版完整回归输入；`audit.py`/`audit.log` 保存
整方法展开、API/状态和目录扫描；`negative.py`/`negative.log` 保存六项拒绝检查。
`group_*.log` 记录 wrapper 的真实退出码，不仅依赖 UVM summary 判定成功。

送测后只修正 engine 的四处说明：移交包含 runtime 提交、reservation 查询实际
位于恢复流程、claimed 多匹配比较 attachment 对象，以及无 pair 与不完整 pair 的
区别。生产 code/string tokens 与首轮送测一致（`sent_tokens.log` 与
`reviewed_tokens.log`）；后续串行 wrapper 可能消费注释终版，不把各 suite 的输入
称为全部字节相同。`reviewed_inputs.sha256` 固定最终生产/专项/注册，另运行
`reviewed.log` 的终版专项。测试与两处注册始终和旧生产专项字节一致。

最终仿真日志为 `baseline.log`、`core.log`、`cmq.log`、`integration.log`、
`host_mem.log`、`pcie_work.log`、`e2e.log`、`e2e_multivf.log`、`e2e_traffic.log`、
`reviewed.log`、`driver_contract.log`；六个 `group_*.log` 保存全部 wrapper 退出码。
`verify_logs.sh`/`verification_summary.log` 汇总实际计数、既有矩阵完成标记、告警、
静态结果与退出码；`final_inputs.sha256` 固定最终交付文件。

## 尚未关闭

queue-data/resource/lifecycle 整体编排、CMQ submit/recovery/reset 与 protected
兼容层、跨组件并发、SRQ 完整组合、SQD/SQE drain/flush、外部
ordering/error/backpressure、Phase-1C F2 whole-plan 和最终 ownership 审计仍开放。
两个重构计划保持 active；本批不新增薄 facade，不把单个恢复入口变短解释为整体完成。
