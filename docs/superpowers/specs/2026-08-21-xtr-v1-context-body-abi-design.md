# xtr_v1 Context 与 CMQ Body ABI 设计

## 1. 目的和范围

本设计修正原 Task 10 把 QPC、CQC、MRT、SRQC、CEQC、AEQC 都视为独立
context 的歧义，并为 Task 9.5、Task 10 和 Task 11 固定同一套可审计 ABI。

本轮只覆盖：

- xtr_v1 创建/注册命令所需的 QPC、CQC、MRT、SRQC、CEQC、AEQC 映像；
- 硬件中立 model 到固定驱动字段的投影；
- encode/decode 的可逆边界；
- CMQ 公共 envelope 与 opcode 专用 body 的组合契约；
- 固定驱动提交、golden vector 和 checker 的扩展范围。

本轮不实现 CMQ ring、doorbell 调度、PCIe BAR 访问、VF 生命周期、数据面 SQE/RQE
或运行时 shadow 更新。它们继续使用总设计中的 adapter 和执行引擎边界。

权威软件基线仍为驱动提交
`491faf2ba42627fffd4dd027607299c8bb591ec2`。所有坐标以最终硬件地址的
byte 0 为最低地址。

## 2. 已确认的驱动事实

驱动中的写入路径决定映像边界，而不是 C 结构体名称：

- `qp.c:xtrdma_fill_rc_ud_qpc_info()` 和
  `qp.c:xtrdma_fill_urc_qpc_info()` 生成独立的 512B QPC buffer；CMQ 命令只携带
  512B 对齐的 buffer 地址。
- `cmq.c:xtrdma_sc_cq_create()` 把 56B CQC 数据复制到最终 64B CMQ WQE 的
  byte 8..63，byte 0..7 同时承载 CQN 和公共 CMQ 字段。
- `cmq.c:xtrdma_sc_mr_register()` 直接在最终 64B CMQ WQE 的 byte 0..48
  生成 MRT register 命令，不存在另一个独立 MRT context buffer。
- `srq.c:xtrdma_hw_create_srfqc()` 先生成 32B SRFQC 数据；
  `cmq.c:xtrdma_sc_srfq_ctx_create()` 把它复制到最终 WQE 的 byte 16..47。
- `event.c:xtrdma_hw_create_eq()` 先生成共同的 32B EQC 数据；
  `cmq.c:xtrdma_sc_eq_ctx_create()` 把它复制到最终 WQE 的 byte 16..47。
  CEQC 与 AEQC 只有 opcode、handle kind 和对象 ID 范围不同，body 布局相同。
- 驱动用 `FIELD_PREP()` 构造 logical qword，再由 `set_64bit_val()` 以
  big-endian 存储。SRQC byte 44..47 的两个 16-bit 写入等价于最终 qword 的
  bit 31:16 和 bit 15:0。

因此，不能先生成一个 context-local byte array，再让 CMQ codec 猜测偏移；Task 10
必须直接生成最终 64B WQE 坐标中的 sparse body。

## 3. 映像种类、大小和对齐

| image kind | 语义 | 长度 | alignment | byte endian | 写入目标 |
|---|---|---:|---:|---|---|
| `RDMA_IMAGE_QPC` | 独立 QPC buffer | 512B | 512B | 每 qword big-endian | host backing；地址由 QPC CMQ 命令引用 |
| `RDMA_IMAGE_CQC` | CQC create sparse body | 64B | 64B | 每 qword big-endian | 只可与 CMQ envelope 合并 |
| `RDMA_IMAGE_MRT` | KEY_ALLOC/MR_REGISTER sparse body | 64B | 64B | 每 qword big-endian | 只可与 CMQ envelope 合并 |
| `RDMA_IMAGE_SRQC` | SRFQC create sparse body | 64B | 64B | 每 qword big-endian | 只可与 CMQ envelope 合并 |
| `RDMA_IMAGE_CEQC` | CEQC create sparse body | 64B | 64B | 每 qword big-endian | 只可与 CMQ envelope 合并 |
| `RDMA_IMAGE_AEQC` | AEQC create sparse body | 64B | 64B | 每 qword big-endian | 只可与 CMQ envelope 合并 |
| `RDMA_IMAGE_CMQ_SQE` | envelope 与 body 的最终合成结果 | 64B | 64B；ring base 4KiB | 每 qword big-endian | CMQ SQ ring |

