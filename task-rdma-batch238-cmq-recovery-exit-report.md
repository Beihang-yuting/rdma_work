# Batch238：CMQ recovery 失败出口收束

日期：2026-09-29；基线：`e04e7c5`；分支：`feature/rdma-structural-batch226`。
本批不合并、不推送；main 保持 `083e0d7`，已有缓存与外部依赖不改。

## 改动与取舍

`recover_submission_observed()` 原有 12 处结构对齐后的
“拒绝结果回填—解锁—返回”，现在共用一个失败尾段。不增加类、方法、公开接口、
实例字段或第二套 journal；仅新增一个调用期 `owner_rejected` 标志。

- reset release gate、locate、batch shape、item order 的四类早拒绝仍返回空数组，
  不提前创建 aligned results。
- 已对齐部分采用单次 `do/while (0)`，失败保留原状态创建位置后 `break`。
  owner 扫描先退出内层 foreach，再退出事务；首、中、末项拒绝均不可继续 CAS。
  不使用命名块 `disable`，避免取消其它 engine 或嵌套激活。
- CONFIRM、RETRY 成功各自解锁并返回，不进入失败回填。CONFIRM 不分配 attempt、
  不执行 I/O；RETRY 的 staging、最终 stale 检查、唯一 CAS、observer 登记、
  transport 调用、effect 折叠和逐项交付顺序不变。
- 失败出口不是 `status.ok()` 的反面：live mapping snapshot 的既有 OK/null
  拒绝仍按 admission helper 的布尔结果交付，不借结构重构更改历史状态契约。
- 三处 stale 的回填文本从固定字面量改读 `status.message`：非 virtual
  `journal_status()` 只调用 direct-new status 并原样保存 message，创建与出口
  之间没有 factory/adapter 回调或新的等待，故与原文本一致。

恢复方法 **375→361 行**，方法 tokens **2,161→1,982**；engine **13,816→13,807 行**，
生产净减 **9 行**（包含新增设计注释）。保留文件内 **212 个原方法声明**、
**31 个非 protected 声明**（30 个 engine 方法，含构造；1 个 observer 回调）
和全部实例字段。这只是重复失败收尾的收缩，不代表 CMQ 已达到最终规模目标。

## 对照测试与复审

新增独立 `rdma_cmq_recovery_exit_test`，只复用父类 fixture/断言，不运行父矩阵。
每例建立三个 retained item，连续拒绝两次，修复后提交一次 RETRY；12 种场景共
**36 次 recovery 调用**：未定位、result staging、stale+坏 action、坏 action、
profile 拒绝、首/中/末 owner 无 RETRY 权限、QUIESCED、attempt 耗尽、observer
staging 和 CONFIRM 非隔离生命周期。

拒绝阶段检查 aligned/current-attempt/recovery/observation、counter/journal/
preallocation/observer/fence 不变、scheduler 和 Host-memory 零 I/O；公开 fence
查询、连续调用及 10us watchdog 检查解锁。修复后仅允许一次 scheduler 提交和
一个新 attempt，累计 HOST_MEMORY_WRITTEN 证据不能降级。fixture 的 scheduler
返回 PRE_SUBMIT_REJECTED 操作错误，预期 orchestration 为 OK，不误称硬件发布成功。

旧版生产 `e04e7c5` 已先通过该专项；送测 hash 与固定 Git blob 一致，重构版沿用
相同测试字节。新增五项 Python 门禁检查共同尾段、早拒绝、owner 两层退出、stale
直接状态契约和最终 CAS/注册顺序。原 manifest 的三处重复尾段断言改为 `break`，
由新门禁约束其共同目标；未删除原认证、live admission 或 candidate staging 检查。

