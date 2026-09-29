# Batch230：状态值操作归入公共类型

日期：2026-09-29。基线：`b4d81b0`。继续在
`feature/rdma-structural-batch226` 实现，保留 main 与原有缓存，不合并、不推送。

## 结果与边界

把重复的诊断字段操作归入已有 `rdma_status` 类型，不新增组件、注册、owner 或转发壳。
两个公共 static automatic 方法分别负责完整字段复制与 code/message 原位初始化：

- `copy_fields_noalloc(source, destination)`：复制全部 13 个诊断字段，不重新分类；
  任一对象为空返回 0，自复制成功且值不变，不调用虚拟 copy/clone。
- `set_fields_noalloc(destination, code, message)`：设置 code/category/severity/message，
  清零其余诊断；空对象返回 0，不分配，不修改对象身份/名称。

移除 queue-data projector 的两个 helper 与 runtime projector 的一个 setter；
runtime/engine 和测试直接调用 types。runtime 状态构造、状态快照复制和
`make_direct` 复用公共实现。方法调用点的执行顺序、失败出口和 factory 窗口不变。

分配/准入策略刻意不统一：

- runtime 仍先 raw factory 创建 `runtime_status`，null/错型直接
  new `runtime_status_fallback`，始终保留原 code/message。
- queue-data 仍创建 `queue_data_engine_status`，null/错型返回 null，不隐藏 fallback。
- `rdma_status::make` 保留 typed-create 及直接赋值；不能因 nullable setter 而把
  原先不支持的 factory null 改成静默返回。其正文与基线不变。
- 构造函数、UVM `do_copy`、`ok`、分类和字符串诊断正文不变。
- doorbell legacy 的状态复制带额外枚举合法性检查，本轮不迁移 scheduler；
  不把普通字段复制当作业务准入或 MMIO 成功证明。

同步复审并修正 `rdma_status` 全部方法注释，删除原有与实现不符的“未 configure
返回 INVALID_STATE”“ok 不读取成员”“do_copy 会 clone 嵌套对象”等模板说明。

## 实际规模

| 文件 | 基线 | 当前 |
| --- | --- | --- |
| rdma_status | 233 行 / 8 methods | 280 行 / 10 methods |
| queue-data projector | 889 行 / 25 methods | 831 行 / 23 methods |
| runtime projector | 884 行 / 21 methods | 830 行 / 20 methods |
| queue runtime | 3,814 行 / 74 methods | 不变 |
| queue-data engine | 9,929 行 / 139 methods | 不变 |

五个生产文件合计净减 **65 行、1 个方法**；不是只将行数迁入新文件。
调用者只改变状态 helper 的限定名称，runtime 的 58 个公开方法、engine 的 27 个
公开方法及全部实例字段/owner 不变。projector 内部值 API 的旧 helper 名移除，
仓库调用点已迁移；不声称这三个内部静态符号保持源码兼容。

## 复审与验证设计

`/tmp/rdma_batch230_audit.py` 固定对照 `b4d81b0`：

- 264 个保留方法在精确还原调用限定或展开三个字段 helper 调用后 token 等价；
  只额外规范化 category_for 限定与相同 ternary 条件的括号，保留字符串。
- 三个旧 helper 对照两个新类型方法，字段顺序、nullable 判断和返回语义一致。
- 五个类壳的字段、继承、注册等 token 不变，没有新增 mutable state 或 owner。
- src/tests-unit 全部 200 个 SV 文件、5,328 methods 中文三段契约扫描无 diagnostics。

上下文复审覆盖 status 全文、两个 projector 的值/创建/输出边界，以及所有改名调用
的 owner/锁/noalloc 窗口。业务方法全量 token 对照复用基线证据；全目录扫描是词法
门禁，不冒充全项目人工语义或最终可读性验收。

复用既有 runtime 测试，不新增 UVM test/注册项：17 个错误码加一个未知编码，
各验证原位更新、direct、typed、runtime 正常/null/错型、data 正常/null/错型，
共 162 cases。所有诊断字段采用显式独立断言，工厂先预填旧证据；检查对象名、原位
身份与分配次数。另在 runtime status factory 回调中嵌套创建不同 code/message 的
状态，确认 automatic 局部值隔离。

既有 post 测试继续验证 null、自复制、category/code 不匹配时原样复制，以及
hostile clone/do_copy 计数为零。新增五项 Python 门禁约束完整字段、单向依赖、
无转发壳、不同分配策略和动态矩阵入口；旧 projector/consumer/device 门禁同步改名。

## 验证状态

首轮专项之后仅修订三处测试长行，重新冻结源码并完成最终专项；所有最终 VCS 均
通过项目 wrapper 在 `ubuntu@10.11.10.53` 登录 bash 执行。专项及完整回归均通过，
所有 wrapper 返回 0。`/tmp/rdma_batch230_verify_logs.sh` 核对计数、162/24 新旧矩阵、
既有 53/126/30-case 恢复矩阵、告警、Python/驱动、wrapper 退出码及输入 hashes；
统一证据为 `/tmp/rdma_batch230_verification_summary.log`。
SV/构建/脚本输入记录为 `/tmp/rdma_batch230_inputs.sha256`，送测后只修改文档。

| 验证 | 结果 | 日志（`/tmp/`） |
| --- | --- | --- |
| runtime projector 专项 | 162-case 状态、24-case factory、对象图与两类嵌套回调通过 | `rdma_batch230_focused.log` |
| core | 103/103 PROCESS、86/86 LOGICAL、103 pristine | `rdma_batch230_core.log` |
| CMQ gate | 28/28 PROCESS、11/11 LOGICAL、28 pristine | `rdma_batch230_cmq.log` |
| integration | 10/10 pristine | `rdma_batch230_integration.log` |
| Host-memory / PCIe | 3/3、1/1 pristine | `rdma_batch230_host_mem.log` / `rdma_batch230_pcie_work.log` |
| E2E 双环境 / 多 VF / 高流量 | 各 1 pristine | `rdma_batch230_e2e.log` / `rdma_batch230_e2e_multivf.log` / `rdma_batch230_e2e_traffic.log` |
| 驱动归档 / oracle / 字段归属 | 203 自测、definitions、C oracle、字段归属通过 | `rdma_batch230_driver_contract.log` |
| Python | 346/346 通过 | `rdma_batch230_python.log` |
| token / 注释门禁 | 264 保留方法等价、200 files / 5,328 methods / 0 diagnostics | `rdma_batch230_audit.log` |
| style / diff / lifecycle / profile / Phase-1A | 通过 | `rdma_batch230_style.log`（空）及终端记录 |

全部套件 UVM WARNING/ERROR/FATAL 均为 0。三项 E2E 各保留 4 条基线编译告警：
2 条 net adapter FLWI、2 条外部 net_packet SV-ANDNMD；其它套件编译告警为 0。
外部依赖未改，路径沿用 Batch229 固定版本：

```text
HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem.audit.current
DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common
NET_PACKET_ROOT=/home/ubuntu/net_packet_latest
PCIE_WORK_ROOT=/home/ubuntu/workspace/pcie_work_audit.POaPmh
```

## 尚未关闭

producer/resize 完整业务编排、manager publication 后更新、runtime snapshot/commit
组合、跨 owner 原子性、跨队列并发、完整 SRQ 生命周期、legacy/external ordering/
error、Phase-1C F2、其它 epoch 饱和策略、包 DAG、全项目可读性最终验收仍 OPEN。
SQD/SQE 仍 unsupported，dpu_common 唯一 authority 与外部依赖不变。