这里的 64B body 不是可直接下发的 SQE：未合并前 `valid/opcode/index/wrap` 必须为零。
QPC 的 `alignment=512` 源自 CMQ QPC buffer address 的 bit 63:9；CMQ entry
alignment 与 4KiB ring base alignment 是两个独立约束。

sparse body 的 `write_target_kind` 固定为 `RDMA_HW_TARGET_NONE`；只有 Task 11 合成的
最终 SQE 才能带 CMQ ring target。QPC encode 只生成内容，control plane 在分配 512B
对齐的 command buffer 后设置它的 host backing target。

Task 9.5 固定 `XTR_V1_HW_VERSION=1`；所有 image 的 `hardware_version` 必须为 1，
registry key 的字符串版本必须为 `"xtr_v1"`。这两个表示法不得由调用者任意组合。

## 4. CMQ qword 0 的所有权

最终 request WQE 的 qword 0 是共享控制字。公共 envelope 和 command body 各自只能
写自己的 mask：

| owner | qword 0 bits | 含义 |
|---|---|---|
| CMQ envelope | 63 | valid/polarity |
| CMQ envelope | 59 | VFID override |
| CMQ envelope | 58:48 | use VFID |
| CMQ envelope | 45 | wrap |
| CMQ envelope | 44:40 | WQE index |
| CMQ envelope | 39:32 | opcode |
| CQC body | 20:0 | CQN |
| MRT body | 62:61、23:0 | next state、STAG index |
| SRQC body | 15:0 | SRFQN |
| CEQC/AEQC body | 11:0 | EQN |

Task 10 的 body codec 可以拥有 qword 0 中的对象 ID 或 command-specific state，
但不得拥有公共 envelope bit。Task 11 不重新编码对象 ID；它只生成公共 envelope，
再通过受检查的合成器与 body 合并。

request envelope mask 固定为：

```text
bit 63 | bit 59 | bits 58:48 | bit 45 | bits 44:40 | bits 39:32
```

completion 的 `cmd ecode` bit 31:24 归 completion decoder，不属于 request
envelope。任何 codec 都不得因 request WQE 中该字段为零而把它声明为自己的字段。

## 5. Sparse body 坐标

### 5.1 CQC create body

| final WQE byte | body 字段 |
|---:|---|
| 0 | CQN bit 20:0 |
| 8 | SD PBA 51:0、depth factor 60:56、URC flag 61、state 63:62 |
| 16 | next PBA high 7:0、current-valid 11、current PBA 63:12 |
| 24 | load-CI-done 0、threshold 10:8、object mode 15:14、next-valid 19、next PBA low 63:20 |
| 32 | PI 22:0、PI wrap 23、last-arm sequence 61:60、CQE size 63:62 |
| 40 | CEQN 11:0 |
| 48 | CQC/shadow backing address 63:6 |
| 56 | CI 22:0、CI wrap 23、arm sequence 33:32、arm state 35:34 |

这相当于驱动 CQC local byte 0..55 整体右移 8B。原 Task 9 中 local-coordinate
`cqc_boundary` 不能作为 Task 10 的最终 golden；Task 9.5 将其替换为
`cqc_create_body_boundary`。

### 5.2 MRT KEY_ALLOC/MR_REGISTER body

| final WQE byte | body 字段 |
|---:|---|
| 0 | STAG index 23:0、next state 62:61 |
| 8 | STAG key 31:24 |
| 16 | KEY_ALLOC self-parent index 23:0；PD 39:24、payload VF 47:40/enable 48、rights 53:49、type 55:54、host page 57:56、PBL mode 59:58、address mode 60、invalidate 61、state 63:62 |
| 24 | length 45:0、ODP 47、重复 STAG key 63:56 |
| 32 | start VA 63:0 |
| 40 | PBL2 first index 63:36，或 PBL0/PBL1 payload PBA0 63:12 |
| 48 | MR serial 11:0；PBL1 时 payload PBA1 63:12 |

