# RDMA 引擎契约优先渐进重构设计

> 状态：总体路线已获批准；本文档随已批准的分阶段实现同步，当前冻结 Task 9 CMQ
> observed execution、journal digest 与 recovery value 契约。
> 日期：2026-09-11
> 首批范围：CMQ 提交证据、opcode 能力契约和 `rdma_cmq_engine` 内部分层。
> 后续范围：`queue_data_engine`、`queue_runtime`、`resource_manager`、
> `control_plane` 和 QP/queue lifecycle executor 分别建立独立规格与计划。

## 1. 决策摘要

本项目采用“契约证据先行、保持兼容 facade、逐层抽取”的重构路线。
不进行大爆炸重写，也不长期维护两套并行引擎。

所有核心引擎遵循同一组边界原则：

1. 先用真实驱动字段、方向和读写位置冻结外部契约，再修功能或移动代码。
2. 一个可变状态域只有一个 owner；抽出的协作者不得建立第二套状态或第二把锁。
3. 副作用证据由执行阶段直接产生，并与本次调用绑定；不得根据最终错误码反推。
4. 原 engine 保留为兼容 facade/coordinator，调用方在分阶段迁移期间不感知内部拆分。
5. 功能修复、结构抽取和无行为排版整理分开提交、分开验证。
6. “文件更小”是结果，不是验收条件；职责、依赖、所有权和测试边界才是验收条件。
7. 原始驱动数据结构是 wire ABI 权威；重构不得改变任何已支持结构的尺寸、偏移、
   端序、overlay 判别或线上字节。

CMQ 是第一批落地对象。其他大单体复用上述方法，但不与 CMQ 放进同一个实现计划，
避免同时改变多个状态机后无法定位回归来源。

## 2. 背景与已确认事实

### 2.1 当前主要大单体

当前核心目录中需要分阶段治理的对象包括：

| 对象 | 当前主要职责混合 |
| --- | --- |
| `rdma_cmq_engine` | ring、ticket/slot ledger、快照图校验、Host-memory/MMIO、completion、timeout/reset |
| `rdma_queue_data_engine` | attachment、SQ/RQ posting、CQ/CEQ/AEQ 发布与消费、resize、recovery、doorbell |
| `rdma_queue_runtime` | cursor、slot ledger、producer/consumer reservation、锁、recovery evidence、深拷贝 |
| `rdma_resource_manager` | ID 分配、registry、值投影、资源状态、QP/queue recovery journal、释放 |
| `rdma_control_plane` | Function 串行化、PD/MR/queue/QP 工作流、补偿与统一恢复 |
| `rdma_qp_lifecycle_executor` | backing 规划、QPC 构造、CMQ 命令、create/modify/destroy/recovery |

SQ、RQ、CQ 和 EQ facade 本身很薄。AEQ/CEQ 的复杂逻辑主要位于
`rdma_queue_data_engine`；CQC 是 context/codec/lifecycle 契约，不应被描述成独立 engine。

### 2.2 真实驱动绑定的价值和边界

`hw/rdma/source_manifest.txt`、`tools/check_rdma_profile_names.py` 和 golden vector
能够锁定驱动文件 hash、宏值、位宽、offset、部分字节图和硬件错误码。这套机制继续保留。

现有能力也有明确边界：archive 路径和 prefix 已固定，但 archive 本体尚未锁定
SHA-256、字节数和 member list；checker 能从部分 `BIT()` / `GENMASK()` 推导 lsb/width，
但部分 qword base、body translation 和 golden 仍来自 Python 人工表；当前也没有直接
针对锁定驱动源码构建的 C oracle。本文把这些内容列为待建立门禁，不能把设计目标
描述成已经存在的证明。

现有门禁尤其不能证明“驱动声明或读取的每个字段都被对应 codec 实际消费”。因此，
即使 profile checker 通过，CQE/RQE/CEQE/AEQE 等 decode 路径仍可能遗漏硬件输出字段。
本设计增加字段所有权/消费矩阵和独立 C oracle，填补这个缺口，而不是放宽全部
reserved 位。

### 2.3 当前 CMQ 脏改动的处置

工作树中现有四项 CMQ 相关修改不能整体视为已修复：

- `wait_for()` deadline 返回 `RDMA_SC_TIMEOUT` 的方向正确，但需要专门测试。
- OCC completion 掩码具有驱动字段依据，但新增的 20 个 opcode 当前不在 completion
  codec 的 `supported_opcode()` 中，相关分支不可达；仅增加 mask 不产生完整功能。
- MR recovery 依据“确定未提交”选择 hardware presence 的概念正确。
- adapter 按 `INVALID_STATE` / `INVALID_ARGUMENT` / `QUEUE_FULL` 猜测“确定未提交”不安全。

最后一项同时存在两个问题：scheduler 可能已经写 Host memory 或尝试 MMIO 后才返回
同一错误码；adapter 级 `last_execute_no_submit_proven` 单 bit 还会被并发调用覆盖。
因此当前 adapter/control-plane 改动不得按原形合入。

## 3. 统一的硬件字段契约

### 3.1 字段所有权矩阵

新增受版本控制的 `hw/rdma/field_ownership.tsv`，由
`tools/check_rdma_field_ownership.py` 读取。每条源记录至少包含：

```text
source_manifest_record
macro_name
source_anchor
entry_kind
opcode_or_variant
direction
ownership
capability
model_field_or_raw_slice
owning_codec
overlay_group
discriminator
oracle_case_id
```

TSV 不重复手写 qword/offset/lsb/width。checker 必须从 manifest 锁定的驱动头和
`BIT()` / `GENMASK()` 表达式实时推导这些坐标，再与模型 `_OFFSET/_LSB/_WIDTH`
和 codec consumer 对照，并生成带坐标的诊断报告。这样 ownership 文件只是消费关系，
不会成为第二份可能漂移的位结构真值表。

`source_manifest_record` 使用 manifest 的
`archive identifier + path + selector + sha256` 四元组定位，不依赖易漂移的行号。

无法由单个宏表达的 `memcpy`、结构整体搬移或 overlay 判别，记录其 manifest source、
稳定源码锚点和 golden vector 名称；checker 从锁定 source 内容验证锚点，不接受只有
自然语言、没有机器证据的偏移声明。

`source_anchor` 不是一段模糊字符串。每个非宏坐标必须记录 path、function、规范化
token/AST occurrence、container expression、buffer argument、operation
（set/get/memcpy/offsetof）、expected length/base 和目标 image 数据流。checker 要求该
锚点在锁定 source 中唯一，并证明调用结果流向目标 image；零匹配、多匹配、只命中
声明/注释或命中错误 buffer 都硬失败。

checker 不能继续把 Python 中手写的 `word_byte_offset`、body translation 或大 mask
当成驱动坐标来源。它必须从锁定 C 源中的 `set_64bit_val()`、`get_64bit_val()`、
`memcpy()`、`offsetof()` 或等价调用点推导 container byte offset，再与宏推导的 lsb/width
组合成完整坐标。手写期望值只能作为第二路交叉断言；不能同时驱动 C oracle 和 SV
检查，否则两边可能共享同一个错误。

`ownership` 只允许：

- `HOST_TYPED`：Host 编码的已类型化字段；
- `HW_TYPED`：硬件回写并由模型解码的已类型化字段；
- `HW_OPAQUE`：有驱动/硬件依据，但当前只保留 raw 的硬件字段；
- `RESERVED_ZERO`：协议要求为零。

`capability` 独立记录 request/response 是 `SUPPORTED` 还是 `UNSUPPORTED`。
它是整个 opcode/entry 方向的能力，不与单个 bit 的 ownership 混用。

矩阵检查必须验证：

1. 驱动清单中的目标宏要么有消费记录，要么有带理由的排除记录。
2. 同一 entry/opcode 的字段不能重叠，除非显式登记 overlay/discriminator。
3. encode 不得写 `HW_TYPED`、`HW_OPAQUE` 或 `RESERVED_ZERO`。
4. decode 必须接受 `HW_TYPED`，完整保存 `HW_OPAQUE`，拒绝非零 `RESERVED_ZERO`。
5. `UNSUPPORTED` 不能被 request/response capability gate 误报为可编解码；
   兼容 `is_supported()` 不得再用于能力决策。

### 3.2 reserved 位策略

reserved 检查继续 fail-closed，不采用“未知位全部放行”的策略：

- Host-to-device image 中真正 reserved 的位必须为零。
- Device-to-host image 中由驱动读取的输出位必须按矩阵放行。
- 尚未类型化但有来源证据的区域只能登记为 `HW_OPAQUE`，并保留原始值。
- 未登记位仍拒绝；诊断必须包含 entry、opcode、qword/byte 和非零 bit range。

每种 entry 采用逐 bit mutation test：对每一位翻转一次，验证其被类型化解码、
opaque 保存或 reserved 拒绝，避免只靠一个大 mask 的正向样本。

### 3.3 原始驱动数据结构防漂移

驱动 tarball、目标头文件和宏族继续由 `hw/rdma/source_manifest.txt` 的 SHA-256
记录锁定。模型侧不得手写一份无法追溯的“等价结构”；每个结构或 command contract
必须能追溯到 manifest 中的文件、宏或驱动实际读写代码。

在实现阶段 0 增加受版本控制的 archive lock，至少记录：archive identifier、
SHA-256、精确字节数、唯一顶层 prefix 和规范化 member-list hash。53 门禁必须先验证
archive lock，再解包并逐条验证 source manifest 的路径、SHA、selector 和源码锚点。
archive 是否携带 `.git` 元数据不得改变验证强度；缺 archive、hash 不符、prefix 多于
一个或目标 member 缺失都必须硬失败，禁止跳过后继续通过。

lock schema 使用明确字段名 `RDMA_ARCHIVE_SHA256`、`RDMA_ARCHIVE_SIZE_BYTES`、
`RDMA_ARCHIVE_PREFIX` 和 `RDMA_ARCHIVE_MEMBER_LIST_SHA256`；Make/checker 从该文件读取，
不能在两个脚本里分别维护默认 hash。

仓库内早期设计引用过旧驱动版本，其文字和数值只作为历史背景。发生冲突时，
当前 manifest 锁定的 0.1.34 source、机器解析结果和对应 golden vector 优先；
不得从旧规格复制 ring 容量、字段位置或 opcode 能力覆盖当前基线。

字段门禁在各后续规格逐项启用后的完成态至少覆盖下列维度；本规格的实际阻断范围严格
限定为 §3.4 的 CMQ 闭合集合：

- entry/context 的总字节数、对齐和端序；
- 每个字段的 byte/qword offset、lsb、width 和读写方向；
- 公共 header 与 command body 的边界；
- CQC/QPC/SRFQC/EQC 等本地 context 坐标，以及嵌入 CMQ SQE 时的显式 base offset；
- 共用地址上的 overlay、union 和 discriminator，例如 SRFQ doorbell 的 bit63/bit62；
- request 与 completion 中同名但方向或位置不同的字段；
- 驱动完整写入、部分写入和只读回写之间的区别。

上下文模型只使用本地坐标定义。放入 SQE 时通过显式 `embed_at(base_byte)` 或等价
接口搬移，禁止在每个字段常量中偷偷加 8/16 字节。这样可避免把 SQE 坐标误用于
Host-memory context slot，也能单独检查 context 与 envelope。

每个被对应阶段 capability 表声明为已支持的 opcode/entry 必须同时具备：

1. 来自真实驱动的正向字节向量；
2. 模型 encode 与向量逐字节相等；
3. 模型 decode 后字段值与驱动语义相等；
4. 对同一方向同时提供 encode/decode 的结构执行 round-trip；仅提供单向 codec 的
   结构用 raw vector 与逐字段断言验证，不伪造反向能力；
5. 每个 reserved 位的负向 mutation；
6. 重构前后旧实现与新实现的差分字节测试。

golden vector 的 oracle 必须与 SV 实现独立：优先用一个针对锁定 tarball 构建的最小
C probe，直接使用原驱动宏、结构和 builder 生成字节/字段报告；不能让 Python oracle
与 SV codec 同时读取一份手抄 mask 后互相“证明正确”。C probe 无法独立编译的布局，
只能用锁定源码片段和人工向量记录调查范围，不能据此开启 capability。

C probe 的输入和输出均为受版本控制的 canonical artifact。每个 case 至少固化：

- archive/source SHA、source anchor 和 driver prefix；
- probe source SHA、编译器版本与完整 flags；
- 非对称字段输入及其 SHA；
- canonical bytes、decoded field report 及其 SHA；
- entry、opcode、direction、总长度、alignment、endian 和 embed base。

正常门禁在临时目录重新编译 probe、重新生成输出，再与版本控制 artifact 比较。
Python/SV 可以消费 artifact，但不得生成或更新它。若原驱动 builder 因内核私有依赖
无法直接链接，probe 只可复用锁定头文件宏/结构并绑定对应源码锚点。只有能针对已验证
archive 重新编译、运行并产出 canonical bytes + field report 的 C probe 才能把
`request_encodable` 或 `response_decodable` 置为真。源码片段解析、人工向量和双人复核
只用于调查记录，不能开启 capability；仍无法独立证明的方向必须保持 `UNSUPPORTED`。

重建必须使用 artifact 锁定的 compiler executable identity、version、target ABI、目标
endianness 和完整 flags。compiler 缺失/版本不符、任何 warning、或 probe 内针对
`sizeof`、`_Alignof`、`offsetof`、byte order 的 static/runtime assertion 失败都非零退出；
不能只把工具链信息打印到日志后继续比较。

