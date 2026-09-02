# RDMA Send Queue Engine 设计

日期：2026-09-02
状态：待审阅

## 1. 目标

本轮在已经交付的 QP lifecycle、queue-data engine、host-memory adapter、
XTR v1 queue codec、doorbell scheduler 和 queue recovery 之上，完成可实际投递的
Send Queue 路径：

1. 新增 `rdma_sq_engine` facade，复用唯一的 `rdma_queue_data_engine` runtime，
   不创建第二套 PI、CI、credit 或 outstanding authority；
2. 按 pinned XTR v1 驱动构造 RC/UD SQE，支持 direct inline、inline SGB、
   direct SGE、SGE SGB 和 atomic fixed-body；
3. SQE、SGB 和可选 non-inline payload 都通过注入的真实 `rdma_host_mem_api`
   访问，写入后逐字节 readback；
4. 使用现有 producer reservation、64-byte ring、DMA→MMIO barrier、SQ doorbell、
   CQ release 和 recovery；
5. 以 QP generation 为边界跟踪 WQE-level 24-bit PSN，并把完整投递证据保存在
   outstanding record 中；
6. 保证失败不静默丢弃 payload、不猜测不确定的 MMIO outcome，也不提前复用
   SQ 或 SGB slot。

这里的 “engine” 是 host-side transaction/UVM 层，不是可综合 RTL，也不模拟设备内部
packetization、ACK/retry 或网络时序。

## 2. 范围边界

本轮支持 pinned kernel `xtrdma_post_send()` 实际接受的两类 QP：

- RC：SEND、SEND_WITH_IMM、RDMA_WRITE、WRITE_WITH_IMM、RDMA_READ、
  ATOMIC_CMP_SWAP、ATOMIC_FETCH_ADD 和 LOCAL_INVALIDATE；
- UD：SEND 和 SEND_WITH_IMM。

URC 的现有 semantic type、QPC codec 和 queue codec registry key 保持不变，但
pinned `xtrdma_post_send()` 没有 URC dispatch case。`rdma_sq_engine` 因此明确返回
`RDMA_SC_UNSUPPORTED_OPCODE`，不会把 RC 布局推测成 URC ABI。SEND_WITH_INV、
REG_MR、BIND_MW 和 GSI/SMI 也没有当前 semantic request 或独立资源语义，不在本轮
增加。

本轮不实现：

- device-side packet engine、24-bit PSN 的 packet-level 增量、重传或 ACK 状态机；
- AH/MR/MW lifecycle、lkey/rkey table lookup 或 PCIe/网络 VIP 的真实接线；
- batch post、blue-flame/FWQE、CQ moderation 或 multi-packet completion 生成；
- 修改外部 `host_mem` 项目；
- 用环境脚本、明文凭据或生成日志替代仓库内可审计代码。

## 3. 证据基线与 ABI 扩展规则

本设计使用仓库 `hw/xtr_v1/source_manifest.txt` 固定的 kernel commit
`491faf2ba42627fffd4dd027607299c8bb591ec2`。本地审计副本与 manifest 完全匹配：

| 文件 | SHA-256 |
|---|---|
| `wr.h` | `c75fb5770ef0ea1af404efbaf95cf79356d1096d331d7cdfcc46ea9ad9b3225b` |
| `wr.c` | `df855a9c560fced5dae7e188a540fb1b333fb8746395f88522a185eb265e8230` |
| `qp.c` | `90e91142fbfbd009feda08b1137ef2c584e8da1054f83d6250c1f67cce1a165a` |
| `xtrdma_hw.h` | `a917b3080d601bcf62d595383ab6c663c19c2a05c7a1854f481800c97dddc9cb` |
| `defs.h` | `79e26543d2b9c0942be2819cd505f50118b6cd005a2c8d237dbf8a690963b9ae` |

