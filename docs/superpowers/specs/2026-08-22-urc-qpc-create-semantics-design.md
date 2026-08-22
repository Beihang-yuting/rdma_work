# URC QPC Create Semantics 设计

## 1. 目的和范围

本文是 `2026-08-21-xtr-v1-context-body-abi-design.md` 的窄范围修订，解决
Task 10C 开始前发现的 URC QPC model、frozen golden 与固定驱动 create
投影不一致的问题。

本设计只覆盖：

- URC QPC 创建/修改语义的硬件中立 model ownership；
- URC 内部队列 backing、depth、fetch 和 threshold 的明确单位；
- xtr_v1 create image 中 sequence mirror、队列地址和 canonical runtime-zero 字段；
- Task 9.5 遗漏字段和 `qpc_urc_boundary` 的窄范围重新冻结；
- Task 10C 的 encode、decode、serialized equality 和错误契约。

本设计不把任意 query/runtime 512B QPC snapshot 暴露为通用 model，不实现运行时
SRBSN 更新，不改变 RC/UD ownership，也不涉及 CMQ、doorbell、PCIe、host_mem 或
数据面 SQE/RQE。

权威软件基线保持为驱动提交
`491faf2ba42627fffd4dd027607299c8bb591ec2`，固定 archive 保持为
`/home/ubuntu/workspace/Desktop.zip`。

## 2. 已确认的缺口和根因

当前 `rdma_qpc_urc_ext` 只有一个 `rbsn`、`dbsn`、`rpsn`、`dpsn`，以及含义不明确的
`fetch_threshold` 和 `queue_threshold`。现有 `qpc_urc_boundary` 却把以下硬件字段冻结为
彼此独立的值：

- 五个 RBSN-family 字段；
- 三个 DBSN-family 字段；
- 两个 RPSN-family 字段和两个 DPSN-family 字段；
- 两个不同 fetch 字段；
- 两个不同 queue threshold 字段；
- 一个没有 model owner 的 RDSQ size。

该 golden 同时没有提供当前 model 校验所要求的非零 `remote_qpn`。因此它是硬件字段
坐标/宽度边界向量，不是当前硬件中立 model 可构造的合法语义向量。四个 sequence
标量无法无损生成或 decode 这些彼此独立的值。

固定驱动还证明 Task 9.5 漏掉了两个 create-path 字段：

- `XTRDMA_QPC_URC_RSQ_SIZE`，byte 24、logical qword bits 61:59；
- `XTRDMA_QPC_URC_NXT_RDSQ_FETCH_NUM`，byte 224、logical qword bits 21:16。

根因是 Task 9.5 的 field-boundary 目标与 Task 10C 的 semantic-round-trip 目标被合并到
同一个 URC payload golden。修复必须重新分离这两个目标，而不是向通用 model 添加每个
运行时硬件镜像。

## 3. 已选架构

URC QPC model 只表达创建/修改语义。硬件镜像由 codec 从唯一语义 owner 派生；只有
query/runtime snapshot codec 才能在未来引入独立运行时状态对象。

新增 `rdma_urc_queue_config extends uvm_object`：

```systemverilog
class rdma_urc_queue_config extends uvm_object;
  rdma_backing_addr_t rsq_backing;
  rdma_backing_addr_t rdsq_backing;
  rdma_backing_addr_t dsq_backing;
  int unsigned rsq_depth;
  int unsigned rdsq_depth;
  int unsigned rdsq_fetch_count;
  int unsigned dsq_fetch_count;
  int unsigned rq_sequence_threshold_entries;
  int unsigned sq_completion_threshold_entries;
endclass
```

`rdma_qpc_urc_ext` 的最终 ownership 是：

```systemverilog
class rdma_qpc_urc_ext extends rdma_qpc_transport_ext;
  bit [23:0] remote_qpn;
  bit [23:0] rbsn;
  bit [23:0] dbsn;
  bit [23:0] rpsn;
  bit [23:0] dpsn;
  rdma_urc_queue_config queues;
endclass
```

原来的三个 backing 和含义不明确的 `fetch_threshold`、`queue_threshold` 从 extension
移入或替换为上述 queue config 字段。constructor 通过 factory 创建非空 `queues`；
`do_copy()` deep-copy；`validate()` 拒绝空对象；`describe()` 同时显示 sequence 和
queue config 摘要。

### 3.1 通用 model 校验

通用 model 只校验硬件中立语义：

- `remote_qpn` 非零；
- RSQ、RDSQ、DSQ backing 都是 4KiB 对齐的未移位 byte address；
- RSQ/RDSQ depth 是非零 2 的幂；
- RQ/SQ threshold 为零，或是不小于 2 的 2 的幂 entry 数；
- RQ sequence threshold 不超过 common `rq_depth`；
- SQ completion threshold 不超过 common `sq_depth`。