同一次测试同时保存 oracle 输入、driver source hash、输出字节和模型结果。任一 hash
变化都必须使旧向量失效并要求显式重建，禁止静默沿用旧驱动向量。

正向 case 必须使用能暴露 byte swap、qword shift 和 overlay 误选的非对称值；验收显式
断言总尺寸、alignment、qword memory order、C logical LSB 到内存 byte 的映射、公共
header/body 边界和 `embed_at(base_byte)`。仅 encode/decode round-trip 不能作为端序
或 offset 正确的证据。

每个 overlay group 必须枚举所有合法 discriminator。每个取值只能激活一组确定字段，
非活动视图不得被 codec 消费；非法 discriminator、未登记重叠和互斥位非法组合必须
拒绝。逐 bit mutation 对每个受支持的 64B CMQ request/response case 穷举 512 bit：
`HOST_TYPED`/`HW_TYPED` 与 C 语义一致，`HW_OPAQUE` 原值保留，`RESERVED_ZERO` 和未登记
位拒绝，并在失败信息中定位 entry/opcode/qword/bit。mutation 的 expected class/field
必须由同一个已验证 C probe field report 加 ownership checker 导出，不能读取 SV
descriptor mask 或被测 codec 来判断 typed/opaque/reserved；报告逐 bit 保存 case ID、
C-derived class/field 和 SV outcome。

无法完整证明 request 或 response layout 的 opcode 必须标记 `UNSUPPORTED`，不得提供
“只填已知字段、其余清零”的半实现。驱动 tarball、manifest、字段矩阵、golden vector
或 ABI 常量的任何变化必须放在独立提交中，附带来源 hash 变化和完整回归结果；
不得与类拆分或排版整理同时提交。

### 3.4 CMQ 首批 wire 范围

字段矩阵和 checker 框架最终可复用于所有 RDMA entry/context，但本规格第一批只启用
以下闭合集合：

- 64B CMQ SQE 公共 envelope；
- capability 表中明确 `request_encodable` 的 request body；
- 64B CMQ CQE 公共 header，以及明确 `response_decodable` 且有 C oracle 的 payload；
- 8B CMQ SQ doorbell 及其 metadata/endian；
- CMQ envelope 搬运本地 context 时的显式 base offset 和完整 payload byte equality。

最后一项把 local-context image 当作来自 C oracle 的 opaque payload，只验证
`embed_at(base)` 后的 64B envelope 全字节相等；它不代表本阶段已经审计 QPC/CQC/
SRFQC/EQC 内部字段。

QPC/CQC/SRFQC/EQC 的本地 context 内部字段、CQE/RQE/CEQE/AEQE 等非 CMQ queue entry，
以及没有独立 request/response oracle 的 opcode，不在 CMQ 首批新增支持范围。已有能力
先由 characterization 冻结；本阶段只验证 CMQ envelope 的嵌入边界，不借拆分之机
宣称这些 context/entry 的内部字段已经完成全量 ownership 审计。

阶段 1 必须建立可机读的 CMQ capability 表。每一行至少包含 opcode、方向、
`registered`、`request_encodable`、`response_decodable`、oracle case ID 和 owning codec。
能力为真必须同时具备 manifest/ownership、C oracle input/output、正向 byte vector 和
512-bit mutation 证据；任一缺失时对应方向保持 `UNSUPPORTED`。扩大该表属于独立 wire
contract 提交，不能混入 engine 分层或格式整理。

## 4. CMQ 首批目标架构

```text
rdma_cmq_engine                         唯一锁与生命周期 owner；兼容 facade
├── rdma_cmq_snapshot_guard             detached snapshot、图和值校验
├── rdma_cmq_ring_math                  PI/CI/wrap/used/full 纯函数
├── rdma_cmq_ledger                     slot、ticket、token、submission journal、late
├── rdma_cmq_transport                  64B SQ/CQ 搬运与提交阶段证据
└── existing rdma_cmq_codec_registry    opcode 能力与 request/response contract
```

### 4.1 `rdma_cmq_engine`

engine 保留现有公开入口和 probe 兼容面，负责：

- 持有唯一 `engine_lock`；
- 控制 UNCONFIGURED/PREPARED/ACTIVE/QUIESCED/POISONED 生命周期；
- 在锁内编排 snapshot、ledger 和 transport；
- 在 `wait_for` 释放锁后等待，并在重新取得锁后重新验证 ticket/epoch；
- 把各协作者的结果投影成现有 ticket/completion/status API。

任何协作者都不得跨 `wait_for` 解锁窗口缓存 engine 内部对象引用。

### 4.2 `rdma_cmq_snapshot_guard`

该对象封装 command/body/image/ticket/dependency 的 detached snapshot 与图拓扑检查。
它保存非拥有 profile/service 引用，但不拥有 ledger、ring cursor 或锁。

现有 `clear_body_references()` / `restore_body_references()` 会临时修改引用图，因此
snapshot guard 不是可在任意上下文调用的普通 utils。调用必须发生在 engine lock 下，
并满足失败原子性：失败后恢复源图，且不发布半成品 snapshot。

测试 seam 采用一个可注入 snapshot service。不得为了测试先把数十个内部 helper
全部改为 `virtual`；现有 probe 通过薄包装维持签名兼容。

### 4.3 `rdma_cmq_ring_math`

ring math 只接收数值快照，返回计算结果或明确错误，不访问对象成员：

- sequence 到 index/wrap/polarity 的映射；
- `publish_seq - retire_seq` 的 used/full 校验；
- CQ consume sequence 的位置与 owner；
- 溢出和非法顺序检查。

它不分配 UVM 对象、不取得锁、不修改 ledger，适合使用表驱动边界测试。

### 4.4 `rdma_cmq_ledger`

ledger 整体拥有：

- 32 个 slot record；
- token 使用位与 incarnation；
- command/entry registry；
- terminal、late diagnostic、late final 队列；
- publish/retire/CQ consume 三个 sequence。

ledger 不创建第二把锁，只提供名称带 `_locked` 的接口，并要求调用者已经持有
engine lock。submit 的本地准备使用 staged batch 对象，不能把多组平行数组分散提交。
“本地准备全或无”只适用于首次外部 I/O 之前；一旦 Host-memory、barrier 或 MMIO
可能产生副作用，就必须由持久 submission journal 接管，不能继续按 staged rollback
删除 ticket/token/slot 证据。

#### 4.4.1 CMQ batch submission journal

ledger 还拥有只服务 CMQ 的 batch submission journal。它不是跨 engine 的通用 recovery
ledger，也不创建锁；所有 `_locked` 操作都要求已经持有 `engine_lock`。

每个 batch record 至少保存：

- batch key、batch ID、当前 attempt ID、engine instance/incarnation、start/end
  sequence、当前 journal state、累计 `submission_effect`、本次 `attempt_effect`、
  observer-armed 和 publication-retry-safe evidence；
- batch-level Function identity、完整 binding、CMQ handle、doorbell image、最终
  PI/polarity 和稳定 batch digest；
- 每条 command 的 detached identity、ticket、token incarnation、slot index/wrap 和
  entry key；
- 每条 command 的 detached 64B SQE image、dependency image 和完整 DMA/Function
  authority；
- 每条 command 的 image/authority digest、累计 `submission_effect`、本次
  `attempt_effect`、completion phase、权威 retained completion、最后 status、
  `recovery_required` 和 recovery owner；
- 预分配的 command/entry index 节点，以及 reset epoch/Function generation。

recovery owner 是 item-level snapshot，不能只放在 batch 上。它至少包含 owning workflow、
resource handle、transaction ID、允许的恢复 action、完整 Function identity 和不可变的
`admission_attempt_id`；由提交该 command 的 control-plane/lifecycle workflow 显式提供，
engine 只验证并冻结，不从 opcode 或 status 猜 owner。同一 Function 的一个 batch 可以
包含属于不同 MR/QP/queue workflow 的 command。batch record 只拥有 fence coordinator
和共享 doorbell evidence，不能替各 item 决定补偿。

owner workflow 与 action 编码固定为四态枚举，`allowed_actions` 固定为
`logic [2:0]`：

```systemverilog
typedef enum logic [2:0] {
  RDMA_CMQ_WORKFLOW_INVALID,
  RDMA_CMQ_WORKFLOW_LEGACY_UNMIGRATED,
  RDMA_CMQ_WORKFLOW_MR,
  RDMA_CMQ_WORKFLOW_QUEUE,
  RDMA_CMQ_WORKFLOW_QP
} rdma_cmq_recovery_workflow_e;

typedef enum logic [1:0] {
  RDMA_CMQ_RECOVERY_INVALID,
  RDMA_CMQ_RECOVERY_RETRY_PUBLISH,
  RDMA_CMQ_RECOVERY_CONFIRM_RESET_ISOLATION
} rdma_cmq_submission_recovery_action_e;
```

具体 owner 在首次 admission 时验证 workflow/resource-kind/action matrix，随后以完整
Function identity 和非零 `admission_attempt_id` 冻结。MR 只接受 MR，QP 只接受 QP，
QUEUE 只接受 CQ/SRQ/CEQ/AEQ；FUNCTION、PD、CMQ、MW 以及所有交叉组合均拒绝。bit 0
对应 INVALID，必须为零；至少一个合法 action bit 必须为一。精确
`LEGACY_UNMIGRATED` sentinel 保持未冻结、零 authority、零 admission attempt 且不允许
任何 action，绝不能从 opcode/status 提升成具体 owner。所有 workflow/action/mask 在索引
或迁移前先拒绝 X/Z、INVALID 和 spare 编码。

journal state 固定为：

```systemverilog
typedef enum logic [3:0] {
  RDMA_CMQ_SUBMISSION_STAGED,
  RDMA_CMQ_SUBMISSION_PENDING_EFFECT,
  RDMA_CMQ_SUBMISSION_HOST_VISIBLE_NOT_PUBLISHED,
  RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS,
  RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED,
  RDMA_CMQ_SUBMISSION_COMPLETED,
  RDMA_CMQ_SUBMISSION_TIMED_OUT_QUARANTINED,
  RDMA_CMQ_SUBMISSION_LATE_COMPLETED,
  RDMA_CMQ_SUBMISSION_RESET_QUARANTINED
} rdma_cmq_submission_state_e;
```

state 在任何 array/state indexing 前拒绝 X/Z 和 9..15 spare。
`rdma_cmq_reduce_batch_state()` 只生成 diagnostic aggregate，不授权迁移；它拒绝
pre-MMIO/published 的不可能混合，否则按保守顺序选择 `RESET_QUARANTINED`、
`HOST_VISIBLE_NOT_PUBLISHED`、`PUBLISH_AMBIGUOUS`、`TIMED_OUT_QUARANTINED`、
`PENDING_EFFECT`、`STAGED`，然后在仍有 pending item 时选 `PUBLISH_CONFIRMED`；全部
completed 返回 `COMPLETED`，全部 terminal 且至少一项 late 返回 `LATE_COMPLETED`。

状态迁移和释放规则如下：

```text
snapshot / encode / slot-token 预分配完成
    -> STAGED
       只存在于锁内 stage；尚未调用任何外部 I/O

即将调用 scheduler observed 入口
    -> PENDING_EFFECT
       ledger 接管完整 batch record；所有对象、索引节点和恢复证据已经预分配

scheduler 在任何外部 I/O 前确定拒绝
    -> effect = PRE_SUBMIT_REJECTED
    -> 原子删除该 batch record，释放 reservation
    -> 对外 ticket 必须为 null

首次 Host-memory write 已进入，但尚未进入 MMIO
    -> effect 至少为 HOST_MEMORY_MAYBE_VISIBLE
    -> scheduler 返回时归类为 HOST_VISIBLE_NOT_PUBLISHED

即将进入 MMIO
    -> 无失败地安装预分配 command/entry index、推进 publish_seq
    -> PUBLISH_AMBIGUOUS / effect = MMIO_MAYBE_VISIBLE

MMIO 明确成功
    -> PUBLISH_CONFIRMED / effect = MMIO_VISIBLE
    -> 等待 completion

正常 completion
    -> COMPLETED；按有序 retire 规则释放运行资源

timeout
    -> TIMED_OUT_QUARANTINED
    -> 对调用方发布 RDMA_CMQ_COMPLETION_TIMEOUT，但该 record 不是可释放终态
    -> 保留 slot/entry key/ticket/epoch/original token incarnation，等待 late completion 或 reset

reset / FLR
    -> RESET_QUARANTINED；旧 epoch 只保留 detached diagnostic

late completion
    -> LATE_COMPLETED
    -> 只按原 ticket/epoch/entry key 更新旧 record，不得命中新 epoch
    -> 产生 late diagnostic/final completion 后再按有序 retire 释放旧 slot
```

`STAGED -> PENDING_EFFECT` 之前必须完成所有 UVM 对象分配、clone、容量检查、index
冲突检查和 invariant 校验。MMIO 前的 arm 只能更新已预分配 record、index 和 cursor；
不得分配、不得失败、不得取得新锁、不得等待，也不得调用外部服务。

effect 一旦达到 `HOST_MEMORY_MAYBE_VISIBLE`，该 batch 的 journal record、slot、token 和
ticket 就不得通过普通错误回滚删除。若 transport 在 MMIO 前失败，engine 进入
submission fence。ledger 持有唯一 `fenced_batch_id`、fence reason 和独立的
ticket-to-journal-attempt index；该索引让尚未 arm 的 ticket 可被查询，但不能冒充
completion entry registry。