字段和顺序来自 `xtrdma_set_sge()`、`xtrdma_fill_sq_sgb()`、
`xtrdma_fill_sqe_sge()`、`xtrdma_process_rc_sge()`、
`xtrdma_process_ud_sge()`、`xtrdma_set_rc_read_write_wqe()`、
`xtrdma_set_rc_send_wqe()`、`xtrdma_set_rc_atomic_wqe()`、
`xtrdma_set_ud_wqe()`、`xtrdma_fill_hdr_wqe()` 和
`xtrdma_notify_sq_db()`。

上一轮 queue-data spec 把尚未取得可信坐标的 byte 8 和 byte 32..63 保持为 reserved。
本轮只用上述同一 pinned source 中新审计到的坐标缩小 reserved mask；不改变已有字段、
qword big-endian 规则或 golden case。`tools/check_xtr_v1_defs.py`、source map 和新增
golden vectors必须同时固定每个新增 C symbol、SV 坐标和最终 byte image。外部驱动源码
仍不复制进仓库。

## 4. 总体架构

```text
rdma_post_send_req
        |
        v
 rdma_sq_engine facade
        |
        +--> optional rdma_sq_payload_writer --> real host_mem payload mappings
        |
        v
 rdma_queue_data_engine
   |       |        |        |
   |       |        |        +--> rdma_doorbell_scheduler
   |       |        +-----------> XTR v1 SQE codec/signature
   |       +--------------------> SQ/SGB rdma_queue_backing_access
   +----------------------------> runtime PI/CI/credit/recovery ledger
```

`rdma_sq_engine` 是窄 facade：它只暴露 SQ attach/post/recover/query，内部引用一个已经
配置好的 `rdma_queue_data_engine`。SQE 构造和 commit 路径在 queue-data engine 中只有
一个实现，直接调用旧 `post_send()` 或经 facade 调用得到相同语义。facade 不缓存第二份
cursor、credit 或 slot ledger。

每个已 attach 的 QP generation 增加一个 SQ extension，保存 programmed-QPC snapshot、
协商的 send capability、可选 SGB backing access、next PSN、per-QP posting semaphore 和
outstanding index。SQ extension 与现有 SQ runtime 一起创建、进入 recovery 和 detach。

## 5. 公共接口

新增接口如下；`payload_writer == null` 是合法配置，但带 non-inline `payload` 的请求会
被拒绝。

```systemverilog
class rdma_sq_engine extends uvm_object;
  function rdma_status configure(
    rdma_queue_data_engine queue_engine,
    rdma_sq_payload_writer payload_writer = null
  );

  function rdma_status attach_qp(rdma_handle qp_h);
  function rdma_status detach_qp(rdma_handle qp_h);

  task post_send(
    rdma_post_send_req request,
    output rdma_queue_post_result result,
    output rdma_status status
  );

  function rdma_status recover_qp(
    rdma_handle qp_h,
    rdma_queue_recovery_action_e action,
    bit caller_confirmed_no_submit = 1'b0
  );

  function rdma_status query_outstanding(
    rdma_handle qp_h,
    longint unsigned wr_id,
    output rdma_sq_outstanding_record record
  );
endclass
```

`configure()` 不重新配置 manager、binding、host-memory、codec registry 或 doorbell
scheduler；这些 authority 来自传入的 queue-data engine。一个 facade 只能绑定一个
queue-data engine，且后者只能有一个 SQ service owner。`attach_qp()` 复用现有
`rdma_queue_data_engine.attach_qp()`；重复 attach、不同 Function、stale generation、
非 ACTIVE resource 或非 RTS QP 均失败且不发布部分 attachment。

`detach_qp()` 只允许没有 posted、pending 或 bookkeeping-recovery record 的 SQ。
ambiguous doorbell 后的 attachment 不能借 detach 清除证据。

## 6. QP capability 与 SGB lifecycle

### 6.1 Create/resource model

`rdma_create_qp_req` 增加显式 `max_inline_data` 和 `sq_sgb_backing`；
`rdma_qp` 与 `rdma_qp_backing_plan` 保存 detached 的 `max_send_sge`、
`max_recv_sge`、`max_inline_data` 和可选 `sq_sgb_ref`。`max_inline_data == 0`
表示该 QP 禁止 inline。

XTR v1 固定：

