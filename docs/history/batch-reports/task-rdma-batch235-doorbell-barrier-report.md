# Batch235：门铃 barrier 限时执行收束

日期：2026-09-29；基线：`fc8b61f`；分支：`feature/rdma-structural-batch226`。
本批不合并、不推送；main 保持 `083e0d7`，外部依赖与原有缓存不改。

## 改动与业务边界

DMA visibility barrier 和 MMIO ordering barrier 原来各自维护同形的剩余预算检查、
worker/timer、取消与状态交付代码。现在由 `barrier_before_deadline` 共用这项能力，
两个旧 protected task 删除，不保留转发壳。caller 使用具名 `dma_visibility` 参数
显式选择后端操作，公共入口、descriptor policy 和业务顺序不变：

```text
完整预检 → payload/context 写入 → 可选 DMA barrier → 可选 MMIO barrier → MMIO write
```

该 helper 只决定一次 barrier 如何在剩余时间内执行，不负责 Function lock、资源
所有权、submission effect、observer 或真正的 MMIO write。`submit_locked` 继续
处理阶段状态与高水位，`mmio_write_before_deadline` 保留自己的最后 deadline 检查和
`MMIO_MAYBE_VISIBLE` 边界，不能把成功排序视为已提交门铃。

每次调用仍使用两层 fork：独占子进程包住 worker/timer，`disable fork` 只取消本次
调用的后代。不改成具名 disable，不缓存 PCIe adapter，不引入 operation 对象、
实例字段、第二份账本或锁。入口已到期时零后端调用；超时、null 与原始错误的诊断
保持原值，非空后端 status 在 helper 内原引用交付，随后按原流程捕获为 detached
结果。取消仿真 worker 不等同于撤销真实外设已产生的副作用。

生产文件 **1,606→1,580 行，净减 26 行**；文件 methods 44→43，scheduler 类
30→29。两份 barrier 方法合计 270 tokens → 单份 167 tokens（约减少 38%）；
新测试和说明不计入生产收缩。scheduler 的 28 个保留声明、4 个公开声明不变，
其余值类不变；27 个未改 scheduler 方法正文与基线 token 相同。

已从文件入口复审 descriptor/result/legacy 投影、Function lock、deadline、预检、
状态捕获与提交收尾：只更新文件头和新 helper 契约，不混入无关行为或格式修改。
固定基线审计展开二态 selector、诊断字符串和局部块名后，两种 barrier 正文与原
实现 token 等价；`submit_locked` 只替换两处调用。其它 199 个 src/tests-unit SV
文件字节不变，package/manifest 各仅增加一条专项注册。
目录契约扫描为 201 个 SV 文件 / 5,355 methods / 零 diagnostics；词法扫描和既有
文件证据不替代整个项目最终语义、并发与可读性验收。

## 新增验证

新增独立 `rdma_doorbell_barrier_test`，复用原 scheduler test 的 fixture 构造器和
断言，但只执行自己的 run_phase。原 scheduler 大矩阵不再扩长，仍独立纳入 core。
新 test 仅调用公开 `submit_observed`，所以重构前后可使用同一套可执行测试：

- 四种 policy 的立即/延迟成功，共 8 cases。
- DMA-only、MMIO-only、DMA+MMIO 的每个启用阶段分别注入 null、原始错误和超时，
  共 12 cases；检查调用顺序、Function identity、耗时、诊断、effect 和 observer。
- DMA 用 3ns、MMIO 用 3ns，总预算仅 5ns，证明第二阶段只获得剩余预算，共 1 case。
- DMA/MMIO 各一个跨 Function 并发场景：A 在 5ns 超时，B 从 1ns 启动并在 9ns
  完成，另一个 sibling 在 6ns 保持存活，共 2 cases。
- 每个顺序场景在结束后再等 10ns，检查无迟到完成或额外 I/O，并再次提交同一
  Function 验证锁可复用；并发场景也验证锁复用与迟到 worker。

合计 **23 cases**，整个矩阵有 2us watchdog。六项 Python 结构门禁固定唯一执行
入口、取消作用域、总预算/诊断、MMIO/effect 边界、注册顺序和动态断言。
core 因新增一个独立 test 从 103 PROCESS / 86 LOGICAL 增至 **104 / 87**；不能把
新增注册导致的计数增长解释为旧测试变多或重复运行父类。