同一 variant 中 byte 40 的 PBL index 和 PBA 不可同时有效。byte 0 state 与 byte 16
state 都由同一个 model state 投影，decode 时两者不一致是 `RDMA_SC_CODEC_ERROR`。
byte 8 与 byte 24 的 STAG key 同样必须一致。

普通 `mr.c:xtrdma_hwreg_mr()` 实际使用 `KEY_ALLOC(0x04)`；该 variant 按当前驱动的
DFX 行为把 byte 16 parent index 写成自身 STAG index。`MR_REGISTER(0x05)` 使用相同
model，但 byte 16 bit 23:0 必须为零。两个 opcode 使用不同 body mask/key，不能互相
decode；本轮不把 KEY_ALLOC 的 self-parent 行为推广为硬件中立 model 字段。

### 5.3 SRQC create body

| final WQE byte | body 字段 |
|---:|---|
| 0 | SRFQN 15:0 |
| 16 | state 63:62、load-PI threshold 59:52、shadow page PBA 51:0 |
| 24 | PD index 63:48 |
| 32 | SRFQ PBA 63:12、depth factor 7:4、object mode 3:2 |
| 40 | PI wrap 31、PI 30:16、limit threshold 15:2、arm sequence 1:0 |

SRQ payload queue backing 和 SRFQ queue backing 是两个资源。此 body 只携带 SRFQ
backing；SRQ payload backing 由引用该 SRQ 的 QPC RQ/SRQ 字段携带。`max_sge` 和
consumer index 不在该 create body 中。

### 5.4 CEQC/AEQC create body

| final WQE byte | body 字段 |
|---:|---|
| 0 | EQN 11:0 |
| 16 | state 63:62、depth factor 56:52、next PBA 51:0 |
| 24 | current PBA 63:12、current-valid 11 |
| 32 | PI wrap 38、PI 37:20、object mode 15:14 |
| 40 | MSI-X index 63:48、CI wrap 18、CI 17:0 |

CEQC 和 AEQC 使用同一个 layout helper，但以不同 `image_kind`、handle kind 和 opcode
注册，禁止一个 key 静默匹配另一个对象类型。

## 6. 硬件中立 model 规划

model 只表达资源语义和 backing 拓扑，不出现 `XTRDMA_*` 常量。Task 10 在现有
`rdma_context_models.svh` 上补充以下共用值对象：

- `rdma_object_mode_e`：direct-4K、indirect-4K、huge-2M、L3-indirect-4K；
- `rdma_context_state_e`：invalid、valid、error；
- `rdma_ring_position`：`index` 和 `wrap`；
- `rdma_page_table_layout`：`mode`、`sd_base`、`current_base/current_valid`、
  `next_base/next_valid`；
- `rdma_address_vector`：source address index、source/destination vport、destination
  port、destination MAC、16B destination IP、IPv6/VLAN/CFI/LAG/tunnel/fwd、VLAN ID、
  traffic class、flow label、hop limit 和 UDP source port；
- `rdma_urc_queue_config`：拥有未移位的 RSQ/RDSQ/DSQ byte-address backing、
  entry-count RSQ/RDSQ depth、count-valued RDSQ/DSQ fetch count 和 entry-count
  RQ sequence/SQ completion threshold，并负责这些硬件中立 queue topology 值的
  deep copy、validation 和 description；
- `rdma_rdma_access_t`：local write、remote read、remote write、memory-window bind、
  remote atomic；它与只描述 PCIe DMA 方向的 `rdma_dma_permission_t` 分离；
- `rdma_mr_page_layout`：PBL mode、host page size、PBA0/PBA1、first PBL index、
  address mode、ODP、invalidate、payload VF enable/ID 和 MR serial。

地址字段继续使用总设计的强类型：实际队列/PBA/PBL 地址用
`rdma_backing_addr_t`，DUT 发起 DMA 的 VA 用 `rdma_iova_t`，HMC/FVM 对象位置用
`rdma_hmc_fvm_addr_t`。现有 QPC/CQC/SRQC/EQC model 中误用
`rdma_hmc_fvm_addr_t` 表示队列 backing 的字段将在 Task 10 改为
`rdma_backing_addr_t` 或上述 page-layout 对象；不得依赖它们都是 64-bit 而混用。
page-layout 中的地址都是未移位的 byte address；codec 先检查 4KiB 对齐，再右移 12。
CQC shadow/context address 单独检查 64B 对齐并右移 6，QPC context address 单独检查
512B 对齐并右移 9。