- WQE 64 bytes；WQE 内直接 payload 区 32 bytes；
- 一个 SGE descriptor 16 bytes，WQE 内最多 2 个；
- SGB slot 512 bytes、512-byte aligned；
- inline 上限 512 bytes；一个 SGB 最多保存 32 个 SGE descriptor；
- 单 SGE 和 total payload 都不得超过 2 GiB，SGE length bit 31 保留，2 GiB 以
  length field 的零值表示。

`need_sq_sgb` 按 pinned QP allocation 规则确定：UD 总是需要；RC 在
`max_send_sge > 2` 或 `max_recv_sge > 2` 时需要。若该条件为假，
`max_inline_data` 必须不大于 32；若为真，必须不大于 512。
`max_send_sge` 还必须同时不大于 Function `max_wq_sge` 和 32。

需要 SGB 时，`sq_sgb_backing` 可以 owned 或 borrowed，逻辑大小固定为
`sq_depth * 512`，物理 allocation 向上取整到 4 KiB。每个 512-byte slot 必须完整落在
一个连续 mapping segment 中，effective IOVA 512-byte aligned，direction/permission
必须允许 `RDMA_DMA_DEVICE_READ`。不需要 SGB 时只接受 canonical empty backing spec。

### 6.2 Ownership 与 cleanup

新增 `RDMA_QUEUE_ROLE_QP_SQ_SGB`。它属于 QP payload authority，但不是 PI/CI ring，
也不创建 page directory。QP lifecycle 在 create 阶段分配或绑定、全量清零并保存
release authority；SQ engine 只借用该 ref，不单独 allocate/release。

每个 SQ index 永久对应 `sq_sgb_ref[index * 512 +: 512]`。只有相同 SQ slot 的
completion credit 已归还后，该 SGB slot 才能复用。write/readback 或 doorbell failure
时 slot 与 image 保留给 recovery。

QP create rollback 按 acquisition 逆序清理 owned SGB；borrowed SGB 永不 release。
正常 destroy 只有在 QP 已进入 ERROR/完成既有 SQ flush 和 QPC delete 之后，才按
exactly-once cleanup progress 释放 owned SGB。queue detach、CQ completion或
`rdma_sq_engine` 析构都不释放 SGB。ambiguous MMIO 时 SGB authority至少保留到
Function reset 或控制面完成可证明的 QP teardown。

## 7. Payload writer

### 7.1 Request 语义

`rdma_post_send_req` 的 payload shape 固定为：

- inline：`inline_data == 1`、`payload.size() > 0`、`sges.size() == 0`；payload
  是唯一数据源；
- ordinary non-inline：`inline_data == 0`、一个或多个非空 SGE、`payload.size()==0`；
  engine 不改写 SGE 指向的 memory；
- staged non-inline：与 ordinary non-inline 相同，但 `payload.size()` 必须精确等于
  所有 SGE length 的 checked sum；engine 必须先经 payload writer scatter/write/
  readback，不能忽略 payload 或仅凭裸 IOVA 写内存；
- RDMA_READ、atomic 和 LOCAL_INVALIDATE 不允许 payload；atomic 固定一个 8-byte、
  8-byte aligned SGE；LOCAL_INVALIDATE 没有 SGE；
- `immediate_data` 只由 SEND_WITH_IMM/WRITE_WITH_IMM 编码；其他 opcode 要求其为零；
- 新增 request `fence` bit。LOCAL_INVALIDATE 映射 FORCE_FENCE=`2'd1`；其余请求
  `fence==1` 映射 READ_FENCE=`2'd2`，否则为零。

### 7.2 可验证 writer contract

新增抽象类：

```systemverilog
virtual class rdma_sq_payload_writer extends uvm_object;
  pure virtual function rdma_status stage_and_verify(
    rdma_dma_request_context request_context,
    rdma_sge sges[$],
    byte unsigned payload[$],
    output rdma_sq_payload_write_receipt receipt
  );
endclass
```

