# QPC Behavior 与 Shadow Ownership 设计

## 1. 目的和范围

本文是 `2026-08-21-xtr-v1-context-body-abi-design.md` 的窄范围修订，解决
Task 10C 开始前发现的两个问题：

- frozen QPC golden 中的 transport version、migration、endian swap、fence 和
  priority 没有硬件中立的 model owner；
- 原 Task 10C 计划错误地把 `context_backing` 视为不进入 payload，但固定驱动实际把
  `ctx_addr.iova >> 9` 写入 `SHADOW_PBA`。

本设计只增加 QPC behavior 值对象并修正 QPC shadow、signature、flow-control 的
ownership。它不实现 codec，不改 PCIe、host_mem、doorbell、SQE 或运行时 shadow
管理，也不增加当前固定驱动没有写入的 QPC 行为字段。

权威软件基线仍为固定驱动提交
`491faf2ba42627fffd4dd027607299c8bb591ec2`。固定 archive 中 `qp.c:1460-1467`
给出的投影是：

```text
SHADOW_PBA = xtqp->qp_ctx.ctx_addr.iova >> 9
SQ_CE_EN   = xtqp->sig_all
FC_EN      = 一个共享 flow-control bit
```

## 2. 已选架构

新增硬件中立的 `rdma_qpc_behavior` 值对象，由 `rdma_qpc_model` 独占持有。xtr_v1
codec 保持无状态，只把 model 的显式值投影到硬件字段。codec registry 中不保存可变
policy，也不为 xtr_v1 创建专用 QPC model 子类。

这个边界保证：

- sequence、builder 或更高层 policy 明确决定行为值；
- RC、UD、URC transport 选择不隐式覆盖行为值；
- 同一个硬件中立 model 可以由其他设备 codec 采用不同的投影规则；
- registry codec 可以安全复用，不因上一次 encode 留下配置状态。

## 3. `rdma_qpc_behavior` 契约

`rdma_qpc_behavior extends uvm_object`，包含：

| 字段 | model 类型/范围 | xtr_v1 投影 |
|---|---|---|
| `transport_version` | `int unsigned`，0..3 | `TVER[1:0]` |
| `migration_enable` | `bit` | `MIG` |
| `tx_endian_swap` | `bit` | `TX_ENDIAN_SWAP` |
| `rx_endian_swap` | `bit` | `RX_ENDIAN_SWAP` |
| `read_after_write_fence` | `bit` | `RA_FENCE` |
| `atomic_after_atomic_fence` | `bit` | `AA_FENCE` |
| `priority` | `int unsigned`，0..7 | `PRI[2:0]` |

构造默认值与固定驱动 create 路径一致：

```text
transport_version          = 0
migration_enable           = 0
tx_endian_swap             = 1
rx_endian_swap             = 1
read_after_write_fence     = 1
atomic_after_atomic_fence  = 1
priority                   = 0
```

默认值只是确定性的 model 初值，不是 transport policy。golden case 需要的 `tver=1`、
`mig=1` 或 `priority=5` 必须由 test/model builder 显式设置；codec 不根据 RC、UD 或 URC
自动补值。

该对象实现 UVM factory 注册、`do_copy()`、`validate()` 和 `describe()`。
`transport_version > 3` 或 `priority > 7` 返回 `RDMA_SC_INVALID_ARGUMENT`。

`rdma_qpc_model` 构造时创建非空 `behavior`，`do_copy()` 必须 deep-copy 它，
`validate()` 必须拒绝空对象并调用嵌套校验，`describe()` 必须包含 behavior 摘要。clone
之后修改 behavior 不得影响源 model。

## 4. QPC 字段 ownership 和投影

### 4.1 Context backing

`rdma_qpc_model.context_backing` 的公开语义保持为未移位的 byte IOVA，而不是预编码
PBA。model 校验 512B 对齐；xtr_v1 encode 写入：

```text
SHADOW_PBA = context_backing.value >> 9
```

decode 执行逆变换：

```text
context_backing.value = SHADOW_PBA << 9
```

因此 `context_backing` 是可序列化语义，必须参与 `serialized_equal()`。因为 model
要求低 9 bit 为零，round-trip 可以无损恢复 byte IOVA。原 Task 10C 计划中“忽略
`context_backing`，因为没有 payload bit”的要求被本文取代。

golden 中给出的 `shadow_pba` 是硬件字段值；测试 model 必须使用
`context_backing.value = shadow_pba << 9`，不得把已移位值冒充 byte IOVA。

### 4.2 Signature 和 flow control