fence 存在时，所有新 CMQ submit 都在调用 scheduler 前以
`RDMA_SC_RESOURCE_BUSY + PRE_SUBMIT_REJECTED` 返回；不允许选择其他空 slot 绕过 gap。
poll、wait、journal query、受控 recovery、reset/FLR 和诊断读取仍可运行。fence 只能在
同一 batch 成功 arm 为 `PUBLISH_AMBIGUOUS`、reset/FLR 完成上述 allocation-free commit，
或后续单独批准的安全 abort 后清除；普通 `reconcile(ticket)` 不得自行再敲一次门铃。

首批只提供两个显式恢复 action，不实现“直接擦除 Host-memory image 并释放”的捷径：

```systemverilog
typedef enum logic [1:0] {
  RDMA_CMQ_RECOVERY_INVALID,
  RDMA_CMQ_RECOVERY_RETRY_PUBLISH,
  RDMA_CMQ_RECOVERY_CONFIRM_RESET_ISOLATION
} rdma_cmq_submission_recovery_action_e;

task recover_submission_observed(
  input rdma_cmq_submission_recovery_request request,
  output rdma_cmq_execution_result results[],
  output rdma_status status
);
```

request 必须携带 batch key/ID、期望当前 attempt ID、期望 Function immutable identity、
完整 binding/CMQ/doorbell/final PI/polarity/sequence 的 batch authority 投影、稳定
batch digest，以及每项 recovery-owner identity 和 detached image/authority digest。
record 保存同一完整 batch authority 投影；recovery 从 request-owned graph 和
journal-owned graph 分别重算并校验，而不信任携带的 digest。
`RETRY_PUBLISH` 只允许 `HOST_VISIBLE_NOT_PUBLISHED`，且 scheduler evidence 必须明确
observer 从未 arm、effect 不超过 `HOST_MEMORY_ORDERED`；当前 mapping、authority、
Function generation、reset epoch 和每个 image/hash 必须与 journal 完全相同。重试仍用
原 batch/slot/ticket，只允许同一组 bytes 执行一次新的 scheduler attempt；失败时更新
attempt/effect，但保留 journal 和 fence，进入 MMIO 后则按正常 ambiguous/confirmed 路径。
相同 authority/image/hash/epoch 下的 dependency write 必须具有字节确定性并经 adapter
契约证明可安全重放；不满足该条件时禁止 retry，只能等待 reset/FLR 隔离。

recovery 采用 CAS 式 attempt 语义。request 的 `expected_attempt_id` 必须等于 journal
当前 attempt；比较、验证全部 item、递增 attempt 和发布新 attempt ID 必须在同一
`engine_lock` 临界区原子完成，并在调用 scheduler 前结束所有可失败的本地准备。两个
并发/重复 retry 中只能一个取得新 attempt；随后到达的旧 expected ID 返回
`RDMA_SC_INVALID_STATE` 和稳定的“stale CMQ recovery attempt”消息，不调用任何外部 I/O。
attempt overflow 在 I/O 前返回 `RDMA_SC_RESOURCE_EXHAUSTED`。无论 scheduler 后续成功或
失败，每项 result 都返回已经生效的 current attempt ID，调用方不得猜测是否递增。该
current attempt 只描述 batch/CAS 进度；owner 的 `admission_attempt_id` 是首次 admission
provenance，retry 不得重写它。

每个 attempt 同时保存两个 effect。`attempt_effect` 只描述本 API 调用触发的 scheduler
attempt；`submission_effect` 是该 command 生命周期的保守累计高水位。正常首次
scheduler envelope 中二者相等；若 authentic arm callback 后 envelope 丢失，原始
`attempt_effect=UNOBSERVED`，而累计值必须吸收 callback 的 `MMIO_MAYBE_VISIBLE`。跨
attempt 折叠只在五个 Host-memory/MMIO concrete 值之间取阶段最大值；当前
`PRE_SUBMIT_REJECTED` 或 `UNOBSERVED` 不得抹去既有 concrete evidence。prior 为
`UNOBSERVED` 时，后续 concrete evidence 可替换它；否则 `UNOBSERVED + PRE/UNOBSERVED`
仍为 `UNOBSERVED`。生命周期 completion、timeout、late 或 reset 更新不得重写任一
effect。

recovery request 内的 item list 必须与 journal 原 batch 等长同序，且 identity/owner/hash
逐项唯一匹配。batch 可定位且 item list 结构合法时，`results[]` 在 action 成功、失败或
stale attempt 下都与 request items 等长同序，每项 status 非空；顶层 status 只描述该
recovery orchestration。batch/attempt 身份无法定位，或 item list 缺项、重复、乱序、
数量不符时，`results[]` 为空并返回非空 `INVALID_ARGUMENT`/`INVALID_STATE`，journal、
attempt 和 fence 完全不变。

reset/FLR 的 observed 生命周期必须严格按以下顺序执行；每个箭头都是不可跳过的提交
边界：

```text
mutation-free staging
    -> confirmed backing release
    -> allocation-free reset commit / fence clear
    -> optional replacement prepare
    -> READY proof
    -> workflow confirmation
```

`stage_reset_candidate_locked()` 只能在锁内构造 detached candidate、取消 completion、
proof 和调用方输出，不能修改 engine-owned map/FIFO/counter/state。只有
`validate_failure_atomic_release()` 成功后，才可对 staged opaque authority 调用
`release_opaque()`；null/non-OK 返回必须丢弃 candidate、清空 detached outputs，并逐值
保留 journal、slot/token/index/cursor、FIFO、counter、state、fence 与 backing authority。
释放成功后，`commit_reset_candidate_locked()` 是 allocation-free、no-fail 的锁内提交：它
只写预先存在的 retained rows/proof/completion，清理旧 epoch runtime/preallocation 与
submission fence，并允许下一次独立 prepare；不得再调用 adapter、scheduler、factory、
clone、`new`、队列插入或 associative-array 插入。

`CONFIRM_RESET_ISOLATION` 不能自行发起 reset、释放 backing、比较 replacement mapping、
清除 fence 或调用任何 I/O。它只能消费 engine 已登记且 `READY` 的 proof，在同一锁内重验
完整 journal/proof digest、ordered tuple、owner permission 和
`RESET_QUARANTINED/RESET_CANCELLED` 生命周期，然后把尚未解决的 concrete-owner item
标记为 `reset_isolation_confirmed=1`、`recovery_required=0`。精确
`LEGACY_UNMIGRATED` sentinel 在确认 backing release 的 reset commit 中立即得到这两个
resolved 值，因此不需要伪造 workflow confirmation；detached diagnostic/proof 仍保留。
对 batch 可定位且 item list 合法的 action，校验失败返回逐项非空 result/status，原
journal/fence 不变。

reset 的公开 seam 固定为：

```systemverilog
task reset_observed(
  output rdma_cmq_completion completions[$],
  output rdma_cmq_reset_isolation_proof proofs[],
  output rdma_status status
);

task query_reset_isolation_proof(
  input string proof_key,
  output rdma_cmq_reset_isolation_proof proof,
  output rdma_status status
);
```

Host-memory adapter 必须在 reset staging 前提供只读的
`validate_failure_atomic_release(mapping)` capability；validator 不释放、不 seal、不改
ledger，unsupported/default mapping 必须 fail closed。只有明确 advertised 且返回 OK 的
adapter 才能进入上述 release/commit 顺序。

reset-isolation proof 使用四态状态：

```systemverilog
typedef enum logic [1:0] {
  RDMA_CMQ_RESET_PROOF_INVALID,
  RDMA_CMQ_RESET_PROOF_AWAITING_REBIND,
  RDMA_CMQ_RESET_PROOF_READY
} rdma_cmq_reset_isolation_proof_state_e;
```

公开构造出的 proof 只有 `INVALID`，不能凭字段相似自行取得 authority。
`AWAITING_REBIND` 只由成功的 backing release commit 产生，并仍引用旧 identity；释放
后 engine 已可准备独立的新 backing。可选 replacement prepare 只有在 ACTIVE 成功建立、
且新 identity 保持相同 immutable Function、reset epoch 严格递增时，才把 proof 提升为
`READY`。proof 保存 proof/batch/attempt/engine identity、isolated/replacement identity、
batch digest、release confirmation，以及有序四字段 tuple `{request_index, image_digest,
authority_digest, full recovery_owner}`。四个 tuple 数组必须非空、等长、同序；所有
enum/mask 在索引或迁移前拒绝 X/Z/spare。replacement identity、proof state 和
release-confirmation 不进入稳定 proof digest，但完整值相等和合法迁移校验仍然必需，
匹配 digest 本身永不授权 recovery。

若未来需要 erase/abort，必须另立规格并提供原始 preimage、排他 mapping ownership、
DMA/read fence 和硬件绝不会读取该 slot 的证明；本规格不允许通过写零或覆盖 SQE 来
推断安全释放。

batch ID 和 attempt ID 由 ledger 在锁内单调分配，稳定身份是
`Function immutable identity + engine incarnation + reset epoch + counter`。counter 不得
wrap 或复用；溢出必须在任何外部 I/O 前 poison/reject。retry 增加 attempt counter，
但保持原 batch ID、ticket、slot 和 recovery owner；owner 内首次冻结的
`admission_attempt_id` 永远不随 current attempt 前进。

effect 达到 `MMIO_MAYBE_VISIBLE` 后，整批 record 保持 `PUBLISH_AMBIGUOUS` 或
`PUBLISH_CONFIRMED`，slot/entry key 持续由该 batch 独占；outstanding/ambiguous token
同样不能提前复用，其中 ambiguous 和 timeout 状态进入 quarantine，正常 confirmed 状态
按普通 outstanding 管理。禁止重复 doorbell，也禁止提前复用 entry key。reset/FLR 将
未终态 record 转成 `RESET_QUARANTINED`；上述 allocation-free commit 释放旧 epoch 运行
资源、清除 fence，但保留 journal-owned detached diagnostic/proof record，使新 epoch 可
独立 prepare。旧 epoch late completion 只能进入 diagnostic，绝不能修改新 epoch 的
slot/token/result。

timeout 时软件 command registry 和可分配 token 是否释放，保持现有
incarnation-safe characterization；无论该实现细节如何，slot、entry registry、原 ticket、
token incarnation 和 epoch 必须保留到 `LATE_COMPLETED` 的有序 retire 或 reset 隔离。
`RDMA_CMQ_COMPLETION_TIMEOUT` 只是对调用方的 completion phase，不是 journal 可回收终态。

`recovery_required` 是按 command lifetime state 推导的保守“仍可能存在且未完全解决”位，
不是自动 retry 能力。它同时保存在 journal item 和每次返回的 result 中；自动恢复还要求
非零 batch/current-attempt identity、具体且已冻结的 owner、匹配的完整 journal authority，
以及 action 所需 proof。精确表固定如下：

| lifetime state / phase | `recovery_required` |
| --- | --- |
| 初始本地 `PRE_SUBMIT_REJECTED/NONE`，没有 retained journal | `0` |
| `HOST_VISIBLE_NOT_PUBLISHED/NONE` | `1` |
| `PUBLISH_AMBIGUOUS` 或 `PUBLISH_CONFIRMED` 且 phase 为 `PENDING` | `1` |
| `TIMED_OUT_QUARANTINED/TIMEOUT` | `1` |
| `RESET_QUARANTINED/RESET_CANCELLED`，具体 owner 的 proof 为 `AWAITING_REBIND` 或尚未确认的 `READY` | `1` |
| `RESET_QUARANTINED/RESET_CANCELLED`，精确 legacy sentinel 且 backing release 已确认 | `0` |
| `COMPLETED/TERMINAL`、`LATE_COMPLETED/DIAGNOSTIC_ONLY` 或 reset isolation 成功确认 | `0` |
| 任一 `UNOBSERVED` result 或 delegation 后 malformed/degraded evidence | `1` |

分类器必须穷举 state/phase/effect/proof 组合，并在读取或索引前拒绝 X/Z、spare 与不可能
组合；拒绝时不得改写调用方预置输出。retry 若在 I/O 前拒绝，只更新本次
`attempt_effect=PRE_SUBMIT_REJECTED`，不得清除 retained item 先前的 recovery bit。

每个 journal item 还拥有权威 detached lifecycle `completion`。phase 为 `NONE` 或
`PENDING` 时它才允许为空；`TERMINAL`、`TIMEOUT`、`RESET_CANCELLED` 和
`DIAGNOSTIC_ONLY` 必须保留 public wait/reconcile/execute 所使用的同一完整 completion
值。FIFO 只可作为 delivery-order index；pop FIFO 绝不能销毁 retained journal evidence。

legacy `reconcile_ticket()` 是只读 journal projection，不是 recovery action。它先按稳定
ticket index 和完整 ticket equality 定位 retained item；只有当前 active incarnation 的
`PUBLISH_AMBIGUOUS` 或 `PUBLISH_CONFIRMED/PENDING` 才允许一次普通 poll/expire，所有
terminal、timeout、late、reset 或未 arm 的 fenced row 都只返回 retained detached evidence。
它不调用 `RETRY_PUBLISH`、不敲门铃、不消费 retained completion，也不因当前 runtime 已是
新 incarnation 而拒绝旧 reset ticket；`STAGED/PENDING_EFFECT` 则 fail-closed 且不改
任何 effect 或 recovery bit。