默认 `rdma_host_mem_sq_payload_writer` 使用注入的真实 `rdma_host_mem_api`，并提供
`register_mapping()`/`unregister_mapping()` 管理 caller-owned payload capability。
注册只保存 detached mapping authority，不取得 release ownership，也不会调用
`host_mem.release()`。成功 receipt列出实际使用的 registration IDs；存在引用该
registration 的 live/pending SQ record 时，`unregister_mapping()` 返回
`RDMA_SC_RESOURCE_BUSY`。这只约束经 writer 管理的 staged payload；ordinary
non-inline SGE 的 memory-registration lifetime仍由 caller负责。

writer 在任何写入前完成全部检查：Function/generation、BDF、PASID、DMA domain、
ACTIVE mapping、无重叠注册、IOVA checked range、`RDMA_DMA_DEVICE_READ` direction 和
device-read permission。每个 SGE 必须完整解析到一个已注册 mapping；payload 按 SGE
顺序连续 scatter。随后每段调用真实 `host_mem.write()` 和 `host_mem.read()`，逐字节
比较；全部成功后才发布包含 Function generation、SGE ranges、payload byte snapshot
和 `verified=1` 的 receipt。

adapter 在写入中途失败可能已经改变 caller-owned payload memory；writer不伪造回滚。
该失败保证没有 SQE/SGB/doorbell side effect，返回 non-OK status 和 null receipt。
recovery retry 复用成功 receipt 与 frozen SQE/SGB image，不再次调用 writer。

## 8. Payload mode 与长度规则

新增枚举并保存在 post result、pending operation 和 outstanding record：

```text
RDMA_SQ_PAYLOAD_NONE
RDMA_SQ_PAYLOAD_INLINE_WQE
RDMA_SQ_PAYLOAD_INLINE_SGB
RDMA_SQ_PAYLOAD_SGE_WQE
RDMA_SQ_PAYLOAD_SGE_SGB
RDMA_SQ_PAYLOAD_ATOMIC_FIXED
```

模式选择是确定的：

| Transport/shape | 条件 | 模式 | SQE 的 SGE count |
|---|---|---|---:|
| RC zero-payload/local invalidate | length 0 | NONE | 0 |
| RC inline | length 1..32 | INLINE_WQE | `ceil(length/16)` |
| RC inline | length 33..max_inline | INLINE_SGB | `ceil(length/16)` |
| RC non-inline | 1..2 SGE | SGE_WQE | 有效 SGE 数 |
| RC non-inline | 3..max_send_sge | SGE_SGB | 有效 SGE 数 |
| RC atomic | exactly one 8-byte SGE | ATOMIC_FIXED | 1 |
| UD inline | length 1..max_inline | INLINE_SGB | `ceil(length/16)` |
| UD non-inline | 1..max_send_sge | SGE_SGB | 有效 SGE 数 |

本设计拒绝 zero-length/null SGE，而不是像 kernel helper 一样跳过它，避免 semantic
request 的 SGE count、payload length 和 serialized count 不一致。所有加法在写内存前
检查 overflow；RC total payload 上限为 2 GiB，UD 的 14-bit total-length field把上限
进一步收紧为 16383 bytes。SGB image 固定 512 bytes并先清零；inline最后一个
16-byte chunk 的 padding 以及未使用 descriptor tail 均为零。

## 9. XTR v1 SQE 布局

所有字段先在 logical 64-bit qword 中按 `FIELD_PREP` 放置，再由
`set_64bit_val()` 等价规则逐 qword big-endian 序列化。memory byte 0 是最低硬件地址。
RC/UD inline payload 和 UD destination-IP 是 driver `memcpy` 的 raw byte range，
不做 qword byte swap；SGE descriptor、SGB pointer 和其他数值字段仍按 qword规则编码。

### 9.1 Common header，qword 0 / byte 0..7

| Bits | 字段 |
|---:|---|
| 20:0 | local QPN |
| 23:21 | ICOS |
| 31:24 | 8-bit QP sequence (`programmed_qpc.qp_sequence`) |
| 35:32 | hardware opcode |
| 39:36 | destination port |
| 54:40 | SQ WQE index |
| 55 | WQE wrap |
| 56 | signature enable，固定 1 |
| 57 | solicited event |
| 59:58 | fence |
| 60 | inline/local-QPC-read selector；本轮仅表示 inline |
| 62:61 | completion event mode |
| 63 | valid polarity |