### 6.1 Handle 到硬件 ID

codec 通过 handle 的 `object_id` 投影硬件 ID：

| model handle | 硬件字段 |
|---|---|
| QPC `qp_h`、`pd_h`、`send_cq_h`、`recv_cq_h`、可选 `srq_h` | QPN、PD index、SQ CQN、RQ CQN、SRFQN |
| CQC `cq_h`、可选 `ceq_h` | CQN、CEQN |
| MRT `mr_h`、`pd_h` | STAG index、PD index |
| SRQC `srq_h`、`pd_h` | SRFQN、PD index |
| CEQC `ceq_h` / AEQC `aeq_h` | EQN |

`kind` 和宽度必须在 encode 前验证。MRT 还要求 `mr_h.object_id == lkey[31:8]`，
`lkey[7:0]` 是 STAG key；xtr_v1 MR register 只有一个 STAG，因此有 remote 权限时
`rkey` 必须等于 `lkey`，无 remote 权限时 `rkey` 可为零或等于 `lkey`。

`function_uid` 和 `generation` 是验证环境的生命周期元数据，没有硬件位。decode 创建
正确 kind/object_id 的投影 handle，并把这两个字段置零；它们不得参与 codec
round-trip equality。

encode 仍要验证同一 model 的所有 handle 具有相同 `function_uid/generation`，并把
generation 复制到 `rdma_hw_image.function_generation` 作为生命周期 guard；该 metadata
不是 payload byte，decode equality 不得因此把它当成硬件可恢复字段。

### 6.2 QPC 投影

QPC common model 增加 `host_id`、`vf_id`、`stat_index`、`pkey`、`qp_sequence`、
`access`、SQ/RQ object mode、address vector、signature/flow-control 选项和显式的
512B context backing address。队列 depth 编码为 `log2(depth)`；队列 backing 先验证
4KiB 对齐，再右移 12。context backing 先验证 512B 对齐，再右移 9。

`rdma_qpc_model.path_mtu_bytes` 是 RC、UD 和 URC 共同的 path MTU 语义状态。
`rdma_qpc_rc_ext` 和 `rdma_qpc_urc_ext` 不得保存重复 MTU；
`rdma_qpc_ud_ext` 仍只拥有 QKey。通用
model 的校验只要求 `path_mtu_bytes != 0`，因此 256B、512B 和未来设备
支持的其他非零值都是可表示的硬件中立语义。

xtr_v1 encode 单独执行以下精确 profile 映射：

| `path_mtu_bytes` | PMTU code |
|---:|---:|
| 1024 | 2 |
| 2048 | 3 |
| 4096 | 4 |
| 8192 | 5 |

任何其他非零 byte size，包括 256B 和 512B，返回
`RDMA_SC_INVALID_ARGUMENT`。decode 执行精确逆映射，code 2/3/4/5 分别恢复
1024/2048/4096/8192B；code 0/1/6/7 返回 `RDMA_SC_CODEC_ERROR`。codec 不得
根据 transport 生成默认 MTU。所有这些失败都保持原子输出契约：encode 的
image 与 decode 的 model 保持 null/未发布。

transport 投影固定为 RC=`0`、UD=`3`、URC=`6`。QP state 投影固定为：

| UVM state | xtr_v1 state |
|---|---:|
| RESET | invalid 0 |
| INIT | 1 |
| RTR | 2 |
| RTS | 3 |
| ERROR | 4 |
| SQD、SQE | drained 5 |