这里的 exactly-once 是按生命周期事件和 phase 解释的，而不是限制一个 ticket 在整个
生命周期只能出现一条 completion。一个 item 若先产生
`TIMED_OUT_QUARANTINED/TIMEOUT`，再因 reset 进入
`RESET_QUARANTINED/RESET_CANCELLED`，两个事件各自产生一次相互 detached 的观察证据；
reset 前已经进入 delivery FIFO 的 timeout projection 仍按原顺序返回，reset cancellation
projection 则作为新的 reset 事件追加。`wait_for()` 只删除目标 ticket 的 FIFO row，不能
删除其他 ticket 的 delivery row；`reconcile_ticket()` 始终从 retained journal 重建
快照，因此 FIFO 消费不会抹掉恢复 authority。对 terminal row，reconcile 的 `status`
是返回 completion 的 operation status（例如 `RDMA_SC_RESET_CANCELLED`），而不是把所有
成功观察统一改写为 orchestration-level `RDMA_SC_OK`；`terminal_known=1` 表示终态已知。

`submit_batch_observed()` 对输入逐项返回 result，顺序和数组长度必须与 requests 完全
一致。共享一次 doorbell 的条目共享 batch ID 和 batch-level effect，但每条 result、
ticket、status、identity 和 completion phase 都是独立 detached 值。单命令入口只是
一项 batch 的包装，不能另写一套副作用状态机。

#### 4.4.2 CMQ journal canonicalization 与 digest authority

journal digest 只使用显式、版本化、schema-closed 的 canonical writer。禁止使用 UVM
field automation、`sprint()`、`pack_bytes()`、host-endian integer、对象 instance name 或
隐式 `get_type_name()`。primitive 编码固定为：

- domain tag 是列出的 ASCII bytes 加最终 NUL，不带长度；
- `u8/u16/u32/u64` 为 unsigned big-endian 固定宽度，窄 packed 值先零扩展；
- boolean/enum 为一个 `u8`，有 X/Z 或 spare 值时在写入前拒绝；
- string 为 `u32 byte_count` 加经验证的 UTF-8/`getc()` bytes；truncated、overlong、
  surrogate、超过 U+10FFFF 或长度超过 `32'hffff_ffff` 时原子拒绝；
- object 为 `u8 present`，存在时再写 counted stable schema tag 和字段；absent 只能配空
  tag，present 必须配非空 tag；
- dynamic queue/array 为 `u32 element_count` 加 index order 元素；fixed array 无 count，
  按升序写入；
- 256-bit digest 从 bit 255 到 bit 0 以 32 个 byte、MSB first 写入。

所有复合 encoder 先写本地 child writer，仅在完整验证成功后把 raw child bytes 原子追加
到 parent；任何失败都不得留下 prefix。writer snapshot 返回 detached bytes 且不清空
writer。

V1 nested schema 及字段顺序冻结如下。增删或重排字段必须新建 V2，不能静默改变 V1：

- `HANDLE-V1`：`kind(u8)`、`function_uid(u64)`、`object_id(u32)`、
  `generation(u32)`；Function handle 验证 runtime subtype 后仍用同一 schema。
- `BDF-V1`：`segment(u16)`、`bus(u8)`、`device(u8)`、`function_num(u8)`。
  `ROUTE-V1`：`host_topology_key(u32)`、`root_id(u16)`、`segment(u16)`、
  `BDF-V1 bdf`。
- `FUNCTION-IDENTITY-V1`：`key.root_id(u16)`、`key.host_topology_key(u32)`、
  `key.function_kind(u8)`、`BDF-V1 key.parent_pf_bdf`、`key.vf_index(u16)`、
  `BDF-V1 key.bdf`、`global_function_id(u32)`、`function_uid(u64)`、
  `generation(u32)`、`reset_epoch(u64)`。
- `OPCODE-KEY-V1`：`profile_name(string)`、`opcode(u32)`、`variant(string)`。
  `RECOVERY-OWNER-V1`：`workflow(u8)`、`resource_h(HANDLE-V1)`、
  `transaction_id(u64)`、`allowed_actions(u8)`、
  `function_identity(FUNCTION-IDENTITY-V1)`、`admission_attempt_id(u64)`、
  `frozen(u8)`；只有精确 legacy sentinel 的 resource/identity 可为 absent。
- `IMAGE-V1`：`length(u64)`、`alignment(u32)`、`endian(u8)`、
  `image_kind(u8)`、`hardware_version(u32)`、`function_generation(u32)`、
  `write_target_kind(u8)`、`backing_target.value(u64)`、`hmc_target.value(u64)`、
  `bar_target.value(u64)`、`bytes(queue<u8>)`、`field_summary(queue<string>)`；验证
  `bytes.size()==length`。
- `CMQ-TICKET-V1`：`command_id(u64)`、`function_h(HANDLE-V1)`、
  `cmq_h(HANDLE-V1)`、`slot_sequence(u64)`、`sq_index(u32)`、`sq_wrap(u8)`、
  `opcode_key(OPCODE-KEY-V1)`、`absolute_deadline(u64)`。
- `DMA-CONTEXT-V1`：`function_h(HANDLE-V1)`、`BDF-V1 requester_bdf`、
  `pasid_valid(u8)`、`pasid(u32)`、`dma_domain_valid(u8)`、
  `dma_domain_id(u32)`、`ROUTE-V1 route`、`reset_epoch(u64)`、
  `route_valid(u8)`、`epoch_valid(u8)`、nullable `owner_h(HANDLE-V1)`、
  `queue_role_valid(u8)`、`queue_role(u32)`。
- `DMA-MAPPING-PUBLIC-V1`：`function_h(HANDLE-V1)`、`BDF-V1 requester_bdf`、
  `pasid_valid(u8)`、`pasid(u32)`、`dma_domain_valid(u8)`、
  `dma_domain_id(u32)`、`ROUTE-V1 route`、`reset_epoch(u64)`、
  `route_valid(u8)`、`epoch_valid(u8)`、`backing_addr.value(u64)`、
  `iova.value(u64)`、`size(u64)`、`direction(u8)`、
  `permissions.device_read(u8)`、`permissions.device_write(u8)`、
  `permissions.atomic(u8)`、`state(u8)`、nullable `owner_h(HANDLE-V1)`、
  `umem_backed(u8)`、`umem_page_count(u32)`。`umem_ref/pbl_ref/mw_ref`、concrete
  subtype、adapter token 和所有 opaque allocation identity 明确排除；opaque capability
  equivalence 另行校验，public digest 相同不能授权另一 allocation。
- `FUNCTION-BINDING-V1`：`function_uid(u64)`、accessor 返回的 detached
  `FUNCTION-IDENTITY-V1`、`pcie.bdf(BDF-V1)`、
  `pcie.parent_pf_bdf(BDF-V1)`、`pcie.vf_index(u32)`、`pcie.mse(u8)`、
  `pcie.bme(u8)`；六个升序固定 BAR `{bar_id(u8), base.value(u64), size(u64),
  enabled(u8)}`；`notify_bar_id(u8)`、`notify_base.value(u64)`、
  `notify_size(u64)`、`notify_table_sel(u32)`、`notify_table_index(u32)`、
  `host_id(u32)`、`pfvf_id(u32)`、`rdma_vf_id(u32)`、
  `global_function_id(u32)`、`vsi_id(u32)`；queue DMA 的
  `requester_bdf(BDF-V1)`、`pasid_valid(u8)`、`pasid(u32)`、
  `dma_domain_valid(u8)`、`dma_domain_id(u32)`；queue capability 的
  `min_cq_depth(u32)`、`max_cq_depth(u32)`、`min_srq_depth(u32)`、
  `max_srq_depth(u32)`、`max_ceq_depth(u32)`、`max_aeq_depth(u32)`、
  `max_wq_sge(u32)`、`max_queue_ring_bytes(u64)`、`max_sgb_bytes(u64)`；
  interrupt-vector queue 中每项 `function_local_vector(u32)`、
  `hardware_eq_vector(u32)`、`msix_table_index(u32)`、`enabled(u8)`；最后为
  `state(u8)`、`generation(u32)`、nullable `owner_h(HANDLE-V1)`、
  `notify_valid(u8)`、`notify_ready(u8)`、`dmi_valid(u8)`、`dmi_ready(u8)`、
  `vft_valid(u8)`、`vft_ready(u8)`。

`CMQ-COMMAND-V1` 依次编码 `function_h(HANDLE-V1)`、
`opcode_key(OPCODE-KEY-V1)`、精确 polymorphic body tag/schema、nullable
`qpc_signature_source(IMAGE-V1)`、`vfid_override(u8)`、`use_vfid(u16)`、
`timeout(u64)`、`recovery_owner(RECOVERY-OWNER-V1)`。body runtime tag 不得来自 factory
name，仅允许以下五种 exact runtime type，任何 subclass/未知类型都拒绝：

这里的 exact runtime type 以唯一、正确注册的 UVM wrapper 身份为闭合契约：对象的
`get_object_type()` 必须与下列具体类型的 `get_type()` singleton 相同；可覆盖的
`get_type_name()` 只用于诊断，不能参与 dispatch、canonicalization 或 authority 判断。
因此，拥有独立 wrapper、但把 `get_type_name()` 伪装成受支持基类名的注册子类仍必须
原子拒绝。当前 VCS/SystemVerilog 不提供从基类 handle 查询不可伪造的动态 class
identity；完全未注册且不覆盖任何虚方法/字段的 fieldless 子类与基类不可观测地区分，
故这类对象位于支持模型契约之外，production producer 不得构造或传入该边界。

- `CMQ-BODY-QPC-V1`：nullable `qp_h/send_cq_h/recv_cq_h(HANDLE-V1)`、
  `qpc_buffer.value(u64)`、`next_state(u8)`、`full_modify(u8)`、
  `partial_modify(u8)`、`wbe_template_count(u8)`，随后 indices 0..3 的
  `{modify_start_qword(u8), modify_wbe(u8), modify_data(u64)}`。
- `CMQ-BODY-OBJECT-ID-V1`：`object_h(HANDLE-V1)`。
- `CMQ-BODY-MR-DEREGISTER-V1`：`mr_h(HANDLE-V1)`、`stag_key(u8)`、
  `next_state(u8)`。
- `CMQ-BODY-OCC-FLUSH-V1`：按序十二个 `u8`：`vf_flush`、`mr_serial_flush`、
  `qpc`、`cqc`、`mrt`、`pble`、`sqrqe`、`sgb_irqe`、`eirqe`、`orqe`、
  `uaqe`、`pd`，再写 `qpn(u32)`、`mr_serial(u16)`、
  `pd_backing.value(u64)`。
- `CMQ-BODY-EMPTY-V1`：tag 后无字段。

codec base profile 是唯一 layer-legal polymorphic canonicalization seam：

```systemverilog
virtual function rdma_status canonicalize_command_body(
  input rdma_hw_model source,
  output string schema_tag,
  output byte unsigned canonical_field_bytes[]
);
```

base 实现清空输出并返回 `RDMA_SC_UNSUPPORTED_OPCODE`。production profile 验证上述五种
exact body，返回稳定 tag 和 tag 之后的 field bytes；caller 每次都从实际 request-owned
或 journal-owned body 重新取得，不信任携带的 tag/bytes。model 层不得 cast codec body。
同一 profile 的 `snapshot_command_body()` 与 `snapshot_completion_payload()` 是
status-returning nonfatal polymorphic boundary：只接受精确支持的 runtime type，以 direct
construction 显式复制全部字段/bytes，不进入 raw factory、`copy()` 或 `clone()`；未知或
hostile subclass 返回非空 `INVALID_ARGUMENT`、null snapshot 和清空的 canonical output。
这里的精确检查同样使用上述注册 wrapper singleton，不信任类型名字符串。

`rdma_function_binding` 同样提供 `snapshot_identity_nonfatal()` 与
`snapshot_complete_nonfatal()`。两者入口清空 output，direct-construct identity、PCIe、六
BAR 和 owner 候选，验证完整值后才发布；complete snapshot 保持 exact base
`rdma_handle` 或 `rdma_function_handle` subtype，拒绝其他 subtype，且不触发 factory。
既有 identity accessor 委托该 seam，失败时只返回 null 而不发 UVM fatal。

digest 使用四条独立 64-bit FNV-1a lane，multiplier 为
`64'h00000100000001b3`，seed 依次为 `cbf29ce484222325`、
`84222325cbf29ce4`、`9e3779b97f4a7c15`、`d6e8feb86659fd93`，结果固定打包为
`{lane3,lane2,lane1,lane0}`。domain projection 固定为：

- image digest：`CMQ-IMAGE-V1\0`，随后 `IMAGE-V1 sqe_image`、
  `IMAGE-V1 dependency_image`；
- authority digest：`CMQ-AUTH-V1\0`，随后 `CMQ-COMMAND-V1 command`、
  `CMQ-TICKET-V1 ticket`、`RECOVERY-OWNER-V1 recovery_owner`、
  `FUNCTION-IDENTITY-V1 function_identity`、`DMA-CONTEXT-V1 dma_context`、
  `DMA-MAPPING-PUBLIC-V1 dependency_mapping`、`dependency_offset(u64)`；command 内
  owner 必须与 item owner 是同一 canonical source node；
- batch digest：`CMQ-BATCH-V1\0`，随后 `FUNCTION-IDENTITY-V1 function_identity`、
  `FUNCTION-BINDING-V1 binding`、`HANDLE-V1 cmq_h`、`IMAGE-V1 doorbell_image`、
  `final_pi(u32)`、`final_polarity(u8)`、`start_sequence(u64)`、
  `end_sequence(u64)`，再写非空等长有序 tuple
  `{request_index(u32), image_digest(32 bytes), authority_digest(32 bytes)}`；current
  attempt、state、两个 effect、phase、status、completion、reset-confirmation 和
  `recovery_required` 均排除；