首个 SQ cycle 的 wrap 为 0、valid 为 1；每次 PI 回到 index 0 时 valid 翻转，因此
固定初始化下 `valid == ~wrap`。`sign_en` 与 request `signaled` 无关：驱动始终启用
SQE signature。RC signaled 使用 RX_CE=`2'd1`；UD 和 LOCAL_INVALIDATE signaled
使用 TX_CE=`2'd2`；unsignaled 为 0。SE 只允许 SEND、SEND_WITH_IMM 和
WRITE_WITH_IMM，其他 opcode 强制清零。

RC 的 ICOS/destination port 来自 attached QP programmed address vector；UD 来自本次
request 的 detached `rdma_address_vector`。因此 UD request 增加必需的
`address_vector` value snapshot；既有 `address_vector_id` 只作调用者 correlation，
不替代实际字段来源。`rdma_address_vector` 增加 UD WQE需要的 `priority[2:0]`、
`multicast` 和 `forwarding_mode[1:0]` value；既有 `forwarding_enable` 仍只保持 QPC
语义，不能代替 UD 的 2-bit FWD。PD index从 attached QP 的 authoritative PD local ID
派生，不能由 send caller提供。destination port、source-address index、destination
vport、VLAN、traffic-class、flow-label 和 hop-limit 都按表中硬件宽度验证，超宽值
不截断。

### 9.2 RC normal body

| Logical qword | 字段 |
|---:|---|
| 1 / byte 8 | bits 63:32 immediate/invalidate value；bits 31:0 total payload length |
| 2 / byte 16 | signature[63:56]，SGE count[55:48]，remote key[31:0] |
| 3 / byte 24 | remote VA[63:0] |
| 4..7 / byte 32 | inline bytes、最多两个 direct SGE，或 qword4 SGB IOVA[63:9] |

SEND 的 remote key/VA 为零；RDMA_WRITE/READ 使用 request remote address/rkey。
WITH_IMM 的 immediate value位于 memory byte 8..11，total length 位于 byte 12..15。
LOCAL_INVALIDATE 在 qword1 bits63:32 写 invalidate key，其余 body 为零。

### 9.3 SGE 与 SGB

每个 descriptor 是两个 qword：第一个 qword bits63:32 为 31-bit encoded length、
bits31:0 为 lkey，第二个 qword为完整 IOVA。2 GiB length 编码为零，其他值原样编码。

SGB effective IOVA 必须 512-byte aligned。model 保存完整 IOVA；codec 向
`XTRDMA_SQ_WQE_SGB_PA[63:9]` 写 `iova >> 9`，最终 logical qword 的高位与 aligned
地址一致。direct-SGE 按 descriptor 顺序占 byte 32..63；SGB-SGE 从 slot byte 0 开始。

### 9.4 Atomic fixed body

| Logical qword | CAS | Fetch-add |
|---:|---|---|
| 1 | total length 8 | total length 8 |
| 2 | signature、SGE count 1、remote key | 同左 |
| 3 | remote VA | remote VA |
| 4 | local length 8、local lkey | 同左 |
| 5 | local IOVA | local IOVA |
| 6 | swap value | add value |
| 7 | compare value | zero |

atomic 不使用 general direct-SGE/SGB body，local/remote address 都要求 8-byte aligned。

### 9.5 UD body

| Logical qword | 字段 |
|---:|---|
| 1 | immediate[63:32]；VLAN/IPv6/tunnel/LAG/fwd/dst-vport/total-length[31:0] |
| 2 | signature[63:56]、SGE count[55:48]、DMAC[47:0] |
| 3 | priority/CFI/VLAN/PD index/flow label/source address index |
| 4 | SGB IOVA[63:9]、multicast bit 8、traffic class[7:0] |
| 5 | hop limit[63:56]、destination QPN[55:32]、QKey[31:0] |
| 6..7 | destination IP 16 bytes，按 driver `memcpy` 顺序 |