SQD/SQE 是非单射映射，decode 统一返回 SQD。RC 的 `send_psn` 必须同时写入
byte 160 `TPE_CUR_SQ_PSN`、byte 208 `LAST_READ_PSN`、byte 344 `PSN_MAX_RPE`、
byte 352 `EPSN_RSP`、byte 376 `QPC2_EPSN_RSP`、byte 416 `PSN_MAX_TPE`、
byte 424 `RETRY_FPSN` 和 byte 432 `RETRY_PSN`。`recv_psn` 必须同时写入 byte 224
`EIRQ_PSN_MAX`、byte 232 `EIRQ_CUR_SEND_PSN` 和 byte 288 `EPSN_REQ`。decode 以驱动
query 路径对应的 byte 352 `EPSN_RSP` 和 byte 288 `EPSN_REQ` 为 canonical 值，并
要求各自所有镜像一致，否则报 codec error。retry count 和 RNR retry 必须适配 3-bit
字段。

UD 的 QKey 仍由 transport extension 提供；address vector 不再用一个不透明 ID 代替。
traffic class 投影为 `ICOS=tc[7:5]`、`DSCP=tc[7:2]`。固定驱动 create profile 对 UD
使用 ECN 0、对 RC/URC 使用 ECN 2；model 的 `tc[1:0]` 必须与该 profile 一致，否则
encode 返回 invalid argument。codec 同时编码 flow label、MAC、IP、VLAN 和端口字段。

URC create/modify 使用一个 `rdma_qpc_urc_ext`；它拥有 `remote_qpn`、canonical
`rbsn/dbsn/rpsn/dpsn` 和 non-null `rdma_urc_queue_config`。queue object 拥有未移位的
byte-address `rsq_backing/rdsq_backing/dsq_backing`、entry-count
`rsq_depth/rdsq_depth`、count-valued `rdsq_fetch_count/dsq_fetch_count`，以及
entry-count `rq_sequence_threshold_entries/sq_completion_threshold_entries`。禁止把
RC `send_psn/recv_psn` 直接写入 URC-only bit。

xtr_v1 的 sequence mirror 固定为：`rbsn -> TX_RBSN/RX_RBSN`、
`dbsn -> TX_DBSN/RX_DBSN/RXED_DBSN`、
`rpsn -> CUR_TX_RPSN/TPE_RPSN_MAX`、
`dpsn -> CUR_TX_DPSN/TPE_DPSN_MAX`。decode 必须先证明每组所有 mirror 相等，才能
publish 对应 canonical scalar。`RX_SRBSN/TX_SRBSN/MAX_TX_SRBSN` 是 runtime-only，
没有 create owner，必须排除在 create allowed mask 外；create-image decode 看到其中
任意非零值都返回 `RDMA_SC_CODEC_ERROR`。

RSQ/RDSQ depth 以 exact `log2(entries)` 编入 3-bit 字段；RDSQ/DSQ fetch count 以
count 直接编入 6-bit 字段；threshold 的零值编码为 code 0，非零值以 exact
`log2(entries)` 编入 4-bit 字段。DSQ current page 等于 `dsq_backing.value >> 12`，
next page 必须等于 current page 加一，且该加法不得发生 52-bit overflow。decode 对
这些 depth、count、threshold、backing page 和 next-page relation 执行精确逆变换。

现有 QPC model 中的 SQ/RQ producer/consumer index 属于 ring/shadow 运行时状态，不是
512B CMQ QPC buffer 的 create 参数。Task 10 把它们从 QPC field model 移除；
`rdma_qp` resource 继续持有运行时 cursor。后续 shadow/doorbell 任务负责 PI，
completion/monitor 负责 CI。

### 6.3 CQC、MRT、SRQC 和 EQC 投影

- CQC：`depth -> log2(depth)`；page layout 映射 SD/current/next PBA；producer 和
  consumer 分别映射 PI/CI 与 wrap；CEQ handle 映射 CEQN；CQE byte size 映射
  32/64/128B code；shadow backing 必须 64B 对齐。
- MRT：`iova -> start VA`、`length -> 46-bit length`；rights bit 0..4 分别来自
  local-write、remote-read、remote-write、MW-bind、remote-atomic，其中 remote-write 或
  remote-atomic 会规范化地同时置 local-write；
  PBL0/PBL1 使用 PBA，PBL2 使用 first PBL index。KEY_ALLOC 的 self-parent index 从
  STAG index 派生，MR_REGISTER 对应位置固定为零。`backing_addr` 不再兼任三种模式，
  由 `rdma_mr_page_layout` 明确选择。
