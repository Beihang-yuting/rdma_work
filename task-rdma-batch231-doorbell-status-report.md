# Batch231：门铃状态字段复用与 legacy 边界保留

日期：2026-09-29。基线：`dad8d20`。继续在
`feature/rdma-structural-batch226` 实现，保留 main 与原有缓存，不合并、不推送。

## 改动结果

上一批把状态值操作放到 `rdma_status`；本批继续收缩门铃的相同实现，不增加生产
组件、实例状态或转发壳：

- 删除 envelope 和 scheduler 中各一份 `set_status_fields`。
- 删除 scheduler 的普通 `copy_status_fields`。
- 普通调用点直接使用 `rdma_status::set_fields_noalloc/copy_fields_noalloc`。
- envelope 的 legacy `copy_status_fields` 不是普通转发壳：保留 null、category/
  code/source_engine 未知位及上界门禁，校验通过后才交给公共字段复制。

`rdma_doorbell_scheduler.sv` 从 1,690 行/47 methods 降为 1,606 行/44 methods，
生产净减 **84 行、3 个方法**。文件中的六个类、全部实例字段及 15 个 public 方法
声明不变；scheduler 类自身 32→30 methods，envelope 类 7→6 methods。

## 明确保留的业务契约

普通 adapter 状态捕获只传输完整诊断，不增加 legacy 枚举校验或 category/code 配对
规则；legacy 校验不检查 severity，不规范化合法但不匹配的 category/code。
未知位门禁仍保留，但现有枚举存储是二态 bit，不能宣称本矩阵注入过 X/Z。

三个直接构造名 `doorbell_submission_initial_status`、`doorbell_direct_status`、
`legacy_doorbell_status` 不变；外部捕获的 raw factory 次数、名称、null/错型
fallback 与 source=null 时复用候选 status 的处理顺序也不变。没有将其替换成命名
不同的 `rdma_status::make_direct`。

submission_effect 高水位、dependency_count、observer、Function identity 锁、deadline
预算、Host-memory→barrier→MMIO 顺序和 reset epoch 门禁均不变。状态复制不被用于
推断副作用或授予恢复权限。

同步纠正旧注释：pre-submit 捕获在 result=null 时直接返回、slot=null 时直接补建；
外部捕获只有 raw null/错型才直接构造 fallback，source=null 则复用 raw candidate。
这两处是注释修正，不是新增生产分支。

## 复审与静态证据

`/tmp/rdma_batch231_audit.py` 固定对照 `dad8d20`：

- 删除的三个 helper 正文分别与已有 types setter/copy 等价。
- 44 个保留方法仅还原调用限定或展开 legacy 字段复制后，含诊断字符串的 token 一致。
- 六个类壳、类外 enum 与 15 个 public 声明不变；types、core/test package 和 core
  回归清单未改，无新增注册项或包依赖。
- src/tests-unit 全部 200 个 SV 文件、5,328 methods 文件头/逐函数中文三段契约
  扫描零 diagnostics；生产删三个方法，既有测试增三个辅助方法。

上下文复审覆盖整个 scheduler 文件的值图、legacy 投影、状态捕获、校验、锁、
deadline、I/O 和公共入口，以及完整 scheduler test 的 fixture、故障注入、并发和
恢复尾段。未改业务正文以固定基线 token 对照复用既有证据；全目录词法扫描不代替
全项目人工语义审计或最终可读性验收。

## 新增验证

扩展既有 `rdma_doorbell_scheduler_test`，不新增测试组件：

- category 全部 16 编码、code 全部 32 编码、source_engine 全部 16 编码、severity
  全部 4 编码；每个坐标分别在 status factory 返回 null/错型模式下投影，共 136 cases。
  验证合法字段原样复制，非法字段返回 INVALID_STATE，13 个诊断字段完整重置；
  envelope/direct/legacy 创建名、零 factory/clone 调用、源值和 effect 不变。