UD nonzero payload 始终使用 SGB，因为 byte 32..63 同时承载 AH metadata；不允许把
inline bytes或 direct SGE 覆盖到该区域。destination QPN和QKey来自 send request；
其余字段来自 request 的 `rdma_address_vector` value snapshot。

## 10. Signature 与 host-memory 提交顺序

signature 是 header 8 bytes、SQE byte 8..63 以及实际 SGB 内容的 byte-XOR 取反：

- direct/atomic/NONE 不加入 SGB；
- inline SGB 加入精确 payload length；
- SGE SGB 加入 `sge_count * 16` bytes；
- signature 字段计算时为零，插入后所有被覆盖 bytes 的 XOR 必须为 `8'hff`。

一次 post 的固定顺序为：

1. clone request/QP/QPC、验证 generation/state/capability、取得 per-QP posting lease；
2. reserve SQ credit；如有 staged non-inline payload，执行 writer 并取得 receipt；
3. 以 reserved index选择 SGB slot，构造 detached SGB 和完整 64-byte SQE image；
4. 建立 PREPARED record并用内部 tracking ID调用 `manager.track_outstanding()`；
5. 若使用 SGB，写完整 512-byte slot并完整 readback；
6. 写 SQE byte 8..63并 readback，然后最后写 header byte 0..7；
7. readback 完整 SQE，复算 signature，并验证 WQE/SGB bytes；
8. 用完整 SQE 的 byte 0..7 构造现有 `sq` doorbell descriptor；
9. 由 scheduler 执行 `RDMA_DB_BARRIER_DMA_MMIO` 后写 relative offset `0x100`；
10. commit producer cursor、slot ledger、outstanding record和 PSN，最后发布 result。

header-last 对应 driver `dma_wmb(); set_64bit_val(wqe, 0, hdr)`；scheduler 的 DMA→MMIO
barrier 对应 WQE 可见后再 notify。engine 不直接写 PCIe MMIO，也不把 SQE host-memory
write重复登记为 scheduler dependency。

任一 SGB/SQE write 发生后失败，即使 doorbell 尚未执行，也进入
`RECOVERY_REQUIRED`，因为 slot memory 可能只部分更新。所有外部调用前后检查绝对
deadline 与 Function generation。

## 11. PI、CI、credit、outstanding 与 PSN

### 11.1 Ring authority

现有 `rdma_queue_runtime` 仍是 PI/CI/wrap/used 的唯一 writer。per-QP posting lease覆盖
reserve 到 commit/recovery publication，避免两个 caller取得相同未提交 cursor。
`available = depth - used`；full 时不触碰 payload、SGB、SQE 或 doorbell。

CQE 根据 QPN/index/wrap释放连续 SQ slots，包括目标之前的 unsignaled WQE；每个 slot
释放时同时释放其 SGB reuse credit 和 outstanding record。完成不能跳过未投递或已释放
slot。CI、PI 和 valid polarity各自保持现有语义，不能用 24-bit PSN代替任何 cursor。

### 11.2 Outstanding record

live record 的外部 key 固定为 `(Function generation, QP handle identity, WR ID)`；同一
QP generation 不允许两个 live record使用相同 WR ID。record 保存：

```text
function_generation, qp_h, local_qpn, wr_id,
wqe_index, wqe_wrap, psn_valid, psn,
payload_mode, total_payload_len, sge_count,
wqe_image, optional sgb_iova/sgb_image,
optional payload_write_receipt, signaled, state
```

`state` 只取 `PREPARED`、`RECOVERY_REQUIRED`、`POSTED`、
`BOOKKEEPING_RECOVERY` 或 `RETIRED`。成功路径为 PREPARED→POSTED→RETIRED；
host-memory/doorbell失败进入 RECOVERY_REQUIRED；CQ 已消费但本地 retire未完成时进入
BOOKKEEPING_RECOVERY。RETIRED record在所有引用计数和 manager tracking清理后从 live
index移除。