`rdma_qpc_model.signature_enable` 映射到 `SQ_CE_EN`，并参与 decode 和
`serialized_equal()`。

硬件中立 model 继续保留 `tx_flow_control` 与 `rx_flow_control` 两个语义字段。xtr_v1
只有一个 `FC_EN`，所以 xtr_v1 encode 要求二者相等；不相等时返回
`RDMA_SC_INVALID_ARGUMENT`。这个限制属于 xtr_v1 profile，不放入通用 model 的
`validate()`，以免阻止未来支持非对称 flow-control 的设备。

encode 把共同值写入 `FC_EN`。decode 从 `FC_EN` 同时设置 TX 和 RX 字段，因此 xtr_v1
round-trip 后两者始终相同并参与 `serialized_equal()`。

### 4.3 Reserved 字段

当前 model 不增加 `CC_TYPE`、`RTO_CODE` 或 `LOAD_RQ_PI_TH`。固定 create 路径没有为
本轮提供它们的独立语义来源；xtr_v1 encode 保持这些位为零，decode 遇到非零值按
reserved-bit 损坏返回 `RDMA_SC_CODEC_ERROR`。以后只有在真实驱动或寄存器 ABI 明确
ownership 后，才通过新的窄范围设计扩展 model。

## 5. Codec 原子性和 mask

xtr_v1 QPC codec 使用独立的 512B allowed mask。它不得调用只描述 64B CMQ sparse
body 的 `body_mask()`。

encode 顺序固定为：

1. 检查 model 动态类型、transport variant 和 `model.validate()`；
2. 检查 xtr_v1 profile 约束，包括 TX/RX flow-control 相等；
3. 从全零 512B logical-qword builder 开始设置字段；
4. 用 QPC 专属 allowed mask 验证写集合和 reserved bits；
5. 每 qword big-endian serialization；
6. 全部成功后才替换 caller 的输出 image。

decode 先验证 image metadata、512B 长度、QPC allowed mask、reserved bits 和重复镜像
字段，成功后才发布完整 model。任何失败都不得向 caller 暴露半填 image 或半填 model。

错误分类沿用总设计：model/字段/profile 约束错误返回
`RDMA_SC_INVALID_ARGUMENT`；image 长度、metadata、reserved bit 或重复镜像损坏返回
`RDMA_SC_CODEC_ERROR`；未注册 variant 返回 `RDMA_SC_UNSUPPORTED_OPCODE`。

## 6. 测试和完成标准

### 6.1 Model 测试

- 验证 behavior 的驱动默认值、范围边界、非法版本和非法 priority；
- 验证 QPC clone 对 behavior 的 deep-copy 隔离；
- 验证空 behavior 被拒绝，`describe()` 包含 behavior 信息；
- 保留现有 QPC context backing 512B 对齐测试；
- 更新 request/context model 测试，使已有 model 显式持有有效 behavior。

### 6.2 Codec 测试

- RC、UD、URC 分别与 frozen 512B golden 逐 byte 相等；
- golden builder 显式设置 behavior，不由 transport 推导；
- RC/UD/URC 都验证 byte IOVA、`SHADOW_PBA` 和 `>> 9`/`<< 9` round-trip；
- 验证 `signature_enable -> SQ_CE_EN`；
- 验证相等的 TX/RX flow-control 编码一个 `FC_EN`，不相等时 encode 原子失败；
- 验证 behavior 与 context backing 都参加 `serialized_equal()`；
- 验证 behavior 边界值、未对齐 context backing、非法 reserved bit、错误 payload
  长度和 transport/extension 不匹配；
- 用专门断言证明 QPC codec 没有复用 64B command `body_mask()`。

### 6.3 验证环境

本前置任务只修改 model 和 model 单元测试。完成后恢复 Task 10C，由 Task 10C 增加
codec 与 golden 测试。每次提交在本地做静态检查，并在 `10.11.10.53` 使用 fresh
checkout、bash login shell 和 VCS 执行相关 core/unit 回归。完成标准是零 warning、零
error、零 fatal，且工作树没有未说明的生成文件。

## 7. 对原设计和计划的修订

本文只取代以下旧要求：

- QPC model 现在包含非空 `rdma_qpc_behavior`；
- `context_backing` 映射 `SHADOW_PBA` 并参加 serialized equality；
- xtr_v1 的单一 `FC_EN` 通过 encode-time equality 约束表达；
- Task 10C 必须使用 QPC 专属 512B allowed mask。

原 ABI 设计中的其他 QPC、CQC、MRT、SRQC、EQC、CMQ ownership 和 projection 契约
保持不变。本变更作为 Task 10A.1 完成后，Task 10C 才能继续。