fetch count 允许为零；通用 model 不施加 xtr_v1 的 6-bit 上限。通用 model 也不限制
depth/threshold 的 xtr_v1 code width，这些是 device codec profile 约束。

### 3.2 不属于 create model 的状态

以下字段是运行时状态，不获得 create model owner：

- `RX_SRBSN`；
- `TX_SRBSN`；
- `MAX_TX_SRBSN`。

它们在 canonical create image 中必须为零。后续若实现 query/runtime snapshot，必须使用
独立 runtime-state 类型，不得把这些字段重新塞回 `rdma_qpc_urc_ext`。

## 4. xtr_v1 投影

### 4.1 Sequence 和 remote QPN

`remote_qpn` 映射 `DST_QPN`。四类 sequence 使用以下唯一 mirror 关系：

| model owner | xtr_v1 fields |
|---|---|
| `rbsn` | `TX_RBSN`、`RX_RBSN` |
| `dbsn` | `TX_DBSN`、`RX_DBSN`、`RXED_DBSN` |
| `rpsn` | `CUR_TX_RPSN`、`TPE_RPSN_MAX` |
| `dpsn` | `CUR_TX_DPSN`、`TPE_DPSN_MAX` |

decode 先读取每组全部 mirror，只有一致时才把 canonical 值写入临时 model。任何组内不一致
返回 `RDMA_SC_CODEC_ERROR`，且 output model 保持 null。

### 4.2 Queue topology

- RSQ/RDSQ backing：验证 4KiB 对齐和 52-bit page-number profile 后右移 12；
- RSQ/RDSQ depth：精确编码 `log2(depth)`，code 必须适配 3 bit；
- DSQ current PBA：`dsq_backing.value >> 12`，写入跨 qword 的 high/low 字段；
- DSQ next PBA：`(dsq_backing.value >> 12) + 1`；
- RDSQ/DSQ fetch count：直接编码，必须适配 6 bit；
- threshold 为零时编码 code 0；非零时编码 `log2(entries)`，必须适配 4 bit。

decode 对这些变换执行精确逆映射。threshold code 0 canonicalize 为零；非零 code
恢复为 `1 << code` entries。DSQ next PBA 必须恰好等于 current PBA 加一，否则返回
`RDMA_SC_CODEC_ERROR`。encode 必须检查 page-number 加一不溢出 52 bit。

### 4.3 Create-image mask

URC QPC private allowed mask 只包含：

- common QPC create semantics；
- URC remote QPN 和四类 sequence mirror；
- URC queue topology、depth、fetch 和 threshold 字段。

`RX_SRBSN/TX_SRBSN/MAX_TX_SRBSN` 不在 create-image mask 中，因此 decode 中任何非零
值都会被 reserved-bit 检查拒绝。`CC_TYPE`、`RTO_CODE`、`LOAD_RQ_PI_TH` 继续保持现有
Task 10C 契约中的 zero/reserved 状态。

encode 仍使用 builder occupancy，要求 64 个 qword 的 occupancy 与 transport-specific
allowed mask 完全相等；值为零的已拥有字段仍必须显式 author。decode 使用 logical words
拒绝 mask 外任何非零 bit。

## 5. Task 9.5 定义补齐和 golden 重新冻结

### 5.1 Frozen definitions

在不改变固定驱动 commit 和 source bytes 的前提下，checker、SV definitions 和定义测试
增加：

| C source | SV definition | byte | LSB | width |
|---|---|---:|---:|---:|
| `XTRDMA_QPC_URC_RSQ_SIZE` | `XTR_V1_QPC_URC_RSQ_SIZE` | 24 | 59 | 3 |
| `XTRDMA_QPC_URC_NXT_RDSQ_FETCH_NUM` | `XTR_V1_QPC_URC_NXT_RDSQ_FETCH_NUM` | 224 | 16 | 6 |

checker 必须继续从固定 `qp.h` source bytes 独立解析坐标，并拒绝 source、reference table
或 SV constant 的任一漂移。

### 5.2 Canonical `qpc_urc_boundary`

case 名称保持 `qpc_urc_boundary`，但输入摘要改为 model semantic units。重新冻结的核心
输入为：

| semantic input | frozen value |
|---|---:|
| `remote_qpn` | `0x654321` |
| `rbsn` | `0xabcdef` |
| `dbsn` | `0x654321` |
| `rpsn` | `0x56789a` |
| `dpsn` | `0x456789` |
| RSQ page PBA | `0x123456789abcd` |
| RDSQ page PBA | `0x23456789abcde` |
| DSQ current page PBA | `0x3456789abcdef` |
| RSQ depth | `64` entries, code `6` |
| RDSQ depth | `64` entries, code `6` |
| RDSQ fetch count | `8` |
| DSQ fetch count | `8` |
| common SQ depth | `32768` entries, code `15` |
| common RQ depth | `16384` entries, code `14` |
| RQ sequence threshold | `2048` entries, code `11` |
| SQ completion threshold | `4096` entries, code `12` |
| common path MTU | `8192` bytes, code `5` |