## 验证状态

旧生产实现的 23-case 基线已通过（1 PROCESS / 1 LOGICAL，UVM 0/0/0），不是仅在
重构后验证。首次静态检查发现新文件头缺层次标记和一条长行，已修正；基线送测后
仅改该文件头和换行，保留原文件 `/tmp/rdma_batch235_baseline_test.sv`，raw hash
核对且终版 tokens 相同。旧版基线没有仿真失败，也没有改变预期来适配重构。

Python **371/371**、六项专项结构检查、manifest、style、lifecycle、profile、
Phase-1A、固定基线等价/目录契约与 diff 门禁通过。

| 验证项 | 结果 |
| --- | --- |
| 旧版基线 / 重构版专项 | 各 1 PROCESS / 1 LOGICAL，均完成 23 cases，UVM pristine |
| core | 104 PROCESS / 87 LOGICAL，104 份 pristine UVM 报告；23-case 新矩阵与既有十组矩阵标记齐全 |
| CMQ | 28 PROCESS / 11 LOGICAL，28 份 pristine UVM 报告 |
| integration / Host-memory / PCIe | 10 / 3 / 1，全部 pristine |
| 双环境 / 多 VF / 高流量 E2E | 各 1，全部 pristine |
| 驱动契约 | 203 tests、definitions、C oracle 与 1,088 项字段归属检查通过 |

全部上述套件的 UVM WARNING/ERROR/FATAL 均为零；三项 E2E 各保留 4 条基线编译
告警（2 FLWI、2 外部 net_packet SV-ANDNMD），其它 suite 编译告警为零。
不修改外部依赖，也不把 pristine UVM 当作编译零告警。最终汇总已核验完整计数、
wrapper 真实退出码均为 0、矩阵标记和冻结输入，不以编译成功代替仿真完成。

所有 VCS 使用 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 执行，
每次独立构建；外部 suite 的 Make preflight 检查依赖锁。路径沿用：

```text
HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem.audit.current
DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common
NET_PACKET_ROOT=/home/ubuntu/net_packet_latest
PCIE_WORK_ROOT=/home/ubuntu/workspace/pcie_work_audit.POaPmh
```

本机证据：`/tmp/rdma_batch235_baseline.log`、`/tmp/rdma_batch235_group_baseline.log`、
`/tmp/rdma_batch235_baseline_inputs.sha256`、`/tmp/rdma_batch235_final_inputs.sha256`、
`/tmp/rdma_batch235_python.log`、`/tmp/rdma_batch235_boundary.log`、
`/tmp/rdma_batch235_manifest.log`、`/tmp/rdma_batch235_style.log`、
`/tmp/rdma_batch235_lifecycle.log`、`/tmp/rdma_batch235_profile.log`、
`/tmp/rdma_batch235_phase1a.log`、`/tmp/rdma_batch235_audit_final.log`。
首次静态日志为 `/tmp/rdma_batch235_style_baseline.log`，修订检查为
`/tmp/rdma_batch235_style_baseline_fixed.log`，不覆盖原始诊断。

回归日志位于本机 `/tmp`，统一使用 `rdma_batch235_` 前缀，分别为
`focused.log`、`core.log`、`cmq.log`、`integration.log`、`host_mem.log`、
`pcie_work.log`、`driver_contract.log`、`e2e.log`、`e2e_multivf.log`、`e2e_traffic.log`；
分组退出码保存在
`/tmp/rdma_batch235_group_{core,cmq,external,e2e,baseline}.log`。最终送测后的
style 复核为 `/tmp/rdma_batch235_style_final.log`（零输出）；最终汇总为
`/tmp/rdma_batch235_verification_summary.log`（全部 PASS）。

## 仍开放

本批不关闭 detached doorbell plan、真实 PCIe ordering/error/backpressure、外部
provider 取消语义、完整 producer/resize 编排、SRQ 全生命周期、跨 owner 原子性、
跨队列并发、Phase-1C F2、包依赖 DAG 或全项目最终验收；项目计划仍 active。