- reset proof digest：`CMQ-RESET-PROOF-V1\0`，随后 `proof_key(string)`、
  `proof_id(u64)`、`batch_key(string)`、`batch_id(u64)`、`attempt_id(u64)`、
  `engine_instance_id(u64)`、`engine_incarnation(u64)`、
  `FUNCTION-IDENTITY-V1 isolated_identity`、`batch_digest(32 bytes)`，再写非空等长
  有序 tuple `{request_index(u32), image_digest(32 bytes), authority_digest(32 bytes),
  RECOVERY-OWNER-V1 recovery_owner}`。

“独立重算”是 request-owned graph 和 journal-owned graph 分别运行同一个冻结 encoder 与
同一个 FNV 实现，不是维护第二套 hash。recovery 先分别校验每张图的 item/batch/proof
carried digest，再比较两个 verified recomputation，最后比较每个完整 detached value；
digest match 永远不能单独授权 retry。binding canonicalization 必须先经
`snapshot_complete_nonfatal()` 和 `snapshot_identity_nonfatal()` 获得完整 detached 值并
验证 Function identity 一致。

### 4.5 `rdma_cmq_transport`

transport 接收 detached 64B SQE image、完整 DMA/Function authority 和 doorbell 描述；
它不理解 QPC/CQC/MR 等业务 body。它只理解 CMQ 公共 header 中完成匹配所必需的
index/wrap/owner/opcode echo，并把 opcode 当作不透明操作标识。

transport 不拥有外部 Host-memory、PCIe、mapping 或 binding；这些均为经 engine
验证后传入的非拥有引用/值快照。transport 不建立独立锁。

#### 4.5.1 transport 与 ledger 的 MMIO 边界

transport 调 doorbell scheduler 的 observed 入口时传入本次 batch 独占的、非拥有
`rdma_doorbell_submission_observer`。它只有一个同步且不可失败的回调：

```systemverilog
virtual class rdma_doorbell_submission_observer extends uvm_object;
  pure virtual function void before_mmio_maybe_visible();
endclass
```

scheduler 是通用组件，因此 observer 参数允许为 null：非 CMQ 调用和 legacy
`submit()` wrapper 传 null，此时不调用 hook，但仍返回完整 per-call effect/result。
CMQ transport 必须传入已在 `STAGED -> PENDING_EFFECT` 前完成分配并绑定 batch ID 的
非空 observer，不能在回调时创建。

scheduler 在所有 dependency write 和所需 DMA/MMIO barrier 成功后、进入 PCIe MMIO
调用前，对非空 observer 恰好调用一次。CMQ observer 只执行
`ledger.arm_batch_for_mmio_locked()`：安装预分配 index、推进 cursor，并把 record 变成
`PUBLISH_AMBIGUOUS`。因此不存在“MMIO 已可能可见，但 completion lookup owner 尚未
建立”的窗口。

回调发生时调用方仍持有 `engine_lock`，scheduler 持有对应 Function transport lock。
observer 不得重新取得任一锁、不得等待、不得分配、不得调用 Host-memory/PCIe/
manager/control-plane，也不得回调 scheduler。除这个窄化、不可失败的 arm hook 外，
scheduler、Host-memory 和 PCIe 不得回调 CMQ engine。

### 4.6 文件与 package 顺序

首批新增文件保持仓库现有平铺目录，不在同一轮同时迁移整个 codec 目录：

```text
src/model/rdma_submission_evidence.sv
src/model/rdma_cmq_execution_models.sv
src/core/rdma_cmq_snapshot_guard.sv
src/core/rdma_cmq_ring_math.sv
src/core/rdma_cmq_ledger.sv
src/core/rdma_cmq_transport.sv
```

通用 submission effect 位于 model 层，只定义不可变副作用阶段，不包含任何 engine
ledger。model package 的新增 include 顺序固定为：

```text
rdma_context_models.sv
    -> rdma_submission_evidence.sv
    -> rdma_cmq_engine_models.sv
    -> rdma_cmq_execution_models.sv
    -> rdma_control_plane_models.sv
```

core package 保持现有前序文件不动，从 scheduler 开始的相关顺序固定为：

```text
rdma_doorbell_scheduler.sv
    -> rdma_queue_data_engine.sv / thin SQ-RQ-CQ-EQ facade
    -> rdma_cmq_port.sv
    -> rdma_queue_lifecycle_executor.sv
    -> rdma_qp_lifecycle_executor.sv
    -> rdma_control_plane.sv
    -> rdma_cmq_snapshot_guard.sv
    -> rdma_cmq_ring_math.sv
    -> rdma_cmq_ledger.sv
    -> rdma_cmq_transport.sv
    -> rdma_cmq_engine.sv
    -> rdma_cmq_engine_port_adapter.sv
```

每个新文件只能依赖其前方已经可见的类型。`rdma_cmq_port` 只消费 model execution
result，不反向依赖 engine；adapter 必须同时位于 port 和 engine 之后。即使 helper
当前不依赖 lifecycle/control-plane，也保持上述位置，避免首批顺手重排既有 package。
这些普通 class/model 文件全部使用 `.sv`，不以 `.svh` 规避编译顺序。

新增 result/journal/value class 必须登记 UVM factory，并提供可验证的 detached value
边界：handle、status、image、DMA context 和嵌套 item 都不能把源对象的可变引用泄漏
出去；同一源图内部有意共享的 ticket/status/recovery-owner 节点在快照内保持一致，但与
源图隔离。包含 polymorphic command body 或 completion payload 的 class 不得声称通用
UVM `copy()/clone()/do_copy()` 是 production nonfatal deep-copy boundary，因为这些入口
没有 profile 参数和 status 返回值。production journal/result/query/recovery 必须使用
显式 status-returning typed snapshot seam；leaf value 可实现 direct-new `do_copy()`，但
控制路径不依赖它。测试在返回后修改 command、mapping、Function handle、status 和嵌套
image，已发布 result 与 journal record 必须保持不变。

opcode capability 首先在现有 `rdma_cmq_codecs.sv` 内扩展 registry。待能力和测试稳定后，
再按 common envelope、业务域 body、opcode contract 分文件；不能在同一提交中既改变
mask/capability 又移动所有 codec。

## 5. 每次调用独立的提交证据

### 5.1 证据状态

副作用路径使用单调阶段，而不是从 `rdma_status.code` 推断；
`PRE_SUBMIT_REJECTED` 是未进入副作用路径的终止分支，不与后续阶段互转：

```systemverilog
typedef enum logic [2:0] {
  RDMA_SUBMIT_EFFECT_UNOBSERVED,
  RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED,
  RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE,
  RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN,
  RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED,
  RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE,
  RDMA_SUBMIT_EFFECT_MMIO_VISIBLE
} rdma_submission_effect_e;
```

这里有意使用四态 `logic` 基类型：持久化及恢复路径可见的 evidence 必须拒绝 X/Z，
不能把未知值静默转换为 `UNOBSERVED`。

跨引擎只共享这个副作用词汇和纯值校验，不共享 command、ticket、completion 或
recovery ledger。每个 engine 仍定义自己的 execution result 和状态机。

语义如下：

- `UNOBSERVED`：兼容实现没有提供可靠阶段，只能保守恢复。
- `PRE_SUBMIT_REJECTED`：未调用任何 Host-memory 写、barrier 或 MMIO；唯一可直接
  映射为 hardware presence `ABSENT` 的状态。
- `HOST_MEMORY_MAYBE_VISIBLE`：至少进入一次 dependency write；即使后端返回错误，
  也不得声称无副作用。
- `HOST_MEMORY_WRITTEN`：所有声明的 dependency write 已明确成功，但 DMA ordering
  policy 尚未满足。dependency 数量为零时，该阶段是逻辑上的空集合成功，result 中的
  `dependency_count == 0` 明确表示没有 Host-memory byte 被写。
- `HOST_MEMORY_ORDERED`：所有 dependency write 已完成，并且声明的 DMA ordering
  policy 已满足；需要 DMA barrier 时以 barrier 成功为准，不需要时从
  `HOST_MEMORY_WRITTEN` 立即单调推进到本阶段。
- `MMIO_MAYBE_VISIBLE`：已经进入 MMIO 调用，返回错误/超时也可能已产生写入。
- `MMIO_VISIBLE`：MMIO 调用明确成功；命令终态仍由 completion/timeout 决定。

CMQ completion 生命周期与通用 transport 阶段正交，使用独立枚举：

```systemverilog
typedef enum logic [2:0] {
  RDMA_CMQ_COMPLETION_NONE,
  RDMA_CMQ_COMPLETION_PENDING,
  RDMA_CMQ_COMPLETION_TERMINAL,
  RDMA_CMQ_COMPLETION_TIMEOUT,
  RDMA_CMQ_COMPLETION_RESET_CANCELLED,
  RDMA_CMQ_COMPLETION_DIAGNOSTIC_ONLY,
  RDMA_CMQ_COMPLETION_UNOBSERVED
} rdma_cmq_completion_phase_e;
```

前六个编码保持不变，`UNOBSERVED` 追加为 wrapper 无可信 lifecycle evidence 时的独立
保守状态；它不能与 `NONE` 混同。`NONE` 只用于已正面确认不存在 completion 的路径，
包括 pre-engine rejection 和尚未 arm 的 Host-visible journal state。所有 phase 在状态
索引前拒绝 X/Z、`3'b111` spare。该阶段由 engine 的实际状态迁移设置，不能用
`completion != null` 或 status code 反推。

### 5.2 execution result

新增 `rdma_cmq_execution_result` 值对象，至少持有：

- detached `ticket`、`completion`、operation `status` 和
  `observation_status`；
- detached command identity、与 journal item 相同的 canonical detached recovery
  owner，以及经 engine 验证的 detached `rdma_dma_request_context`；
- 累计 `rdma_submission_effect_e submission_effect` 和只描述本次调用的
  `attempt_effect`；
- `rdma_cmq_completion_phase_e completion_phase`；
- batch key、batch ID、current attempt ID 和 `recovery_required`。

所有 observed 入口的 result 都必须非空。`UNOBSERVED` 只表示 effect 无法精确取得，
不表示 status、identity 或已有 ticket 可以丢失。command 通过 engine admission 并进入
journal 后，即使后续失败也必须返回 detached ticket。只有 adapter/engine/scheduler 在
任何外部 I/O 前确定拒绝时，ticket 与 DMA context 才允许为空；另一个唯一例外是 legacy
wrapper 的手工 reconcile shape：`completion_phase=UNOBSERVED`、
`recovery_required=1`、batch/attempt ID 均为零，此时 DMA context 可为空且绝不能授权
engine retry。

每个 `rdma_cmq_execution_result.status`、`observation_status`、
`rdma_doorbell_submission_result.status` 和 `batch_status` 都必须是非空 detached value，
包括 snapshot/factory/null-adapter/lock-deadline 失败。任何拥有 status 的新 value 构造器
都必须 direct-construct 独立 status 节点，并把 category/code/severity/hardware/source
identity/message 初始化为显式 fail-closed shape：category `RDMA_STATUS_STATE`、code
`RDMA_SC_INVALID_STATE`、severity `RDMA_SEVERITY_ERROR`、hardware code 为零且 invalid、
source engine `RDMA_ENGINE_NONE`、全部 identity 为零、retryable 为零，并使用稳定非空的
class-specific message；不得继承 `rdma_status::new()` 的默认 OK。operation `status` 表示
command/legacy operation 的原始
结果；`observation_status` 只表示 observed envelope 及全部 evidence 是否忠实捕获。两者
不能 alias，observation failure 不得覆盖已经有效的 operation result。

production observation 表固定如下：

生产调用方向冻结为 `adapter.execute() -> adapter.execute_observed() ->
engine.execute_observed() -> engine.submit_observed()`。submit 返回后，engine
在 `engine_lock` 下按完整 ticket/batch/attempt/Function incarnation 重读 retained
journal；只有 `PUBLISH_AMBIGUOUS/PENDING` 或 `PUBLISH_CONFIRMED/PENDING` 的已 arm
项允许一次 `wait_for()`。Host-visible/NONE 立即返回，终态/timeout/late/reset 均从
journal retained completion 快照返回；STAGED/PENDING_EFFECT 直接报告 observation
error 且不做 I/O。ticket presence、status code 和 FIFO 都不是 wait authority。

| production path | operation `status` | `observation_status` |
| --- | --- | --- |
| 可靠 success 或可靠 command/hardware failure | 精确 operation result | `OK` |
| 可靠 timeout、reset cancellation 或 late diagnostic | 精确 lifecycle result | `OK` |
| delegation 后 null/malformed result、status、snapshot 或 observed envelope | 保留任何有效 operation result，否则保持 fail-closed `INVALID_STATE` | `INVALID_STATE` |
| observer/effect/state contradiction | 保留 scheduler/operation status | `INVALID_STATE` |

payload snapshot failure 同样只使 `observation_status` 失败，不能覆盖有效 operation
status。observation failure 不改变任一 effect，不伪造 phase；后续 completion/timeout/
late/reset lifecycle update 可更新 status、phase 和 recovery state，但不得重写
`submission_effect` 或 `attempt_effect`。

`batch_status` 只描述 batch orchestration，不汇总或覆盖 item status；presence 与 recovery
只能读取对应 item 的 status/effect/journal identity，不能由 batch status 推断。

| batch 输入/结果 | item result 规则 | batch status 规则 |
| --- | --- | --- |
| commands 为空 | results 为空，不创建 journal，不调用 scheduler | `OK` |
| 全部 item 在本地独立拒绝 | 每项非空失败 status、`PRE_SUBMIT_REJECTED`、ticket null | `OK`，表示遍历完成 |
| 部分 item 独立拒绝、部分可提交 | 拒绝项保持自身失败；可提交项共享 batch ID/effect | orchestration 成功则 `OK` |
| journal/transport 的 batch-level 失败 | 已进入 journal 的 item 保留各自 ticket/effect/owner；预拒绝项不被覆盖 | 返回该 orchestration failure |