- DMA barrier、MMIO barrier、MMIO write 三个真实提交窗口，各注入合法不匹配诊断、
  非法 category、非法 code、非法 engine，共 12 cases。验证 observed 捕获完整原始
  诊断而不套用 legacy 门禁；随后 legacy 拒绝不得修改原 observed status/effect。
- 原有 Host-memory 写后与 MMIO 后 factory null/错型、deadline/锁并发、reset epoch、
  同 Function 恢复、null/malformed legacy 等测试继续运行。

共 148-case 新矩阵，测试逐字段核对初始化结果，不调用生产 setter/copy 构造预期；
category 预期沿用未修改的 `category_for`，不将其称为独立分类 oracle。
扩展三个 Python 门禁约束无重复 helper、legacy 的准确完整拒绝逻辑和矩阵入口；
全部 Python 自测 349/349 通过。

## 验证状态

首轮 148-case 专项之后仅修正两处状态捕获注释，代码 token 不变。冻结最终源码后，
通过项目 wrapper 在 `ubuntu@10.11.10.53` 登录 bash 重新运行终版专项及完整回归。
终版专项及完整回归全部通过，所有 wrapper 返回 0。
`/tmp/rdma_batch231_verify_logs.sh` 核对各套件计数、新增 148-case 矩阵、既有
162/24 与 53/126/30-case 矩阵、编译告警、Python/驱动、wrapper 退出码及输入
hashes；统一证据为 `/tmp/rdma_batch231_verification_summary.log`。
SV/构建/脚本输入记录为 `/tmp/rdma_batch231_inputs.sha256`，送测后只修改文档，
最终复核 hashes 全部一致。

| 验证 | 结果 | 日志（`/tmp/`） |
| --- | --- | --- |
| 终版门铃专项 | 148-case 新矩阵及既有契约通过，1 PROCESS / 1 LOGICAL | `rdma_batch231_focused_final.log` |
| core | 103/103 PROCESS、86/86 LOGICAL、103 pristine | `rdma_batch231_core.log` |
| CMQ gate | 28/28 PROCESS、11/11 LOGICAL、28 pristine | `rdma_batch231_cmq.log` |
| integration | 10/10 pristine | `rdma_batch231_integration.log` |
| Host-memory / PCIe | 3/3、1/1 pristine | `rdma_batch231_host_mem.log` / `rdma_batch231_pcie_work.log` |
| E2E 双环境 / 多 VF / 高流量 | 各 1 pristine | `rdma_batch231_e2e.log` / `rdma_batch231_e2e_multivf.log` / `rdma_batch231_e2e_traffic.log` |
| 驱动归档 / oracle / 字段归属 | 203 自测、definitions、C oracle、字段归属通过 | `rdma_batch231_driver_contract.log` |
| Python | 349/349 通过 | `rdma_batch231_python.log` |
| token / 注释门禁 | 44 保留方法等价、200 files / 5,328 methods / 0 diagnostics | `rdma_batch231_audit.log` |
| style / diff / lifecycle / profile / Phase-1A | 通过 | `rdma_batch231_style.log`（空）及终端记录 |

全部套件的 UVM WARNING/ERROR/FATAL 均为 0。三项 E2E 各保留 4 条基线编译
告警：2 条 net adapter FLWI、2 条外部 net_packet SV-ANDNMD；其它套件编译
告警为 0。驱动字段归属结果为 666 个执行检查、422 个静态检查，共 1,088 项。
外部依赖未改，沿用固定路径：

```text
HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem.audit.current
DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common
NET_PACKET_ROOT=/home/ubuntu/net_packet_latest
PCIE_WORK_ROOT=/home/ubuntu/workspace/pcie_work_audit.POaPmh
```

## 尚未关闭

detached doorbell plan、producer/resize 完整业务编排、manager publication 后更新、
runtime snapshot/commit 组合、跨 owner 原子性、跨队列并发、完整 SRQ 生命周期、
legacy/external ordering/error、Phase-1C F2、其它 epoch 饱和策略、包 DAG 与全项目
可读性最终验收仍 OPEN。SQD/SQE 仍 unsupported；外部依赖及 dpu_common 唯一 authority 不变。
