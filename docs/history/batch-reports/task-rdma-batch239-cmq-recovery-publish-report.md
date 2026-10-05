# Batch239：CMQ RETRY 持锁发布阶段

日期：2026-09-29；基线：`1d577d3`；分支：`feature/rdma-structural-batch226`。
本批不合并、不推送；main 保持 `083e0d7`，既有缓存和外部依赖不修改。

## 改动与取舍

将 recovery 的唯一 attempt 提交、同步 transport、累计 evidence 折叠及逐项
结果交付整理为同类 protected task `publish_recovery_retry_locked()`。
公共 `recover_submission_observed()` 保留 locate/对齐、双图/owner 认证、
CONFIRM、RETRY 准入与 staging、最终 stale 重验、统一拒绝出口及锁/status 交付。

```text
RETRY 准入与 staging → 最终 stale 重验 → publish_recovery_retry_locked
                                      ├─ attempt / pending / observer 登记
                                      ├─ transport 与真实 arm 回调
                                      └─ evidence 折叠与逐项结果
                    → orchestration OK → 解锁
```

阶段只借用原 record/preallocated、调用期 recovery_stage 和已对齐的 results
对象；不替换结果数组、不新建 owner、账本、锁、类或公开接口。十二个局部变量
随业务逻辑移入阶段，不升级为实例字段。整个阶段仍在原 engine_lock 内同步完成，
没有新增等待、factory/adapter 回调或锁窗口。

公共 recovery 方法 **361→227 行**，新阶段 **146 行**；engine **13,807→13,837 行**，
生产净增 **30 行**，受影响方法 tokens **1,982→2,024**。这是业务入口可读性整理，
不是总体代码收缩；原 **212 个方法声明**、**31 个非 protected 声明**及实例字段
不变（31 包含 30 个 engine 方法和 1 个 observer 回调），仅新增一个 protected task。

保留以下不能与首次 submit 合并的恢复策略：

- CAS 在任何 transport 调用之前完成，operation 失败不回滚已提交的 attempt。
- 未 arm 的 PRE 保留 journal/fence 及历史累计值，不走首次 submit 的 PRE rollback。
- arm 后从回调更新过的 record 读取累计 evidence，未 arm 则使用发布前 prior 值。
- arm + UNOBSERVED 保留原 attempt/observation 策略；无真实 arm 的 MMIO 自报
  降级为 UNOBSERVED 并禁止重试，不能仅根据返回 effect 授权。
- classifier 的逐项降级沿原顺序继续传播，最终 orchestration OK 与 operation
  status 分开；失败 admission 仍回到 Batch238 的唯一拒绝出口。

## 对照测试与复审

新增独立 `rdma_cmq_recovery_publish_test`：四种可恢复历史累计值 × 两种真实 arm
× 十二类 scheduler 返回，共 **96 个三项 batch 场景**。十二类为七种合法 effect、
null envelope、null status、spare effect、X effect 和 Z effect；合法 operation
交替使用 OK/TIMEOUT，验证 operation 错误不改变 authentic arm 的解释。

scheduler 观察器在原同步回调之前检查：唯一 attempt 已推进、preallocation 与
逐项 pending/status 已初始化、observer 已登记。随后使用原 observer 消费逻辑。
公开 recovery 返回后检查逐项状态/诊断、累计/本次 effect、独立 status 对象、
owner admission attempt、deadline、fence、token/preallocation/capability 计数；
每例独立 teardown，10us watchdog 防锁泄漏，不调用父类 run_phase。
预期计算不调用 DUT 的 decode/classify/fold helper。

初版测试将 scheduler 的 null envelope/status 误按 engine decoder 的内部边界
预期，两个旧版运行各有 48 条逐项诊断错误。读取真实 transport 后确认其先修复
null 返回：operation 文案来自 facade，engine 接收的是有效的非空 status。
仅修正测试预期，在 detached `1d577d3` 工作树重新验证为零告警/错误；生产未为
测试调整。最终专项字节与该修订基线一致，旧日志保留但不作为通过证据。