这张表冻结现有“有效 item 可压缩成一次 doorbell、无效 item 保持逐项错误”的兼容语义，
但不允许压缩 results 数组或把 batch failure 写回并覆盖已经确定的 item-level 拒绝原因。

result 只属于本次调用，禁止放在 adapter 的 `last_*` 成员中。并发 Function 或同一
Function 的相邻调用不能覆盖彼此证据。命令在第一次可能的外部 I/O 前进入 submission
journal；effect 随 slot/ticket record 持久保存，供 timeout、reset、cancel、reconcile
和 late completion 继续投影。

reset 的 completion/proof 输出同样是本次调用的 detached projection：
`reset_observed()` 必须先完成 mutation-free staging 和
`validate_failure_atomic_release()`，再执行 confirmed release 与 allocation-free commit。
release 返回 null/non-OK 时，outputs 清空且 result/status 非空；journal、fence、runtime
authority、FIFO、counter 和 engine state 逐值不变。成功 commit 后旧 backing/fence 已经
释放，允许独立 replacement prepare；它不等待或要求 replacement mapping 等于旧 mapping。
`AWAITING_REBIND` proof 只表示旧 backing 已隔离，`READY` 还要求同一 immutable Function
的严格更大 reset epoch。`CONFIRM_RESET_ISOLATION` 只验证 journal-resident READY proof、
完整 digest/tuple 和 owner permission，并把 concrete-owner rows 标记 resolved；它不
发起 reset、不释放 backing、不清 fence、不调用 scheduler/Host-memory/PCIe。精确
`LEGACY_UNMIGRATED` sentinel 在 release commit 立即得到 `recovery_required=0`，而
concrete owner 在 workflow confirmation 前保持 `recovery_required=1`。

reconcile 的返回必须遵守 §4.4.1 的只读表：terminal/timeout/late/reset completion
来自 retained journal，重复查询返回值相等但图分离的 snapshot；unarmed fenced ticket
不产生 scheduler/MMIO；旧 epoch reset ticket 在新 incarnation ACTIVE 后仍可读取旧证据。
FIFO 只负责 delivery order，不能成为 completion 或 recovery authority。

显式 `rdma_cmq_nonfatal_snapshot_context` 由 direct `new` 构造，不登记 factory。每个方法
入口先清空 output/reason，只用 direct construction 与显式 scalar/byte copy，绝不调用
fatal clone helper、generic `copy/clone/do_copy` 或 `type_id::create`。required null status
返回稳定非空 reason；optional null ticket 和 null completion 成功返回 null snapshot 与空
reason。context 以 source object identity canonicalize status、ticket 和 frozen recovery
owner，因此 source graph 中 outer 与 completion 共用的节点在 detached graph 中仍共用
一个新节点，并且不 alias source。completion shell 的 polymorphic payload 由 profile
typed hook 先行 detached；source payload 非空时，null、source self-alias 或其他未 detached
payload 都必须非 fatal 地拒绝且不发布 partial shell。

observed 接口固定为：

```systemverilog
virtual class rdma_cmq_port extends uvm_object;
  virtual task execute_observed(
    input rdma_cmq_command_desc command,
    output rdma_cmq_execution_result result
  );
endclass

class rdma_cmq_engine extends uvm_object;
  task submit_batch_observed(
    input rdma_cmq_command_desc commands[],
    output rdma_cmq_execution_result results[],
    output rdma_status batch_status
  );

  task submit_observed(
    input rdma_cmq_command_desc command,
    output rdma_cmq_execution_result result
  );

  task execute_observed(
    input rdma_cmq_command_desc command,
    output rdma_cmq_execution_result result
  );
endclass

class rdma_cmq_transport extends uvm_object;
  task submit_observed(
    input rdma_function_binding binding,
    input rdma_doorbell_desc desc,
    input rdma_doorbell_submission_observer observer,
    output rdma_doorbell_submission_result result
  );
endclass

class rdma_doorbell_scheduler extends uvm_object;
  task submit_observed(
    input rdma_function_binding binding,
    input rdma_doorbell_desc desc,
    input rdma_doorbell_submission_observer observer,
    output rdma_doorbell_submission_result result
  );
endclass
```

`rdma_doorbell_submission_result` 至少包含 detached doorbell result、status、
submission effect、dependency count 和 `before_mmio_maybe_visible()` 是否已调用。
无论 snapshot、preflight、Function-lock deadline、dependency write、barrier 或 MMIO
在哪一处失败，production scheduler 都必须返回本次调用独占的 detached result。

调用方向只能是：

```text
port.execute_observed
    -> production adapter.execute_observed
        -> engine.execute_observed
            -> engine.submit_observed
                -> engine.submit_batch_observed
                    -> transport.submit_observed
                        -> scheduler.submit_observed
                            -> observer.before_mmio_maybe_visible
            -> engine.wait_for / reconcile
```

engine 从 scheduler result 原样投影 effect，adapter 和 control plane 都不得根据 status
code 重新推断。`submit_batch_observed()` 的 results 数组与 commands 数组等长同序；
无效 item 也返回独立失败 result，不能通过数组压缩改变调用方索引。共享 doorbell 只
允许共享不可变 batch ID/effect，不允许共享可变 result、ticket 或 status。

为保持兼容，`rdma_cmq_port` 新增 `execute_observed()`：基类默认调用旧 `execute()`
并返回 `attempt_effect=submission_effect=UNOBSERVED`、
`completion_phase=UNOBSERVED`、`recovery_required=1`、零 batch/attempt ID 的手工 reconcile
shape；生产 adapter 覆盖它并发布精确 result。legacy output 能可靠 detached 时
`observation_status=OK`；捕获失败时保留任何有效 operation `status`，并把
`observation_status` 设为 `INVALID_STATE`。现有 `execute()` 暂时保留，由兼容调用方继续
使用。生产恢复调用方全部迁移后，
`last_execute_definitive_no_submit()` 仅保留为弃用兼容入口并始终按保守语义处理。

兼容包装的方向固定为：

```text
legacy port subclass:
    base execute_observed() -> legacy execute()
    -> result.attempt_effect/submission_effect = UNOBSERVED
    -> result.completion_phase = UNOBSERVED, recovery_required = 1

production adapter:
    legacy execute() -> production execute_observed()
    -> 只投影 ticket/completion/status

legacy engine/scheduler entry:
    legacy entry -> 对应 observed entry
    -> 只投影旧 outputs
```

production adapter 必须 override `execute_observed()`；其 `execute()` 不能被基类默认
`execute_observed()` 路径调用。每种 legacy mock/subclass 和 production adapter 都有
递归探针，确保两个包装方向不会形成 `execute() <-> execute_observed()` 循环。

doorbell scheduler 同样增加 observed 入口，返回本次调用独占的
`rdma_doorbell_submission_result`（doorbell result、submission effect、status），
并在实际阶段前更新证据：

```text
preflight fail
    -> PRE_SUBMIT_REJECTED

before first host_mem.write
    -> HOST_MEMORY_MAYBE_VISIBLE

all dependency writes succeed
    -> HOST_MEMORY_WRITTEN

required DMA barrier succeeds
    -> HOST_MEMORY_ORDERED

before PCIe MMIO call
    -> MMIO_MAYBE_VISIBLE

MMIO succeeds
    -> MMIO_VISIBLE
```

完整 dependency-count × barrier-policy × failure-point 语义固定如下；实现和测试不得
各自解释：

| dependency 数量 | barrier policy | 失败/边界 | 返回 effect |
| --- | --- | --- | --- |
| 任意 | 任意 | scheduler preflight/Function-lock deadline，未调用外部 I/O | `PRE_SUBMIT_REJECTED` |
| 大于 0 | 任意 | 第一笔或后续 Host-memory write 已进入并失败 | `HOST_MEMORY_MAYBE_VISIBLE` |
| 大于 0 | 任意 | 全部 dependency write 成功 | `HOST_MEMORY_WRITTEN`，随后按 policy 推进 |
| 0 | 任意 | preflight 成功，无 dependency 可写 | `HOST_MEMORY_WRITTEN`，`dependency_count=0` |
| 任意 | `DMA` / `DMA_MMIO` | DMA barrier 失败 | `HOST_MEMORY_WRITTEN` |
| 任意 | `DMA` / `DMA_MMIO` | DMA barrier 成功 | `HOST_MEMORY_ORDERED` |
| 任意 | `NONE` / `MMIO` | 无需 DMA barrier | 立即推进为 `HOST_MEMORY_ORDERED` |
| 任意 | `MMIO` / `DMA_MMIO` | MMIO barrier 失败 | `HOST_MEMORY_ORDERED` |
| 任意 | `NONE` / `DMA` | 无需 MMIO barrier | effect 不变，进入 MMIO arm |
| 任意 | 任意 | observer 已 arm，PCIe MMIO 即将/已经进入但返回失败或超时 | `MMIO_MAYBE_VISIBLE` |
| 任意 | 任意 | PCIe MMIO 明确成功 | `MMIO_VISIBLE` |

barrier 本身不是“命令已到硬件”的证明；但只要已经调用 barrier，就不再允许返回
`PRE_SUBMIT_REJECTED`。presence 仍只有该终止值能映射为 `ABSENT`，其余阶段保持保守。

上层 presence 映射只允许显式 `PRE_SUBMIT_REJECTED -> ABSENT`；其余失败保持
`UNKNOWN` 或按已观察 completion 得到的终态处理。

阶段测试矩阵至少包含：

| 注入点 | 期望 submission_effect | presence 结论 |
| --- | --- | --- |
| adapter/engine/scheduler preflight 拒绝且无 I/O | `PRE_SUBMIT_REJECTED` | `ABSENT` |
| 第一笔或后续 dependency write 失败 | `HOST_MEMORY_MAYBE_VISIBLE` | `UNKNOWN` |
| 全部 dependency write 成功、DMA barrier 失败 | `HOST_MEMORY_WRITTEN` | `UNKNOWN` |
| DMA 已有序、MMIO barrier 失败 | `HOST_MEMORY_ORDERED` | `UNKNOWN` |
| PCIe MMIO 返回失败或超时 | `MMIO_MAYBE_VISIBLE` | `UNKNOWN` |
| PCIe MMIO 明确成功 | `MMIO_VISIBLE` | 由 completion/timeout 决定 |
| legacy adapter 无 observed 能力 | `UNOBSERVED` | `UNKNOWN` |

还必须覆盖零 dependency、不同 barrier policy、两个 Function 并发、同一 Function
跨 generation、timeout/reset/late completion、malformed CQE 和 codec 返回 null；
所有 result 都必须保持 command/ticket/authority 对应关系，不得串线。

兼容测试还要逐字段比较旧 `execute()` 的 ticket/completion/status（包括 message），
验证 legacy subclass 得到 `UNOBSERVED`，并保证原 probe 可以继续编译。result 返回后
修改调用方 command、Function handle 或 mapping snapshot，不得改变已发布证据。

## 6. opcode contract 的演进

当前并非只有一张 opcode 表：`rdma_cmq_codec_registry` 持有 descriptor、request/response
mask 与能力，`rdma_hw_cmq_body_registry` 还独立持有 `registered[256]`、
`input_kinds[256]` 和 `body_masks[256][8]`。目标是把二者收敛为一份 descriptor contract，
但不能先假设它们已经一致。`rdma_defs.svh` 继续只负责 opcode 数值和固定硬件 mask。

descriptor 增加相互独立的能力：

```text
registered
request_encodable
response_decodable
request_body_kind
response_payload_kind
generation_policy
ecode_policy
```

兼容 `is_supported()` 在迁移期保留当前行为：只有 descriptor 满足现有完整 contract
校验（当前等价于 request/response 均允许且 descriptor `valid()`）时才返回真。不得把
同名 API 静默改成“已注册”，否则旧调用方会开始提交只有名字、没有完整 codec 的
opcode。新代码不再用这个含混接口做能力判断，而使用：

- `is_registered()`：驱动表中存在该 opcode；
- `is_request_encodable()`：模型能产生完整合法 SQE；
- `is_response_decodable()`：模型能消费该 opcode 的合法 CQE；
- `lookup_contract()`：返回包含字段 ownership 与 codec 能力的 detached 描述符。

每个 opcode 必须有独立 contract；真正相同的 wire layout 可以复用底层 field codec，
但不能把多个 opcode 的能力、completion payload 或 generation 规则合并成模糊分支。

双表合并按以下顺序实施：

1. 对全部 256 个 opcode 生成 characterization：descriptor 是否存在、旧
   `is_supported()`、request/response allowed、request/response mask，以及 body registry
   的 registered/input kind/body mask；任何差异先分类，不自动选择一侧覆盖另一侧。
2. descriptor 接管 request body kind、response payload kind、body mask 和三项 capability；
   所有字段必须来自同一 ownership/oracle contract。
3. `rdma_hw_cmq_body_registry` 暂时保留为 descriptor-backed adapter，不再持有可独立
   修改的数组；双读期对 256 项逐字段比较，差异立即失败。
4. 编码器、profile、测试和 golden reader 全部迁移到 `lookup_contract()` 后，才允许在
   独立提交删除旧 body registry adapter。

不得新建第三张手写 opcode 表。`field_ownership.tsv` 和 CMQ capability artifact 是
驱动证据及机器检查输入，不是运行时 registry；checker 必须验证它们生成/约束出的
descriptor 与 C oracle 一致。