所有 object/image/byte queue 都是 detached deep snapshot。pending recovery 与正常
posted record使用同一个对象和状态迁移，不复制第二个事实源。engine为每条 record
分配内部 nonzero tracking ID，并在首次 SGB/SQE write 前调用既有
`resource_manager.track_outstanding()`；CQ release或可证明 no-MMIO 的 abort完成后调用
`retire_outstanding()`。该内部 ID 不替代用户 WR ID，也不进入硬件 image。

ambiguous MMIO record保持 manager tracking，因此同 generation的普通 QP
modify/destroy继续返回 busy；`ABORT_AND_DETACH` 只能停止该 SQ facade继续工作，不能
伪造 retire。只有使整个 Function generation失效的 reset，或能证明硬件已 quiesce 的
控制面 recovery，才能清理这种 tracking 和 SGB authority。

### 11.3 WQE-level PSN

RC attachment 的初始 `next_psn` 来自 `rdma_qpc_rc_ext.send_psn`。candidate PSN 在
reserve 后写入 record，但不写入 SQE：pinned SQE header 的 `QP_SN` 只有 8 bit，来源是
`programmed_qpc.qp_sequence`，不是 24-bit PSN 的低八位。

只有完成 host-memory write/readback、doorbell scheduler成功和 producer/ledger commit
后，`next_psn` 才更新为 `(candidate_psn + 1) & 24'hff_ffff`。每个成功 WQE只加 1，
与 payload length、PMTU和 packet数无关。UD record 的 `psn_valid` 为 0，不推进 RC PSN。

known-no-MMIO recovery retry 复用 record 中的 candidate PSN、WQE image、SGB image和
receipt；不能重新分配 PSN。ambiguous MMIO 不回退或猜测推进 PSN，attachment保持
recovery状态，直至明确 teardown/reset。QP PSN显式 modify 只允许在 SQ 没有 live/
pending record时发生，并把 watermark重置为新的 programmed QPC值。queue-data engine
为同一 QP handle generation保留 PSN watermark；空 SQ detach/re-attach不会回到初始
PSN。只有显式 PSN modify成功或新的 QP generation才重新初始化。

## 12. Recovery、错误和输出原子性

- payload writer失败：无 queue side effect；返回原始 non-OK status。
- SGB/SQE write/readback失败：保存 exact images、cursor、PSN和 known-no-MMIO证据；
  允许 caller确认后 retry。
- scheduler明确未写 MMIO：允许 retry，同一 doorbell/image/PSN只提交一次。
- timeout、reset、missing PCIe completion 或可能已写 MMIO：禁止 retry；
  `ABORT_AND_DETACH` 不释放 SGB，也不把未知 WQE当作已完成。对应 Function generation
  必须经 reset/teardown失效后才能清理 retained authority。
- doorbell成功但本地 commit失败：视为可能已提交，保留 pending record和credit。
- CQ release后的本地 bookkeeping失败：CQE不重复消费，保留可重试的 bookkeeping
  record，PSN不受影响。

所有 public task/function 返回 non-null `rdma_status`。`result`、receipt和 query output
只在完整成功后赋值。失败不推进 PI/used/PSN、不发布 outstanding POSTED状态，也不释放
SGB slot。argument、unsupported opcode、queue full、stale generation、DMA permission/
translation、codec、PCIe和 recovery-required使用现有 status code。

caller request、QP/QPC、mapping receipt、WQE/SGB image在任何 host-memory或 scheduler
调用前 deep-clone。一个 QP 的 post 串行化；不同 QP可并行，继续服从现有 Function与
runtime lock order。

## 13. 测试与验证

### 13.1 Codec/golden

扩展 `queue.hex` 或新增独立 SQ payload golden，至少冻结：RC direct inline 1/32、
RC inline SGB 33/512、1/2 direct SGE、3/32 SGE SGB、SEND_WITH_IMM、WRITE_WITH_IMM、
READ、LOCAL_INVALIDATE、CAS、FAA、UD inline/non-inline，以及每种 signature。
测试完整 64-byte SQE、512-byte SGB、qword endian、raw UD destination-IP copy、reserved
bits、2 GiB length zero encoding和512-byte address alignment。