- SRQC：depth 映射 size factor，producer index/wrap 映射 SRFQ PI；page layout 提供
  SRFQ backing；shadow backing、limit threshold、arm sequence 和 load threshold
  显式建模。consumer index 和 max SGE 只保留在 `rdma_srq` resource，不留在 body
  model 中。
- CEQC/AEQC：depth 映射 size factor；page layout 提供 current/next PBA；ring
  position 映射 PI/CI；vector ID 映射 MSI-X index。现有 `interrupt_enable` 没有独立
  硬件 bit，移到 event/interrupt policy，不留在 body model 中。

xtr_v1 对 mode 的 profile 约束固定为：CQC 接受 indirect-4K、huge-2M 和
L3-indirect-4K；CEQC/AEQC 只接受 indirect-4K 和 L3-indirect-4K；driver 标记为未使用的
direct-4K 在这些 body 中返回 invalid argument。PBL mode 是 MRT 的另一套枚举，不得与
queue object mode 复用。

## 7. Encode、decode 和 equality 契约

`rdma_codec_base` 增加
`serialized_equal(lhs, rhs, output bit equal, output string mismatch)`；基类默认把
`equal` 置零并返回 `RDMA_SC_UNSUPPORTED_OPCODE`，xtr_v1 context/body codec 必须覆盖
它。测试不得调用普通对象全字段 compare 来冒充硬件 round-trip。

比较规则是：

1. 比较所有真正序列化的语义字段；
2. handle 只比较 kind/object_id；
3. 比较变换后的 canonical 值，例如 `log2(depth)`、QP state 和 PBA shift；
4. 忽略 function UID 和 generation；其他无法序列化的 runtime/policy 字段不得继续
   混入 context/body model；
5. 驱动要求的重复/镜像硬件字段必须在 decode 时彼此一致，不能只读其中一个并忽略
   损坏；
6. reserved bit 必须为零。

QPC `serialized_equal()` 对 RC、UD 和 URC 都比较公共
`rdma_qpc_model.path_mtu_bytes`。它绝不从 transport extension 读取 MTU，也绝不
省略 UD MTU。

URC `serialized_equal()` 还比较 `remote_qpn`、四个 canonical sequence scalar，以及
`rdma_urc_queue_config` 的每个字段；它不比较三个 runtime SRBSN 字段，因为成功的
create-image decode 已要求 `RX_SRBSN/TX_SRBSN/MAX_TX_SRBSN` 全部为零。

编码分两阶段进行：先用 `LSB/WIDTH` 对 logical qword 执行等价 `FIELD_PREP`，再逐
qword big-endian serialization。禁止把 `WORD_BYTE_OFFSET*8+LSB` 当成 raw byte-stream
bit offset。16B IP 和其他 byte array 按驱动 `memcpy` 顺序复制。

所有操作都必须原子化：

- caller-supplied model / encode input 的 class/variant 不匹配、宽度超限、非 2 的幂、
  非法对齐或矛盾字段返回 `RDMA_SC_INVALID_ARGUMENT`；这包括 URC
  `remote_qpn == 0` 和 threshold topology 不合法；
- image kind、length、alignment、endian、reserved bit 或重复镜像不合法返回
  `RDMA_SC_CODEC_ERROR`；
- 从 image decode 和 inverse transform 后发现的 semantic invalidity 返回
  `RDMA_SC_CODEC_ERROR` 并保持 decode output null/unpublished；这包括 threshold inverse
  超过 common QPC RQ/SQ depth，以及 URC `DST_QPN == 0`；
- 未注册 transport/opcode 返回 `RDMA_SC_UNSUPPORTED_OPCODE`；
- encode 失败不返回半写 image；decode 失败不返回半填 model；
- 每次 encode 从全零固定长度数组开始，body mask 外的 byte/bit 必须保持零。

## 8. Task 11 合成接口

Task 11 增加唯一的 CMQ request 合成入口，逻辑等价于：

```text
compose_request(envelope, body):
  validate length/image kind/version/endian
  validate envelope bytes outside envelope_mask are zero
  validate body bytes outside opcode_body_mask are zero
  reject (envelope_mask & opcode_body_mask) != 0
  result = envelope OR body
  validate final opcode-specific allowed mask and reserved bits
```