OCC 的处理分两步：先用真实向量证明每个 opcode 的 response payload，再同时登记
`response_decodable`、mask 和 payload codec。不得只添加当前不可达的 mask 分支。

## 7. 其他核心引擎的后续拆分

其他 engine 采用同一模板：先建契约和 characterization tests，再提取无状态/只读服务，
最后移动共享 ledger。每个对象单独成规格、计划和提交序列。

后续立项登记如下，当前状态全部为 `PENDING`；CMQ 的实现 PR 不得顺带完成其中任一项：

| 独立项目 | 实施前冻结 | 唯一状态/锁 owner | 第一项可移动职责 | 本项目不得同时修改 | characterization gate |
| --- | --- | --- | --- | --- | --- |
| queue-runtime contract/internal split | cursor、reservation、pending marker、`copy_ring_state()` | runtime semaphore、cursor/slot/recovery ledger | clone/value compare、纯 ring math | queue-data 状态机、lifecycle backing | runtime unit + queue-data 互操作 |
| queue-data engine | attachment、publish/consume、resize/recovery | facade resize 权威；ring 状态仍归 runtime | device publisher 或 host WQE poster | runtime ledger、queue lifecycle owner | queue-data core + event/resize/recovery |
| resource-manager | ID/registry transition、journal、release | manager state；同 Function 串行化归 control plane | 纯值投影/比较 | 新 semaphore、control-plane lock table | resource-manager unit + recovery |
| control-plane front door | per-Function lock、txn ID、presence/compensation | control-plane lock table/Function lock | 单资源 orchestrator | queue/QP executor 内部拆分 | PD/MR/queue/QP workflow |
| queue-lifecycle executor | `*_locked` 前置条件、plan/backing/context/recovery | control-plane Function lock；manager 提交资源状态 | backing planner/context builder | queue-data/runtime 内部状态 | queue lifecycle + failure injection |
| QP-lifecycle executor | `*_locked` 前置条件、QPC/CMQ/recovery | control-plane Function lock；manager 提交资源状态 | QPC/command builder | queue lifecycle、control-plane lock table | QP lifecycle + rollback/reconcile |

每一行开始实施前必须另有批准的 spec、implementation plan 和独立提交边界。SQ/RQ/CQ/EQ
继续只是兼容 facade；CEQ/AEQ 是 generic device-produced event-ring kind；CQC 是
context/codec/lifecycle contract。三者均不另造独立 engine，也不能因为名字相似而复制
CMQ 的 ledger 或 recovery 状态机。

### 7.1 `rdma_queue_data_engine`

候选职责边界：

- attachment/QP-link registry；
- host WQE poster（SQ/RQ/SRQ encode、backing、producer doorbell）；
- device publisher（CQE/CEQE/AEQE reservation、encode、commit）；
- CQ completion consumer 与 WQE release；
- CEQ/AEQ event consumer/router；
- CQ resize coordinator；
- queue recovery coordinator。

原 engine 保持 facade，并继续持有 engine 级 resize 串行化权威；单个 ring 的 cursor、
reservation 和 recovery 锁仍归 `rdma_queue_runtime`。不得让 publisher/consumer
各复制一套 attachment 或 cursor。

queue plan、backing create/destroy 和 mapping/HMC 释放继续归
`rdma_queue_lifecycle_executor`；queue-data 只保存 attachment/runtime 的借用引用，
不能在拆分时把生命周期所有权吸收到 publisher 或 recovery helper。

实施前先冻结 runtime 的 pending marker、consumer release gate、route/epoch 与
`copy_ring_state()` 契约。queue-data 的 poll/recovery/resize 依赖这些状态和
CQ runtime → WQ runtime 的锁序，不能在同一提交中同时重命名 runtime 状态并移动调用方。

### 7.2 `rdma_queue_runtime`

先提取 clone/value comparison 和纯 ring math，再按 host slot ledger、device producer
reservation、recovery journal 的顺序评估协作者。
runtime 始终保留唯一 semaphore、cursor、occupancy、reservation 和 pending evidence
所有权。协作者只接受锁内快照，不能各自加锁。

### 7.3 `rdma_resource_manager`

先提取纯值投影/比较，再分离 ID allocator、registry 索引和 recovery journal。
manager facade 继续作为资源状态迁移与 publication 的唯一 owner；QP/queue recovery
服务不能直接修改 registry，只能提交经过校验的 transition。

manager 当前没有内部 semaphore，其调用串行化来自 control plane 的 per-Function lock。
重构不得“补”一把 manager 锁，否则会改变现有锁序甚至与 `*_locked` executor 形成死锁。

### 7.4 `rdma_control_plane` 与 lifecycle executor

control plane 保留 Function 级串行化和事务 ID，按资源工作流拆出 PD/MR/queue/QP
orchestrator。lifecycle executor 按 backing planner、context builder、CMQ command builder
和 recovery coordinator 切分，但资源状态只由 manager 提交。

QP 和 queue lifecycle 分别实施；不能因为错误处理形态相似就共享一套可变 recovery
对象。可共享的只能是无状态 evidence/value helper。

QP lifecycle executor 本身不取得 Function 锁，`create_locked()`、`modify_locked()`、
`destroy_locked()` 和 `recover_locked()` 均依赖 control plane 已持锁这一前置条件。
拆出的 backing/context/command helper 必须保持同一前置条件，不得内部再次加锁。

### 7.5 跨对象锁序

拆分前用测试和设计注释冻结真实组合锁链。control-plane lock 和 scheduler transport lock
虽然都以 Function 为 key，但不是同一把锁；不得因名称相似省略其中一层：

```text
control-plane lock_table_guard
    （只建立/查找 lock table 和事务号，取得 per-Function lock 前必须释放）

control-plane per-Function lock
    -> manager transition / lifecycle executor *_locked
        ->（工作流需要 CMQ 时）CMQ engine_lock
            -> doorbell scheduler Function transport lock

queue-data resize_lock
    -> CQ runtime lock
        -> routed SQ/RQ/SRQ runtime lock
```

禁止 WQ runtime → CQ runtime 的反向获取；禁止 executor 在 `*_locked` 入口内部再次
取得 Function lock；禁止新协作者为了方便增加与 facade 状态重叠的 semaphore。
queue-data 的 resize lock 只保护 attachment/resize/unclaimed-recovery 索引及对应原子
切换，不能扩张为覆盖任意长时间等待的全局 engine 锁。

CMQ 首批保持当前 `engine_lock -> scheduler Function transport lock` 的持锁语义；scheduler
等待上限是本 command/batch 的绝对 deadline。`wait_for()` 的 completion 等待窗口必须
释放 engine lock，返回后重新取得并以 ticket/generation/reset epoch 复核。若未来希望
在调用 scheduler 前释放 engine lock，必须另开并发状态机规格，不能在提取 transport
时顺手改变。

doorbell scheduler 的 transport lock 以 immutable Function identity
（`function_uid + global_function_id`）为 key，跨 generation/rebind 串行；它不是
control-plane per-Function lock。旧 generation 持锁时，新 generation 不得越过它发
doorbell。scheduler、Host-memory 和 PCIe adapter 不得在持有自身锁时重入 control
plane、manager 或 CMQ engine。唯一例外是 §4.5.1 的
`before_mmio_maybe_visible()`：它只调用已持锁的 ledger arm，不取得任何锁或调用外部
服务。engine/observer 也不得从该回调反向取得 engine lock 或 scheduler lock。

manager 没有内部 semaphore；生产并发前置条件仍是同一 Function 由 control-plane
per-Function lock 串行化，直接 manager 单测仅允许单线程，除非后续独立规格改变契约。

锁测试至少覆盖 scheduler Function-lock contention、Host-memory/PCIe barrier 阻塞、
observer 恰好一次、恶意 re-entry/rebind，以及 deadline/reset 并发；断言无反向取锁、
无无限等待，且 ticket/journal/epoch 不串线。

### 7.6 测试 seam 兼容

现有测试通过 protected probe 和 virtual fault seam 注入失败，包括 queue-data 的
doorbell/consumer/recovery seam、runtime 的 factory/retry probe、resource manager 的
ID/registry/recovery probe、control plane 的锁表/事务号 probe，以及 QP executor 的
command/release seam。移动内部字段前先把这些观察收敛成兼容访问器；检查用例继续调用
原签名，只有 probe 适配层改为委托新组件。不得为了拆文件删除故障注入能力或让测试
直接穿透多个新组件的私有字段。

CMQ 首批的 seam 映射必须先于字段移动落地：

| 现有 probe / seam | 拆分后 owner | 兼容方式 | 禁止行为 |
| --- | --- | --- | --- |
| `seed_ring_counters` 及 publish/retire/CQ consume 查询 | ledger | engine protected wrapper 委托 test-only compatibility view | 测试直接访问 ledger 数组 |
| token incarnation、slot/entry registry 查询 | ledger | 保留原 probe 签名，返回 detached snapshot | 返回 ledger 内部可变 record |
| terminal/late FIFO seed 与 count | ledger | facade wrapper 委托 terminal diagnostic API | 为测试复制第二套 FIFO |
| `build_runtime_desc` / `publish_runtime_snapshot` override | snapshot/transport coordinator | 暂保留 engine protected virtual wrapper，再内部委托 | 一次性删除 override seam |
| profile/codec fault injection | existing profile/registry | 保持注入边界，只替换其后 contract lookup | 测试修改全局静态表绕过 seal |
| Host-memory、DMA/MMIO barrier、scheduler block/mock | transport/scheduler adapter | 保持现有 adapter mock，并增加 per-call observed result | adapter 级 `last_*` 共享状态 |
| `last_execute_definitive_no_submit` 相关 mock | port execution result | 新增 result-based substitute；旧函数迁移后恒保守 | 由 status code 伪造 effect |

base `execute_observed() -> legacy execute()` 与 production
`execute() -> execute_observed()` 必须分别有 subclass/mock 编译和运行测试；任何类都
不能同时继承两个默认包装而产生递归。probe 适配只改变一处，其余 check 用例签名保持
不变。

Phase 1A 中 production legacy `execute()` 仍是 `last_execute_no_submit_proven` 的唯一
写者：进入时清零，调用 observed override 一次后仅在初始
`PRE_SUBMIT_REJECTED` 且 batch/attempt 为零、无 retained journal、`recovery_required=0`
时置一。observed API、engine、wait/reconcile 与 retained snapshots 不读写该弃用成员；
三个 Phase 1B consumer 完成迁移前 accessor 保留以维持 ABI。

`execute_observed()` 的决策只读取 submit 返回后锁内重查的 journal item：
`PUBLISH_AMBIGUOUS/PUBLISH_CONFIRMED + PENDING` 才允许一次 `wait_for()`；
`HOST_VISIBLE_NOT_PUBLISHED/NONE` 立即返回；COMPLETED、TIMEOUT、LATE 和 RESET
行从 journal-owned snapshot 返回，即使 delivery FIFO 已被消费。STAGED、PENDING_EFFECT、
缺失 authority、state/phase/effect 矛盾或 snapshot 失败必须保留 operation status/effects，
并独立设置 `observation_status=INVALID_STATE`、`UNOBSERVED` phase/effect 与
`recovery_required=1`（真实零 identity PRE_SUBMIT_REJECTED/NONE 除外）。

## 8. 可读性与排版契约

本轮采用当前 `AGENTS.md`，并把用户认可的 Claude 风格具体化为以下规则：

这些规则同样适用于 production、model、codec、adapter、test、probe 和 mock；constructor、
accessor、compare/clone helper 也不例外。触及一个源文件时先从文件头复审整份文件的
层次、职责、依赖、owner/lifetime 和注释真实性，但只格式化本次职责直接涉及的区域；
其他历史排版放在独立 cleanup 提交，兼顾全文件审阅与低噪声 diff。

1. 文件头必须写清层次、职责、主要依赖、所有权和生命周期。
2. 每个 function/task 紧邻三段准确中文说明：功能、输入输出及副作用、失败边界。
3. 注释解释设计原因、状态所有权和错误选择，不使用“执行职责逻辑”一类模板句。
4. 声明区、输出初始化、校验、staging、外部副作用、commit、recovery 之间各留空行。
5. 一个语句只承担一个动作；禁止同一行连续初始化多个字段或写多个 `return`/调用。
6. 长参数列表逐项换行；长条件按语义分组，复杂 `inside` 集合抽成具名 predicate。
7. 多语句 `case`/循环分支使用 `begin/end`；错误分支保持视觉上独立。
8. 注释先于对应逻辑块，代码完成后同步复审，禁止用大量逐行翻译淹没关键约束。
9. 只整理本次职责抽取直接触及的区域；全文件纯排版另开提交。
10. 不以硬性行数替代设计，但单个方法无法在一屏内说明完整事务阶段时必须评估拆分。
11. 新增/修改行以 100 列为软上限；硬件符号等不可拆文本允许例外，但须人工审查。
12. 风险有先后顺序的状态映射使用显式 `if/else` 或小型 `case`，不用嵌套三元表达式。
13. `case` 必须有明确 `default`；默认行为是拒绝、零 mask 还是 opaque 保留要直接写出。

以下形态不再接受：

```systemverilog
manager = null; binding = null; host_mem = null; configured = 1'b0;
if (!status.ok()) return status;
```

推荐形态为：

```systemverilog
manager = null;
binding = null;
host_mem = null;
configured = 1'b0;

if (!status.ok())
  return status;
```