固定基线审计把 12 个失败出口展开、消去调用期 owner 标志与 RETRY 末尾显式
return，再对三处 stale 文本单独证明，整个 recovery 方法逐 token 一致；其它
**211 个方法正文**、类壳/字段和 **202 个其它既有 src/tests-unit SV 文件**不变。
从文件入口、owner/锁字段及调用边界复审，检查 aligned staging/reject、双图认证、
owner、reset proof/lifecycle、live authority、candidate、CAS 与 transport/effect
交付；另复核复用的 fixture、aligned/atomicity 断言和 package/manifest 注册。
目录契约扫描为 **204 SV 文件 / 5,379 方法 / 零 diagnostics**；不将该扫描及局部
语义复审冒充全目录注释语义、并发或最终架构验收。

## 验证状态

全部验证完成，各 wrapper 真实退出码为 0，最终送测输入哈希一致。

| 验证项 | 最终结果 |
| --- | --- |
| 旧版基线 / 重构版专项 | 各 1 PROCESS / 1 LOGICAL，36-call 完成标记齐全 |
| core | 107 PROCESS / 90 LOGICAL，107 份 pristine 报告；本批及既有十三组矩阵标记齐全 |
| CMQ | 28 PROCESS / 11 LOGICAL，28 份 pristine 报告 |
| integration / Host-memory / PCIe | 10 / 3 / 1，全通过 |
| 双环境 / 多 VF / 高流量 E2E | 各 1，全通过 |
| Python | 388/388，含新增五项结构门禁 |
| 驱动契约 | 203 tests、definitions、C oracle、1,088 项字段归属检查全通过 |
| 静态复审 | style（含新增文件暂存后）、lifecycle/profile/Phase-1A、固定基线/目录契约、diff 全通过 |

所有 suite 的 UVM WARNING/ERROR/FATAL 为零。三组 E2E 各保留 4 条既有编译告警
（2 FLWI、2 外部 net_packet SV-ANDNMD），其它 suite 编译告警为零。
core 增加一个独立专项，故 106/89→107/90，不把注册数增长称为旧矩阵覆盖扩大。
本批未修改外部依赖或原 CMQ process inventory；新增专项不调用父类 run_phase，
避免重复运行父矩阵。

所有 VCS 由 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 执行，
依赖固定为：

```text
HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem.audit.current
DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common
NET_PACKET_ROOT=/home/ubuntu/net_packet_latest
PCIE_WORK_ROOT=/home/ubuntu/workspace/pcie_work_audit.POaPmh
```

本机证据前缀 `/tmp/rdma_batch238_`：`baseline.log` 为未改生产的专项，
`focused.log` 为最终生产专项，完整回归分别是 `core.log`、`cmq.log`、
`integration.log`、`host_mem.log`、`pcie_work.log`、`driver_contract.log`、
`e2e.log`、`e2e_multivf.log`、`e2e_traffic.log`；真实退出码在 `group_*.log`。
`baseline_inputs.sha256` 和 `final_inputs.sha256` 固定两版送测输入，
`audit.py`/`audit.log` 保存等价及目录契约审计，`verify_logs.sh` 对最终报告计数、
矩阵完成标记、编译告警、wrapper 状态与哈希做联合检查，结果在
`verification_summary.log`，最终为 PASS。`python.log`、`style.log`、
`style_staged.log`、`lifecycle.log`、`profile.log` 和 `phase1a.log` 保存静态检查结果。

## 尚未关闭

本批只收束 CMQ recovery 的重复失败出口。observed submit/recovery/reset 整体
业务编排、CMQ 文件规模与 protected 兼容层、queue-data/resource/lifecycle 更广泛
结构、跨组件并发、SRQ 完整组合、SQD/SQE drain/flush、外部 ordering/error/
backpressure、Phase-1C F2 whole-plan 和最终 ownership 审计仍 OPEN；两个计划
继续保持 active。

下一轮候选的只读对照发现：首次 submit 的未 arm PRE 会撤销 journal，而 recovery
必须保留历史累计 evidence；真实 arm 下 UNOBSERVED 的 observation 策略也不同；
recovery 还要将本次 effect 折叠进原累计值。因此不能直接共用 submit classifier，
也不为缩短入口而加入大量 context 开关。后续先梳理 recovery 成功交付的业务阶段，
仅在确认规则确实相同后共享，不搬动唯一 owner。