合成器使用 opcode registry 选择 body mask，不能根据非零 byte 猜命令类型。CQC、MRT、
SRQC、CEQC、AEQC create 使用 Task 10 body；QPC create/modify、delete/query、MR
deregister、CQ/EQ/SRQ delete/query 和 flush 的轻量 command body 由 Task 11 自己实现，
但仍服从相同所有权检查。

VF override/use-vfid 属于 envelope，并由后续 Function binding/CMQ request 提供；
context model 内的 QPC `vf_id` 和 MRT payload VF 是硬件对象内容，不能代替 CMQ
requester VF。两套 VF 字段允许数值相同，但含义和校验来源不同。

## 9. Task 9.5：冻结扩展 ABI

Task 9.5 在写任何 Task 10 codec 前完成，并保持 Task 9 的独立 reference 原则。

### 9.1 Provenance

`source_manifest.txt` 在现有 qp/cq/cmq 来源上增加：

| path | selector | SHA-256 |
|---|---|---|
| `alloc.h` | `xtrdma_alloc_type` | `6723ae4bdfdc283e6c4821d2ce59f5ca300629665527cf316e4c49c6dad53922` |
| `mr.h` | MR/PBL/page/address enums and `xtrdma_reg_mr_info` | `de683e3e941e31ba07162ea2b4712a5ed2224d26362fd567916c0abfbfef58c8` |
| `mr.c` | `xtrdma_hwreg_mr` projection | `ac507832fb7f595ad168735946499c4612baf1eaebac7ede301f1f29621d8aed` |
| `rdma_main.h` | `xtrdma_get_access` | `19f16fc6f4e0b2a8e3f9e14ec4ac9d2bde1e34472313866abe430be1f9258c7e` |
| `srq.h` | `XTRDMA_SRFQ_CTX_*` | `c0f7edd9bc65a4a574c082167221bdb7644c28e6f4387c1bd2a5db157b2341ae` |
| `srq.c` | `xtrdma_hw_create_srfqc` | `c511b0d669e9501ece1c3f02ac7079b6d900b34cf87a33b1dc800857b47fd766` |
| `event.h` | `XTRDMA_EQ_CTX_*` | `9c1185a2279854c95ed00a949c2a8aa3f4a1588386de65bf7fa7662d08dfb99a` |
| `event.c` | `xtrdma_hw_create_eq` | `efdba325776236f3715c4e847d5bae90369263bd29b14192dd6234b498df189b` |

checker 仍校验固定 commit 和实际 source bytes。新增 enum/value mapping、body base offset、
field width、field uniqueness 和 ownership mask 都必须从 checker 的独立 reference table
核对，不能从待测 SV 常量派生 expected 值。

### 9.2 Definitions 和 golden cases

Task 9.5 新增明确的 `*_BODY_*` 常量，避免把 local context 坐标与 final WQE 坐标混用；
现有 QPC standalone 常量保持原名，并新增
`XTR_V1_OP_KEY_ALLOC=8'h04`。新增/替换的 context/body golden 精确包含：

- `qpc_rc_boundary`：RC address vector、SQ/RQ backing、SQ/RQ CQN、SRQ 选择、
  send/recv PSN 镜像、retry/RNR、state 和 handle ID；
- `qpc_ud_boundary`：QKey、traffic class 拆分、flow label、MAC、IPv4-mapped/IPv6 byte
  顺序、VLAN 和端口；
- `qpc_urc_boundary`：非零 remote QPN；四个 canonical sequence owner 派生出的全部
  mirror；使用 byte address、entry count 和 count 单位的 RSQ/RDSQ/DSQ queue config；
  RSQ/RDSQ depth、RDSQ/DSQ fetch、RQ/SQ threshold；三个 runtime SRBSN 全部为零；
- `cqc_create_body_boundary`；
- `mrt_register_pbl0_boundary`、`mrt_register_pbl1_boundary`、
  `mrt_register_pbl2_boundary`；
- `mrt_key_alloc_pbl0_boundary`，用于锁定普通 MR 路径的 opcode 和 self-parent 差异；
- `srqc_create_body_boundary`；
- `ceqc_create_body_boundary`、`aeqc_create_body_boundary`。