功能提交的审查同时检查 touched methods 的完整注释和排版，但不顺手重排无关方法。
样式门禁只检查本次新增/修改的 `.sv` 行，至少覆盖 `git diff --check`、尾空格、
一行多语句、行宽和函数三段注释邻接；历史长行不阻断当前功能提交。实施阶段增加一个
轻量 diff-aware checker，拒绝新增的 `a = ...; b = ...;`、单行多调用/多 `return` 和缺失
紧邻三段中文说明；复杂条件按 authority、geometry、state 分组后再检查。checker 不能
自动重排代码，也不能替代 reviewer 对注释与实现是否一致的判断。

## 9. 实施顺序与提交边界

### 阶段 0：恢复可信门禁

1. 修复 frozen ABI 校验：不再硬编码早于 ABI 文件诞生的 commit，改用受版本控制的
   SHA-256 manifest 或显式 baseline 更新流程。
2. 增加 driver archive lock、C oracle、field ownership/capability checker 和 CMQ gate
   manifest；缺 archive、hash、source anchor 或 oracle 时硬失败。
3. 对齐 README 与 `sim/Makefile` 的 host_mem pin。
4. 从跨机同步中排除 `.worktrees/`、`__pycache__/` 和其他非输入目录。
5. 将外部依赖 pin 扩展到可验证 commit/hash，而不只检查目录存在。
6. 明文凭据轮换与历史处置独立执行；未获破坏性历史重写授权前不得强推。

### 阶段 1A：CMQ per-call evidence 与 batch journal

1. 先为单 command 与 batch 的第一笔、中间笔、最后一笔 dependency write、DMA/MMIO
   barrier、MMIO timeout/success 编写失败测试；断言已可能受影响的 record/ticket/epoch/
   effect/recovery owner 不丢失，并覆盖同 Function 不同 MR/QP/queue owner 的混合 batch。
2. 在不拆 engine 文件的前提下建立 scheduler → transport facade → engine → production
   adapter 的 observed 调用链、nullable MMIO observer、batch submission journal、fence
   和 `recover_submission_observed()`。
3. 保留 legacy 包装并逐字段比较 ticket/completion/status/message；验证 legacy subclass
   为 `UNOBSERVED`，production adapter 不发生递归或并发串证据。
4. 为 deadline TIMEOUT、reset/FLR、late completion 和 submission fence 补定向测试。
   覆盖 ID overflow、retry 前 authority/hash 漂移、ambiguous 禁止 retry 和 reset 隔离。
   还要并发提交相同 expected attempt 的重复 retry，证明只有一次 scheduler I/O，并验证
   stale/非法 item list 的 results 基数与 journal 原子性。
5. reset/FLR 的实现与测试必须固定为
   `mutation-free staging -> confirmed backing release -> allocation-free reset commit/fence
   clear -> optional replacement prepare -> READY proof -> workflow confirmation`；release
   失败不得先执行 destructive cancel/clear，commit 后新 backing 可独立 prepare，且
   `CONFIRM_RESET_ISOLATION` 不得再次释放旧 backing、清 fence 或调用 I/O。

### 阶段 1B：恢复调用方分项迁移

MR control-plane、queue-lifecycle 和 QP-lifecycle 分成三个独立小计划/提交，依次迁移到
`execute_observed()` 的 result-based presence/recovery 判断。每次只改一个 consumer 及其
测试，不拆对应大单体；未迁移 consumer 继续走 legacy API 并保持保守行为。

reset proof 的 workflow confirmation 只能消费 engine 已登记的 READY proof；旧 runtime
authority 与 fence 在 reset commit 已清除，replacement 只用于证明同一 immutable Function
的更大 reset epoch。精确 `LEGACY_UNMIGRATED` sentinel 在 release commit 即 resolved，
concrete owner 则保持 `recovery_required=1`，直到获授权 workflow 完成 CONFIRM。所有
consumer 的 reconcile 必须继续使用 journal-owned、old-epoch-safe 的只读 projection，
不能把 FIFO delivery row 或当前 runtime authority 当作 recovery authority。

全部生产调用方迁移后，才能停止写入/读取 adapter 级 `last_*` 证据，并让
`last_execute_definitive_no_submit()` 固定返回保守 false。不得在中途把 status code
映射重新包装成另一种共享 bit。

Phase 1A 的 observed route 不得读取或写入 adapter shared last-state；只有 legacy
`execute()` wrapper 可更新 deprecated compatibility seam。adapter 对 engine envelope
执行语义 shape 校验（status/effect/phase/completion、ticket/Function/CMQ identity 和
alias topology），任何矛盾只污染 observation，不覆盖有效 operation status/effects。
Phase 1B 完成三个 consumer 迁移并验证后，才可删除该 seam。

### 阶段 1C：CMQ wire/opcode 契约修复

1. 对两张现有 opcode 表做 256 项 characterization，并建立 descriptor-backed 迁移。
2. 对每个拟支持方向建立 archive/ownership/C-oracle/vector/512-bit mutation 闭环。
3. OCC 每个 opcode 分别登记 request/response 能力；未证明的 20 个 OCC/IDX OCC 分支
   保持 `response_decodable=0`，不得仅靠放宽 mask 宣称支持。
4. wire contract 变化与 engine journal/拆分提交隔离，分别运行完整 CMQ gate。

### 阶段 2：CMQ 渐进抽取

1. characterization tests 锁定 facade、probe、timeout、late completion、reset/FLR 行为。
2. 注入 snapshot service，逐簇移动快照逻辑。
3. 提取纯 ring math。
4. 在阶段 1C 的双表 characterization 仍通过时移动 descriptor adapter，不改变能力。
5. 在 observed/journal 行为已经稳定的前提下，整体下沉 ledger；不得把首次引入 journal
   语义与移动 2300+ 行代码放在同一提交。
6. 最后提取 transport，保持 MMIO observer、锁序和所有 effect 完全不变；engine 继续是
   唯一 coordinator。

### 阶段 3 以后：逐个治理其他大单体

顺序建议为：

```text
queue_runtime contract freeze
    -> queue_data_engine
    -> queue_runtime internal split
    -> resource_manager
    -> control_plane front door
    -> queue lifecycle executor
    -> QP lifecycle
```

每个箭头只表示规格依赖和推荐顺序，不要求前一个对象一次拆完。发现跨对象功能缺陷时，
先以独立测试和独立提交修复，再继续结构抽取。

## 10. 验证与验收

### 10.1 53 上可复现的 CMQ 驱动契约门禁

唯一跨机入口继续使用 `scripts/run_vcs53.sh`，由其启动登录 bash。阶段 0 必须把
`rdma_defs` target 扩展成 archive verifier + C oracle rebuild/diff + field ownership/
capability checker + 现有 profile checker + 对应 Python tests 的组合门禁。固定调用为：

```text
scripts/run_vcs53.sh rdma_defs rdma_cmq_driver_contract_test
```

该入口在 53 默认消费：

```text
RDMA_ARCHIVE=/home/ubuntu/Downloads/dpu_kernel_rdma-version_0.1.34.tar(1).gz
RDMA_ARCHIVE_PREFIX=dpu_kernel_rdma-version_0.1.34
```

Makefile 在临时目录解包后把已验证的 `--kernel-root` 传给所有 checker/probe。archive
lock、路径、hash、prefix、member list、source hash、selector、anchor 或 oracle artifact
任一缺失/不一致时必须非零退出；不得因为解包树没有 `.git`、C probe 无法构建或环境
变量缺失而跳过检查。

CMQ UVM gate 不能只依赖当前通用 regression manifest。阶段 0 建立专用、受版本控制的
CMQ gate manifest，至少逐项执行：

```text
scripts/run_vcs53.sh core rdma_cmq_codec_test
scripts/run_vcs53.sh core rdma_cmq_completion_test
scripts/run_vcs53.sh core rdma_cmq_profile_test
scripts/run_vcs53.sh core rdma_doorbell_codec_test
scripts/run_vcs53.sh core rdma_cmq_engine_test
scripts/run_vcs53.sh core rdma_cmq_driver_field_mutation_test
```

每个 UVM 日志都通过 summary gate，warning/error/fatal 为零；driver contract gate 记录
archive/source/probe/input/output SHA 和编译器 flags。当前 `rdma_cmq_engine_test` 的 VCS
SIGSEGV 是已知阻断项，不能用删业务逻辑或跳过测试掩盖；若仍存在，阶段完成前必须先
保留最小复现并取得工具链修复/稳定 workaround。

### 10.2 每个功能修复

- 严格执行 RED → GREEN → REFACTOR；必须记录失败原因与通过输出。
- Python 静态/定义测试与 §10.1 driver contract gate 通过。
- 对应 VCS 单测与最小相关 suite 在 10.11.10.53 的登录 bash 环境执行。
- UVM warning/error/fatal 均为零；日志必须通过既有 summary gate。
- batch 在第一笔、中间笔、最后一笔 dependency write 注入失败时，每个已可能受影响的
  command 都保留可定位 journal record；禁止出现“Host-memory 已写、ticket 全为 null、
  ledger 无 owner”的状态。
- 同一 Function、不同 resource/workflow owner 的混合 batch 在中间 dependency 失败后，
  每项 result/journal 仍指向自己的 resource、transaction、attempt 和允许 action。
- CMQ 的非空 MMIO observer 恰好调用一次；其后的 MMIO error/timeout 中，entry key 仍
  可被 poll、reconcile 和 late-completion 路径定位，且不得重复 doorbell。
- observer 为 null 的普通 scheduler/legacy 调用不执行 hook，但仍返回非空 status/effect；
  所有 batch item status 和 batch status 满足 §5.2 的空 batch/部分拒绝/全局失败表。
- pre-MMIO fence 期间所有新 submit 返回 `RESOURCE_BUSY + PRE_SUBMIT_REJECTED`；严格同
  image/authority retry 可以在原 batch 上推进，reset/FLR 只有完成 confirmed release 与
  allocation-free commit 才清除 fence，失败 recovery 不丢 journal；
  `CONFIRM_RESET_ISOLATION` 本身不得释放 backing 或清 fence。
- 两个相同 expected-attempt retry 只有一个递增并调用 scheduler；另一个稳定返回 stale
  failure。合法 recovery request 的 results 等长同序，无法定位/结构非法的 request 返回
  空 results，且两条失败路径都不改变 journal/fence。
- reset 后旧 epoch late completion 只生成 diagnostic，绝不改变新 epoch 的 token、slot、
  cursor 或 completion result。
- timeout 后 `TIMED_OUT_QUARANTINED` 保留旧 slot/entry/ticket/epoch，直到 late completion
  有序 retire 或 reset 隔离；timeout completion phase 本身不得触发 slot 复用。
- reset release 失败/null status 必须在任何 destructive cancel/clear 之前返回，且逐值保留
  journal、fence、preallocation、observer、slot/token/index、cursor、FIFO、counter、
  engine state 与 backing authority；成功路径必须证明
  `mutation-free staging -> confirmed backing release -> allocation-free reset commit` 的
  顺序，并允许独立 replacement prepare。
- 每个受影响 batch 的 `AWAITING_REBIND` proof 必须保留 batch/proof digest 与等长有序
  `{request_index, image_digest, authority_digest, full recovery_owner}` tuple；只有同一
  immutable Function 的严格更大 reset epoch 才能提升为 `READY`。精确
  `LEGACY_UNMIGRATED` sentinel 在 reset commit 即 `recovery_required=0`，具体 owner
  在 workflow confirmation 前保持 `1`。
- `reconcile_ticket()` 必须按 retained journal 的完整 ticket authority 只读投影；FIFO
  消费、当前新 incarnation 或旧 completion 的 detached snapshot 不得删除/改写 journal
  evidence，也不得触发 retry 或重复 doorbell。
- legacy `execute()` 的 ticket/completion/status/message 与 observed 投影逐字段一致；
  legacy-only subclass 的 observed effect 恒为 `UNOBSERVED`。Phase 1A 中 production
  adapter 的 observed route 不读写共享 `last_*`，但其 legacy `execute()` wrapper
  暂作为唯一 deprecated writer 更新 `last_execute_no_submit_proven`；三个 Phase 1B
  consumer 完成迁移并验证后才删除该 writer/accessor。
- 任何 wire capability 变化都同时具备 archive/ownership/C-oracle/vector/mutation 证据；
  对 canonical 非对称输入逐字节比较 size/offset/bit/endian/overlay/embed，不以 round-trip
  或 profile checker 单独通过替代。

### 10.3 每次结构抽取

- 对外 facade、status code/message、ticket identity 和 probe 观察保持兼容。
- 新协作者没有额外锁、没有复制 authority、没有跨等待窗口保留可变引用。
- 抽取前后的 characterization tests 使用相同输入并得到相同可观察结果。
- 对首批 capability 表的 request/response bytes 做旧实现、新实现、C oracle 三方差分；
  任一 byte、metadata、typed/opaque/reserved 分类变化都阻断结构提交。
- 功能 diff 与排版 diff 分离，reviewer 能独立接受或拒绝任一提交。

### 10.4 不作为验收条件

- 不要求某文件压缩到指定行数。
- 不把 VCS SIGSEGV 自动归因于大类；该问题保留独立最小复现和工具链调查。
- 不以 profile checker 单独通过宣称所有驱动字段已被模型消费。
- 不以 opcode 常量已注册宣称 request/response codec 已实现。

## 11. 非目标

- 本规格不修改真实 Linux 驱动，也不把当前模型描述成 uverbs/ioctl/libibverbs 闭环。
- 不在 CMQ 提交中顺带修复所有 CQE/RQE/QPC/AEQE 功能问题。
- 不创建通用“万能 engine 基类”或跨引擎共享可变 recovery ledger。
- 不在一个提交中同时改变 wire contract、状态机、类边界和全文件格式。
- 不删除现有兼容接口，除非后续独立 ABI 规格明确批准。