模型中的 backing 输入分别是上述 page PBA 左移 12；`context_backing` 仍使用 frozen
shadow PBA 左移 9。common SQ/RQ backing 也继续把 frozen page PBA 左移 12 后交给 model。

新 payload 中：

- 同一 sequence owner 的所有 mirror 值一致；
- 三个 SRBSN runtime 字段为零；
- `DST_QPN` 使用非零 `remote_qpn`；
- RSQ/RDSQ size 和两个 fetch 字段都存在并来自明确 queue config；
- threshold 来自 entry-unit model 值，不是独立硬件 field boundary 值。

其他 common URC golden 输入继续显式设置，包括 behavior、traffic class、state、handles、
signature/flow control 和 address-vector 值。codec 不提供 transport default。

独立硬件字段的最大值、宽度、offset 和 mask 继续由 Python definitions checker 与
SystemVerilog definitions/mask tests覆盖；它们不再通过一个不可 round-trip 的 512B
semantic payload 覆盖。

## 6. Equality、错误和原子性

URC QPC `serialized_equal()` 比较：

- 全部 common QPC serialized semantics；
- `remote_qpn`；
- `rbsn/dbsn/rpsn/dpsn`；
- queue config 中所有 backing、depth、fetch 和 threshold 字段。

它不比较不存在于 create model 的 SRBSN runtime 状态。因为 decode 会拒绝这些位非零，
忽略它们不会产生不可见的成功 decode。

错误分类固定为：

- 通用 model 的 null、alignment、power-of-two、threshold topology 错误：
  `RDMA_SC_INVALID_ARGUMENT`；
- xtr_v1 encode 的 width、page-number、next-page overflow 或 profile 错误：
  `RDMA_SC_INVALID_ARGUMENT`；
- decode 的 metadata、length、reserved/runtime bit、mirror 或 next-page 关系损坏：
  `RDMA_SC_CODEC_ERROR`；
- registry 缺少 variant：`RDMA_SC_UNSUPPORTED_OPCODE`。

所有 encode/decode 路径继续使用临时 builder/model/image。只有全部校验成功后才替换 caller
output；任何失败保持 output null/未发布。

## 7. 测试和验收

### 7.1 Definitions 和 golden

- Python checker 从固定 driver source 重建两个新增字段；
- Python negative tests 对 source/SV constant/reference table 漂移保持非零退出；
- checker 逐 byte 重建新的 `qpc_urc_boundary`；
- SystemVerilog definitions test 校验两个新增字段的 byte/LSB/width/offset；
- mask tests覆盖新增字段，并证明三个 runtime SRBSN 字段不属于 URC create mask。

### 7.2 Model

- queue config factory/default、copy、describe 和 validate；
- URC extension clone 对 queue config deep-copy 隔离；
- null queue config、未对齐 backing、非法 depth、非法 threshold 和 threshold 超过 common
  SQ/RQ depth 的 exact status；
- request/context model 切换和 clone 保留全部 URC create semantics；
- 通用 model 不施加 xtr_v1 width 限制。

### 7.3 Codec

- URC encode 与新 frozen golden 逐 byte 相同；
- encode/decode/serialized-equal round-trip；
- 四组 sequence mirror 分别注入 corruption 并得到 exact codec error；
- 三个 SRBSN runtime 字段分别注入非零并得到 exact codec error；
- RSQ/RDSQ depth、fetch、threshold、PBA width 和 DSQ next-page corruption；
- 每个失败用预置 output 验证原子清空；
- RC/UD golden 和回归保持不变。

SystemVerilog compile/simulation 只在 `10.11.10.53` 运行，使用 fresh runner 和 bash login
环境。每项完成标准是进程退出 0，UVM warning/error/fatal 为 0/0/0。

## 8. 实施顺序和文档修订

Task 10C 恢复前增加两个独立 prerequisite：

1. 补齐 frozen definitions、独立 checker reference 和 canonical URC golden；
2. 引入 `rdma_urc_queue_config` 并迁移 context/request model tests。

两个 prerequisite 都必须按 TDD、独立提交和两阶段审查完成。随后修订
`2026-08-21-xtr-v1-context-body-abi-design.md` 及其实施计划中的 URC ownership、golden、
mask 和 replay order，再恢复原 Task 10C。

本文只取代父设计/计划中以下旧要求：

- URC extension 直接拥有三个 backing 和两个模糊 threshold；
- `qpc_urc_boundary` 可把同族 sequence/runtime mirror 设置为彼此独立值；
- Task 9.5 的 URC field map 已完整；
- Task 10C 可以在不补 prerequisite 的情况下直接实现 URC codec。

RC/UD、common PMTU、QPC behavior、context backing、signature/flow-control、private 512B
mask、registry key 和 atomic-output 契约保持不变。
