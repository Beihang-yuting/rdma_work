# Batch245：硬件镜像元数据值复制归一

日期：2026-09-30；基线：`9bcce51`；分支：`feature/rdma-structural-batch226`。
不合并、不推送；main 保持 `083e0d7`，保留既有缓存，不修改外部依赖。

## 改动与业务边界

将 8 个入口、9 处重复的十项 hardware-image 元数据赋值归入模型自身的
`rdma_hw_image::copy_metadata_noalloc(source, destination)`。字段顺序为 length、
alignment、endian、image_kind、hardware_version、function_generation、write_target_kind、
backing_target、hmc_target、bar_target。三个 target 是 packed 地址值，不是外部资源
capability；复制不产生或验证 authority。

共享操作是 static automatic void，仅执行赋值；调用方保证两端非空。没有新增
null/shape/status 策略、factory、clone/copy 回调、锁、字段、缓存或 owner。
它是新增的公开模型值操作，不声称“没有新增 API”；所有已有方法声明不变。

| 入口 | 留在原位的分配与队列策略 |
| --- | --- |
| image `do_copy` | super/cast/fatal；bytes→metadata→summary，允许自复制 |
| queue publish | typed factory；metadata 后清空、逐项复制两组队列 |
| queue poll | raw factory；metadata 后向工厂预填队列追加，不清空 |
| runtime image projection | raw factory；清空后逐项复制，status 保留 direct fallback |
| pending `do_copy` | direct new；metadata 后赋值 bytes/summary |
| CMQ direct image snapshot | 原 shape 校验、direct new、bytes→metadata→summary |
| CMQ checked image snapshot | factory 捕获原值→clone 回调→恢复源值→原 clone/value 校验 |
| CMQ completion raw CQE | direct new base image；原 canonical/target/ticket/generation 校验 |

保留非空 poll source alias 的历史风险，不擅自加入拒绝分支或改写追加方式。
runtime/publish 的 hostile factory source alias 仍会清空源队列；本批将该既有行为
写清并测试，而不是把结构重构扩展为兼容性修复。pending 自复制不保证子对象保值、
void `do_copy` 的非空前提以及 typed factory 错型的 FCTTYP 也同步明确。

八份生产文件含中文说明净减 **55 行**（28,342→28,287），代码/字符串 tokens
**138,984→138,429**。没有新增生产文件；这是重复值操作的集中维护，不是整体架构
已收敛，也不把新增测试/文档排除后称为全仓净减。

## 对照验证与复审

独立 `rdma_hw_image_copy_contract_test` 只调用旧入口，不调用新 helper、不复跑父
测试，也不覆盖被测生产方法。protected 入口通过 test-only subclass 透传。
复用现有错型对象、CMQ hostile clone 和精确 FCTTYP catcher，避免复制测试机制。

专项共 **153 次**被测调用：

- 8 入口 × 16 组成功值：十项 metadata、双 endian、四类 target、非零/满位地址、
  满位 version/generation；逐项核对两组 queue、结果隔离及完整 factory 创建名序列。
- 6 次 image null/错型 factory，含 publish 错型一次预期捕获的 FCTTYP。
- 4 次 status null/错型 factory：poll 返回 null+已生成 copy；runtime 保持 fallback。
- 6 个可空入口、6 种 hostile clone（正常/null/self/错型/改写源值/第三个等值对象）。
- model 自复制、runtime/publish factory source alias 各一次。

未对非空 poll 自别名执行 foreach 追加，以免原实现无界增长；未对要求非空的
`do_copy` 注入 null。此值专项不声称覆盖业务 admission、全部 malformed shape、
跨组件并发或外部 I/O；既有 CMQ/queue 和全链路 suite 继续承担相应回归。

四项 Python 门禁固定十项有序赋值、九个调用点、各入口 payload/clone 顺序和专项
注册。六项只在内存中的破坏注入（漏 generation、反向写源、增加分配、poll 误清空、
源恢复反向、遗漏 publish 委托）全部被拒绝。

完整源码对照不是仅比较赋值块：展开九处 helper 后，八个变更方法的全部代码及
诊断字符串 token 与固定旧版一致；**462 个其它方法正文、470 个已有声明、176 个
public 声明及八份文件的类壳/字段不变**。多类文件按名字+出现序号保留全部方法，
不让重名构造/copy 覆盖扫描结果。**202 个其它既有 SV 文件**字节不变，package/
core manifest 各只注册一个新专项。目录契约扫描：**211 SV / 5,451 方法 / 零诊断**。