新增五项 Python 门禁固定最终 stale→阶段→OK/解锁顺序、非拥有参数与锁边界、
CAS/I/O/交付次序、恢复独立策略和矩阵注册。Batch238 的门禁沿新阶段追踪 CAS，
没有删除原 owner、stale 或“CAS 在 I/O 前”约束。

固定基线审计将唯一阶段调用展开，显式核对十二个局部声明的迁移后，整个 recovery
方法逐 token 相同；另 **211 个方法正文**、类壳/字段和 **203 个其它既有 SV 文件**
不变。从文件入口与所有权字段开始复核 recovery 调用链、transport facade、
observer arm 后证据、分类/逐项交付和测试 fixture/注册边界。目录契约扫描为
**205 SV 文件 / 5,385 方法 / 零 diagnostics**；不将该扫描及局部语义复审当作
全目录注释语义、并发或最终架构验收。

## 验证状态

全部验证完成。各有效 wrapper 真实退出码为 0，最终送测输入哈希一致。

| 验证项 | 最终结果 |
| --- | --- |
| 修订旧版 / 重构版专项 | 各 1 PROCESS / 1 LOGICAL，96-case 完成标记齐全 |
| core | 108 PROCESS / 91 LOGICAL，108 份 pristine 报告；本批及既有十四组矩阵标记齐全 |
| CMQ | 28 PROCESS / 11 LOGICAL，28 份 pristine 报告 |
| integration / Host-memory / PCIe | 10 / 3 / 1，全通过 |
| 双环境 / 多 VF / 高流量 E2E | 各 1，全通过 |
| Python | 393/393，含新增五项阶段门禁 |
| 驱动契约 | 203 tests、definitions、C oracle、1,088 项字段归属检查全通过 |
| 静态复审 | style（含新增文件暂存后）、lifecycle/profile/Phase-1A、固定基线/目录契约、diff 全通过 |

所有最终 suite 的 UVM WARNING/ERROR/FATAL 为零。三组 E2E 各保留 4 条既有
编译告警（2 FLWI、2 外部 net_packet SV-ANDNMD），其它 suite 编译告警为零。
core 因新增独立专项从 107/90→108/91，不把注册增长称为旧矩阵覆盖扩大。

所有 VCS 均通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 执行，
固定依赖路径如下；未修改依赖仓库：

```text
HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem.audit.current
DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common
NET_PACKET_ROOT=/home/ubuntu/net_packet_latest
PCIE_WORK_ROOT=/home/ubuntu/workspace/pcie_work_audit.POaPmh
```

本机证据前缀 `/tmp/rdma_batch239_`。`baseline.log`、`baseline_final.log` 是上述
错误测试预期的旧版运行；**有效旧版证据为 `baseline_fixed.log`**，来源隔离工作树
`/tmp/rdma_batch239_baseline.i1KGbM`（已核对只含本批临时测试/注册改动后清理；
可由 `1d577d3` 加本批测试及注册恢复，日志保留）。其源码/测试哈希在
`baseline_fixed_inputs.sha256`，重构后送测哈希在 `final_inputs.sha256`。
重构版专项及完整套件：`focused.log`、`core.log`、`cmq.log`、`integration.log`、
`host_mem.log`、`pcie_work.log`、`driver_contract.log`、`e2e.log`、`e2e_multivf.log`、
`e2e_traffic.log`；对应真实退出码在 `group_*.log`。`audit.py`/`audit.log` 为固定
基线及目录契约审计；`verify_logs.sh` 联合核验报告计数、矩阵标记、编译告警、
wrapper 状态和哈希，`verification_summary.log` 最终为 PASS。
`python.log` 保存 393 项 Python 结果；`style.log`、`style_staged.log`、
`lifecycle.log`、`profile.log` 和 `phase1a.log` 保存其它静态检查结果。

## 尚未关闭

本批只完成 RETRY 发布阶段的职责整理，不关闭 CMQ 整体规模、submit/recovery/reset
整体编排、protected 兼容层、更广泛 queue-data/resource/lifecycle 结构、跨组件
并发、SRQ 完整组合、SQD/SQE drain/flush、外部 ordering/error/backpressure、
Phase-1C F2 whole-plan 和最终 ownership 审计。两个重构计划继续保持 active。