三个 QPC case 的 frozen common golden inputs 精确为：RC=8192B/code 5、
UD=4096B/code 4、URC=8192B/code 5，均设置
`rdma_qpc_model.path_mtu_bytes`。这些是每个 golden case 显式提供的输入，不是
transport 或 codec 默认值。

每个 case 都保存固定输入摘要、byte count 和完整 payload。reference encoder 继续使用
独立 occupancy；零值字段也占用声明的 mask，重叠或越界必须在不改变输出的情况下失败。
checker 还要验证：

- 所有 body mask 与 request envelope mask 不相交；
- body mask 外全零；
- CQC local offset 到 body offset 的 `+8` 关系；
- SRQC/EQC context offset 到 body offset 的 `+16` 关系；
- MRT/CQC 重复字段一致；
- 所有 golden 文件 byte-for-byte 可独立重建。

## 10. Task 10 和 Task 11 的边界

Task 10 负责：

- 补齐硬件中立 model 和 validate/copy/describe；
- 实现 QPC RC/UD/URC standalone codec；
- 实现 CQC/MRT/SRQC/CEQC/AEQC sparse body codec；
- 实现 serialized equality、reserved-bit 检查和 Task 9.5 golden round-trip；
- 注册 context/body codec key。

body codec registry key 的 opcode 必须是对应 create/register opcode，不能用 opcode 0
作为“无关”通配符；同一个 `image_kind` 后续增加 modify body 时必须获得不同 key。

为避免再次形成单体 codec 文件，Task 10 的文件边界固定为：

- `src/model/rdma_context_layouts.svh`：共用 enum/value object，不含 xtr_v1 常量；
- `src/model/rdma_context_models.svh`：QPC/CQC/MRT/SRQC/EQC 对象与 validate/copy；
- `src/codec/xtr_v1/rdma_xtr_v1_qword_codec.svh`：logical qword occupancy、
  `FIELD_PREP` 等价操作和 big-endian serialization；
- `src/codec/xtr_v1/rdma_xtr_v1_qpc_codecs.svh`：QPC common 与 RC/UD/URC extension；
- `src/codec/xtr_v1/rdma_xtr_v1_context_body_codecs.svh`：五类 sparse body；
- `src/codec/xtr_v1/rdma_xtr_v1_image_masks.svh`：Task 9.5 固定的 allowed/body mask，
  供 Task 10 validate 和 Task 11 compose 共用。

现有 raw-byte `rdma_bit_packer` 不负责 endian 转换，不能被 QPC/body codec 直接用于
logical offset；只能由 qword helper 在单个 logical qword 内复用其范围/重叠思想。

Task 10 不写 CMQ opcode、index、wrap、valid 或 use-vfid，不计算 QPC CMQ signature，
也不把 sparse body 直接写进 ring。

Task 11 负责：

- CMQ request/completion envelope；
- opcode registry 与 body ownership registry；
- envelope/body 合成和 QPC signature；
- create 以外的轻量 command body；
- completion 和硬件 error-code decode。

Task 11 不重新解释 Task 10 的 context 字段。两个任务之间唯一交换对象是经过验证的
`rdma_hw_image`、明确 opcode/body mask 和 immutable model/request。

## 11. 验收标准

设计落地后必须满足：

1. checker 从固定驱动 source bytes 独立重建所有新增定义和 golden，并在 source、SV
   常量或 golden 任一处漂移时失败；
2. QPC 的三种 transport 和五类 sparse body 均 byte-for-byte 匹配 golden；
3. 所有 encode/decode round-trip 使用 serialized equality，且能发现镜像字段不一致；
4. 所有 reserved-bit、错误长度、错误 endian、错误 variant、越界 ID、错误对齐和
   header/body overlap negative case 都返回确定 status；
5. Task 10 输出中公共 CMQ envelope bit 始终为零；
6. Task 11 合成后的 64B SQE 与真实驱动构造顺序一致；
7. 本地 Python checker 通过，并在 `10.11.10.53` 的 fresh VCS staging 上运行相关 UVM
   测试；所有新增 expected-failure 都验证精确非零退出码和目标错误消息。