从八个文件入口复核职责、依赖与生命周期，复审完整被改方法、调用窗口、上游
null/分配/shape 检查、payload 顺序与相关 clone fixture；全面更新 image 模型说明。
目录契约扫描不等于全目录注释语义、所有并发和最终 ownership 审计完成。

## 验证状态

全部最终选定 suite 的 wrapper 真实退出码均为 0。

| 验证项 | 最终结果 |
| --- | --- |
| 旧生产专项 / 重构版 core 专项 / 注释终版专项 | 各完成 153 次复制调用，完成标记齐全 |
| core | 114 PROCESS / 97 LOGICAL，114 份 pristine；本批及既有二十组矩阵标记齐全 |
| CMQ | 28 PROCESS / 11 LOGICAL，28 份 pristine |
| integration / Host-memory / PCIe | 10 / 3 / 1，全通过 |
| 双环境 / 多 VF / 高流量 E2E | 各 1，全通过 |
| Python | 初轮及注释终版均 417/417，含四项新门禁；六项静态破坏均被拒绝 |
| 驱动契约 | 203 tests、definitions、C oracle、1,088 项字段归属全通过 |
| 静态复审 | style（含暂存后）、lifecycle/profile/Phase-1A、完整方法/目录契约、diff 全通过 |

所有仿真的 UVM WARNING/ERROR/FATAL 为零；专项中的一次预期 FCTTYP 由精确
catcher 捕获并断言次数，不将其作为未处理 fatal。三组 E2E 各有 4 条既有编译告警：
2 FLWI、2 外部 net_packet SV-ANDNMD；其它 suite 无编译告警。
core 的 113/96→114/97 仅是新增专项注册，不表示既有组合矩阵维度扩大。

所有 VCS 经 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 执行，
固定外部依赖只消费、不修改：

```text
HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem.audit.current
DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common
NET_PACKET_ROOT=/home/ubuntu/net_packet_latest
PCIE_WORK_ROOT=/home/ubuntu/workspace/pcie_work_audit.POaPmh
```

证据前缀 `/tmp/rdma_batch245_`。`baseline_inputs.sha256` 固定旧生产与最终专项；
`sent_inputs.sha256` 固定首轮完整回归输入，`sent_tokens.json` 保存代码/字符串 token
哈希。送测后只修正两份文件的 null/self-copy/FCTTYP 注释，全部 code/string tokens
一致（`reviewed_tokens.log`）；`reviewed_inputs.sha256` 固定最终生产/专项输入，
注释终版另运行 focused。不能把首轮回归与注释终版描述为全文件字节相同。

固定旧版对照使用保留的临时 detached 工作树
`/tmp/rdma_batch245_baseline.odRAoY/tree`，只加入最终专项及两个注册项。
`audit.py`/`audit.log` 保存完整展开与目录扫描，`negative.py`/`negative.log` 保存
破坏拒绝检查。最终有效仿真日志为 `baseline.log`、`core.log`、`cmq.log`、
`integration.log`、`host_mem.log`、`pcie_work.log`、`e2e.log`、`e2e_multivf.log`、
`e2e_traffic.log`、`reviewed.log` 和 `driver_contract.log`；五个 `group_*.log`
保存全部 wrapper 退出码。`verify_logs.sh`/`verification_summary.log` 检查计数、
矩阵标记、告警、静态结果、退出码及最终输入；`final_inputs.sha256` 固定交付文件。

首次旧版编译因测试误用 `uvm_factory::set` 失败；改为项目现用的 coreservice 接口。
第二次旧版执行暴露两个 trace oracle 错误：漏计 publish 探针构造 planner，误认为
base UVM clone 会调用 factory。修正测试后重新在固定 `9bcce51` 执行并通过；未为
迁就测试改变生产行为。两次失败日志保留为 `baseline_compile_attempt1.log` 与
`baseline_trace_attempt2.log`，不计入最终通过证据。

## 尚未关闭

CMQ submit/recovery/reset 编排与 protected 兼容层、queue-data/resource/lifecycle
整体结构、跨组件并发、SRQ 完整组合、SQD/SQE drain/flush、外部
ordering/error/backpressure、Phase-1C F2 whole-plan 和最终 ownership 审计仍开放。
两个重构计划保持 active；后续仍以业务事务编排的可读性为主，不继续拆薄 facade。