### 13.2 Engine/unit

新增 `rdma_sq_engine_test`，覆盖：

- QP attach capability、RTS/generation检查和重复 facade owner；
- payload mode boundary、overflow/null/zero SGE、max SGE/max inline和opcode shape；
- payload writer missing/registration/range/identity/permission/write/readback failure；
- SQ full、PI wrap、valid polarity、header-last write trace、SGB index对应和doorbell bytes；
- signaled/unsignaled连续 completion release、WR ID key collision和detached snapshots；
- PSN initialization、24-bit wrap、UD不推进、失败不推进、retry复用；
- known-no-MMIO retry、ambiguous MMIO禁止 retry、commit/bookkeeping recovery；
- concurrent same-QP serialization和不同QP独立推进；
- owned/borrowed SGB create rollback、normal destroy、reset retention和exactly-once cleanup。

### 13.3 Real host-memory 与回归

在 `10.11.10.53` 使用 `ubuntu` login shell运行 VCS。integration test必须使用真实
host-memory adapter，读取并核对 actual payload、SGB、SQE bytes和doorbell trace；
不得仅用 mock证明“真实 host-mem”路径。

最低验证集：

```text
scripts/run_vcs53.sh core rdma_sq_engine_test
scripts/run_vcs53.sh host_mem rdma_sq_engine_host_mem_test
scripts/run_vcs53.sh core regression
scripts/run_host_mem_regression53.sh
scripts/run_vcs53.sh xtr_defs regression
```

所有 VCS test要求 `UVM_WARNING=0`、`UVM_ERROR=0`、`UVM_FATAL=0`；Python unit tests和
definition checker全部通过。build/cache、simulation logs、SSH wrapper、外部 host_mem
源码和环境文件不得提交。

## 14. 文件与命名约束

预期实现影响：

- 新增 `src/core/rdma_sq_engine.sv`、`src/core/rdma_sq_payload_writer.sv`；
- 修改 `src/core/rdma_queue_data_engine.sv`、`rdma_queue_runtime.sv`、
  `rdma_qp_lifecycle_executor.sv`、`rdma_resource_manager.sv` 和
  `rdma_core_pkg.sv`；
- 修改 `src/model/rdma_semantic_requests.sv`、`rdma_queue_models.sv`、
  `rdma_queue_lifecycle_models.sv`、`rdma_resources.sv`；
- 修改 `src/codec/xtr_v1/rdma_xtr_v1_queue_codecs.sv`、source map、checker和golden；
- `src/codec/xtr_v1/rdma_xtr_v1_defs.svh` 与
  `rdma_xtr_v1_image_masks.svh` 只承载真正的宏/bit-mask定义，可以保留 `.svh`；
- 新增/修改的 class、package、test 和普通 source一律使用 `.sv`，不新增普通 `.svh`；
- 新增 `tests/unit/rdma_sq_engine_test.sv`、
  `tests/integration/rdma_sq_engine_host_mem_test.sv` 并注册到
  `tests/rdma_unit_test_pkg.sv` 与 VCS file list。

不做与本功能无关的扩展名批量改写或重构；远端提交只包含源代码、测试、golden、
checker/source-map和设计/计划文档。

## 15. 验收标准

本设计实现完成的判定是：

1. RC/UD 的每种支持 shape都生成与 pinned driver一致的 WQE/SGB bytes和signature；
2. inline payload进入 WQE/SGB，staged non-inline payload只能经可验证 writer写入真实
   host-memory，普通 non-inline payload不会被 engine静默改写；
3. PI/CI/credit、SGB slot、doorbell barrier和completion release只有一个 runtime事实源；
4. WQE-level PSN只在完整 commit后 modulo-24推进，retry复用，且从不混同8-bit QP_SN；
5. outstanding证据包含 generation/QP/WR ID、cursor、PSN、mode、SGE count和detached
   images；
6. 所有 failure/recovery路径保持输出原子性、generation fence和SGB ownership；
7. 指定 VCS、真实 host-memory、Python checker与全量回归全部通过，仓库无环境产物。
