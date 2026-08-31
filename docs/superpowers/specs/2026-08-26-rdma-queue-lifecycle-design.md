# RDMA Task 14B CQ/SRQ/CEQ/AEQ 生命周期设计

日期：2026-08-26
状态：已实现；完成证据由 `scripts/run_queue_lifecycle_regression53.sh`、
`tools/check_queue_lifecycle.py` 和 host_mem integration test 提供

## 1. 目标

Task 14B 在 Task 14A 已完成的事务、CMQ port、resource manager、generation
fence 和 ERROR recovery 基础上，实现 CQ、SRQ、CEQ、AEQ 的完整控制面生命周期：

1. 为四类队列提供类型化 create/destroy API；
2. 同时支持 control-plane-owned 和 caller-borrowed queue payload backing；
3. 根据语义请求推导 entry/stride、容量、页布局和硬件 context；
4. 在 create CMQ 前初始化 ring、4 KiB page directory 和 context shadow；
5. 以同一事务执行器统一 CMQ、registry、回滚和 recovery 语义；
6. 把 VF DMA domain 和 MSI-X vector 映射作为 Function binding 的输入，而不把
   PCIe env、AXIS env 或具体 VIP 变成核心依赖；
7. 为 Task 14C 的 QP queue/backing 生命周期提供可复用边界。

成功实现后，独立 UVM core test 可以使用 mock adapter 完整验证队列资源事务；真实
DUT 环境可以通过现有 host_mem adapter 和 Function binding adapter 使用同一控制面。

## 2. 本轮不做的内容

- CQE、CEQE、AEQE 的生产或消费；
- SRQ WQE 的构造、投递和 doorbell；
- CQ resize、shared/URC fragment CQ，以及 BASIC 以外的 SRQ type；
- BAR/MMIO 访问、doorbell scheduler 或真实中断处理；
- QP create/modify/destroy；
- lifecycle 自动生成 `DIRECT_4K`、`HUGE_2M` 或 `L3_INDIRECT_4K` backing；这些
  mode 继续保留在 model/codec 中；
- 新建一套通用 shadow page pool；CQ/SRQ 必须消费 Function HMC/GRM context manager
  提供的 context slot；
- PCIe env、AXIS env、host_mem 实现类或任意 VIP 的固定实例化；
- 修改已冻结的 xtr_v1 context 位域、opcode 或 CMQ envelope。

Task 14B 只实现资源控制面。队列运行时 PI/CI 推进、entry 编解码和 doorbell 属于后续
数据面任务。

## 3. 事实基线

### 3.1 Task 14A 已有能力

- `rdma_control_plane` 已提供 transaction ID、per-Function semaphore、post-lock
  generation fence、同步 `rdma_cmq_port`、逆序回滚和持久化 recovery。
- `rdma_resource_manager` 已提供 `ALLOCATED -> PROGRAMMED -> ACTIVE ->
  QUIESCING -> RELEASED/ERROR` 的受控提交接口。
- `rdma_resource_manager.create_cq/create_srq/create_ceq/create_aeq()` 已能预留
  identity，并记录 CQ→CEQ、SRQ→PD 等静态依赖。
- `rdma_host_mem_api` 已提供 64-bit mapping 的 allocate/write/read/release；PCIe
  32 MiB BAR aperture 与 DMA backing 地址空间彼此独立。
- `rdma_hmc_allocator` 只管理强类型 FVM lease，不提供 HMC/GRM context backing 的
  DMA 地址、CPU view 或写接口。
- `rdma_recovery_record` 已能保存 CMQ ticket、硬件存在性、backing authority 和逐步
  cleanup 进度，但现有 `recover_resource()` 的具体硬件步骤仍只支持 MR。

### 3.2 已有模型与 codec

- 语义请求已有 CQ/SRQ/CEQ/AEQ 的 depth、CQ→CEQ 和 SRQ→PD 基础字段。
- `rdma_cqc_model`、`rdma_srqc_model`、`rdma_ceqc_model`、`rdma_aeqc_model`
  已定义 context 语义。
- xtr_v1 已支持四类 context 的 create/delete/query codec。
- CQE size 的 xtr_v1 合法值为 32、64、128 bytes。
- CQ、CEQ、AEQ 使用 `rdma_page_table_layout`；SRQ 使用 object mode、queue base
  和独立 shadow base。

当前模型还没有定义普通 queue page-directory entry，也没有表达真实 SRQ 所需的
SRQ ring、SRFQ ring 和可选 SGB 三类 payload backing。Task 14B 必须先补齐这些语义
对象，不能只在 control plane 内用裸 byte 临时构造。

### 3.3 53 上真实驱动基线

审计来源为：

```text
10.11.10.53:/home/ubuntu/workspace/Desktop.zip
dpu_kernel_rdma-version_0.1.32/
```

真实驱动固定了以下 Task 14B 语义：

- `alloc.h` 标记 DIRECT mode 为 “NOT used”。普通 4 KiB queue backing 使用
  `INDIRECT`：一个 4 KiB PD table 加若干 4 KiB payload page。
- `alloc.c` 的 PD entry 为 big-endian 64 bit：PBA `[63:12]`、RDMA VF ID
  `[11:4]`、valid bit `[0]`，其余 bit 为 0。
- 一个 PD table 有 512 个 8-byte entry，最多覆盖 512×4 KiB = 2 MiB；超过
  2 MiB 的真实驱动路径使用 L3 indirect，本任务不实现。
- CQ 的 `CQC_SHADOW_PA` 实际写 CQC context base；shadow view 位于 64-byte
  CQC 的 offset 48，长度 8 byte。
- SRQ shadow 位于 GRM 分配的 SRFQC context，offset 28，长度 4 byte；SRQC
  shadow 字段使用 context manager 返回的 page-aligned pointer base。
- CEQ/AEQ context 写入 MSI-X vector 的 global index，而 Linux/Function 层同时保存
  local table index；共享 MSI-X 配置允许 AEQ/CEQ 共用 vector。
- SRQ create 同时准备 64-byte SRQ ring、64-byte SRFQ ring；`max_sge > 2` 时还准备
  每 WQE 512-byte SGB backing。SRQC 只直接编码 SRFQ page-directory base，其他
  backing 由 SRQ 数据面 entry 使用。
- CQC create 将 load-CI threshold 编码为 2（queue size/4）、`load_ci_done=1`、
  `last_arm_sn=1`、当前 `arm_sn=0`；SRQC load-PI threshold 为 8，create 时有效的
  SRQ limit 至少为 16 且硬件粒度为 4。
- kernel queue backing 的初始字节为零；软件侧 CQ/CEQ/AEQ 初始期望 polarity 为 1，
  SRFQ WQE polarity seed 为 0。
- CQ destroy 在 CQC delete 成功后 OCC-flush CQ PD；SRQ destroy 在 SRQC delete
  之前分别 OCC-flush SRFQ PD 和 SRQ PD；CEQ/AEQ 不执行该 PD flush。

## 4. 已确认的设计选择

1. Task 14B 只实现 lifecycle，不实现队列数据面行为。
2. CQ/EQ ring 以及 SRQ/SRFQ/SGB payload 同时支持 owned 和 borrowed；borrowed 不
   转移释放责任。
3. borrowed 输入必须是已有的 Function-scoped mapping slice，不能传裸 DMA 地址。
4. 普通 destroy 遇到 live dependent 返回 `RDMA_SC_RESOURCE_BUSY`，不级联销毁。
5. 公共请求只暴露语义参数；entry/stride、页布局和 context 默认字段由 typed builder
   推导。
6. lifecycle 首版只生成 `INDIRECT_4K`，每个 ring 最大 2 MiB；direct/huge/L3
   保留 model/codec，但 create 请求明确返回不支持。
7. payload ownership 与内部 metadata ownership 分离：payload 可 owned/borrowed；
   PAGE_DIRECTORY 和 CONTEXT_SHADOW 始终由 control plane/context manager 管理。
8. CEQ/AEQ 使用 Function-local vector；Function binding 负责映射到硬件 vector 和
   MSI-X table entry。
9. create 前由 control plane 初始化 owned/borrowed payload、page directory 和
   context shadow；borrowed 只描述 allocation ownership，不描述内容 ownership。
10. delete 状态不确定时保留 identity、依赖和全部 backing，进入
    `ERROR/RECOVERY_REQUIRED`。
11. CQ/SRQ 的 PD-cache flush 顺序跟随真实驱动，并成为可恢复事务步骤。
12. 采用“复合 backing plan + 通用 lifecycle executor + 类型化 policy”，不复制四套
    事务，也不引入任意声明式脚本引擎。

## 5. 总体架构

```text
typed create/destroy request
             |
             v
      rdma_control_plane
             |
             v
rdma_queue_lifecycle_executor
   |        |         |          |           |
   |        |         |          |           +--> rdma_cmq_port
   |        |         |          +--------------> rdma_host_mem_api
   |        |         +-------------------------> rdma_context_backing_api
   |        +-----------------------------------> resource-specific policy/builder
   +--------------------------------------------> rdma_resource_manager/HMC allocator
```

`rdma_control_plane` 保留公共 API、transaction ID、Function lock 和 generation fence。
它把队列事务委托给一个内部 `rdma_queue_lifecycle_executor`。executor 只实现一次公共
顺序、回滚和 recovery，不识别 xtr_v1 位域。

每个资源提供一个类型化 policy：

```text
CQ policy   -> layout + CQC create/delete/query + post-delete PD flush
SRQ policy  -> layout + pre-delete SRFQ/SRQ PD flush + SRQC create/delete/query
CEQ policy  -> layout + CEQC create/delete/query
AEQ policy  -> layout + AEQC create/delete/query
```

policy 的窄职责为：校验资源特有请求、调用对应 resource-manager reservation、推导
backing plan、生成初始化图像、构造硬件 model，以及返回 create/delete/query command
descriptor。policy 不执行 CMQ、不提交 registry、不释放 mapping。

新增窄接口 `rdma_context_backing_api`，把 Function HMC/GRM context manager 隔离在
adapter 后面。它按 Function、resource kind 和 local ID acquire/release context slot，
返回强类型 slot token、HMC lease、硬件需要的 shadow pointer base，以及可写 shadow
view。生产 adapter 包装真实 HMC/GRM；mock adapter 可以用 host_mem 模拟。HMC FVM
address、context DMA address、queue payload IOVA 和 host_mem backing address 保持不同
强类型，不能互相强制转换。

executor 的窄职责为：获取并验证权威输入、执行公共事务顺序、记录完成步骤、调用 policy、
执行 CMQ、提交资源状态、逆序回滚和持久化 recovery。executor 不手工拼接 bit，也不
down-cast 到 PCIe/host_mem 生产 adapter。

## 6. 公共 API 与语义请求

`rdma_control_plane` 增加：

```text
create_cq(binding, request, cq, result)
destroy_cq(binding, request, result)
create_srq(binding, request, srq, result)
destroy_srq(binding, request, result)
create_ceq(binding, request, ceq, result)
destroy_ceq(binding, request, result)
create_aeq(binding, request, aeq, result)
destroy_aeq(binding, request, result)
```

destroy 继续使用带 `target_h` 的语义请求，但 typed API 必须校验 target kind。调用者
不能通过 CQ destroy API 删除其他资源。

identity reservation 后、任何 backing allocation 前校验 xtr_v1 local object-ID 宽度：
CQ 为 21 bit、SRQ 为 16 bit、CEQ/AEQ 为 12 bit。超宽 identity 立即释放 reservation，
不依赖 codec 截断，也不产生 host_mem/context side effect。

创建请求字段为：

| 请求 | 调用方字段 | builder 推导字段 |
|---|---|---|
| CQ | `depth`、`cqe_size_bytes`、可选 `ceq_h`、CQ ring spec | CQ ring/PD、CQC context slot、threshold、PI/CI/wrap |
| SRQ | `depth`、`max_sge`、`limit_threshold`、`pd_h`、SRQ payload spec | 64-byte SRQ/SRFQ rings、两个 PD、可选 SGB、SRFQC slot、initial PI |
| CEQ | `depth`、Function-local `vector_id`、CEQ ring spec | 16-byte CEQE ring、PD、page layout、PI/CI/wrap |
| AEQ | `depth`、Function-local `vector_id`、AEQ ring spec | 16-byte AEQE ring、PD、page layout、PI/CI/wrap |

CQ 的 `cqe_size_bytes` 只接受 32、64、128；默认值为 64。所有 ring 的 4 KiB
round-up 大小不得超过 2 MiB。SRQ 的 `max_sge` 必须满足
`1 <= max_sge <= capability.max_wq_sge`；大于 2 时 builder 增加每 WQE 512-byte SGB
role。`limit_threshold` 使用 entry 数为语义单位，默认 16，必须在 16 到 depth 之间且为
4 的倍数；builder 除以 4 后写入 14-bit SRQC 字段。CEQ/AEQ entry size 是 profile
常量，不成为调用方参数。

2 MiB/512-page 上限只约束有 PD 的 ring role。SGB 不通过 SRQC page directory 寻址，
其 `checked(depth * 512)` 大小单独受 Function `max_sgb_bytes` 和 host_mem mapping 上限
约束；本任务不错误地把一个 PD 的覆盖上限套到 SGB。

Task 14B 的 CQ 固定为非 shared、`urc_enable=0`，SRQ 固定为 BASIC type；公共 create
请求不暴露这些 variant selector。后续任务若增加 shared/URC CQ 或扩展 SRQ type，必须
新增 typed request/policy，不能复用 unchecked flags 改写本任务 builder。

Task 14B 镜像真实驱动安全初值：CQC threshold 字段编码值为 `2`（queue size/4）、
`load_ci_done=1`、`urc_enable=0`、`last_arm_sequence=1`、当前 arm sequence 为 0、
arm state 为 NO_EVENT；SRQC load-PI threshold 为 8、arm sequence 为 0。需要 URC 或
运行时 arm 行为时由后续数据面 API 修改，不在 create 请求中暴露裸字段。

## 7. Backing 数据模型与布局

### 7.1 payload spec、slice 和 plan

公共 `rdma_queue_backing_spec` 描述 payload ownership，其 mode 只有：

```text
RDMA_QUEUE_BACKING_OWNED
RDMA_QUEUE_BACKING_BORROWED
```

owned spec 不携带 mapping。borrowed spec 按 payload role 携带一个或多个
`rdma_queue_backing_slice`：

```text
role
mapping
mapping_offset
length
logical_queue_offset
```

slice 引用现有 `rdma_dma_mapping`。设备可见 page address 由 mapping 的 64-bit
`iova + checked offset` 得到；mapping 的 `backing_addr` 只由 host_mem adapter 用于
read/write，不得写入 PD entry 或 queue context。公共 API 不接受裸 `dma_addr`、`iova`
或物理地址整数。

CQ/CEQ/AEQ 各有一个 ring payload。SRQ 的 payload mode 同时应用于 SRQ_RING、
SRFQ_RING 和条件性的 SGB：borrowed 模式必须完整提供这些 role，owned 模式由 control
plane 全部分配。PAGE_DIRECTORY 和 CONTEXT_SHADOW 不属于公共 payload spec，始终由
control plane/context manager 创建；因此真实驱动所需的 role-specific ownership 不被
误判为 caller 请求的“混合模式”。

builder 生成权威 `rdma_queue_backing_plan`，包含：

- 每个 ring 的 entry/stride、logical bytes、4 KiB round-up 大小和 payload slice；
- 每个 ring 对应的 4 KiB page-directory mapping 和 entry 图像；
- CQ/SRQ context slot、shadow pointer base 和 shadow view；
- 每个 role 的 alignment、required length、ownership 和 cleanup policy；
- context 使用的最终 64-bit device-visible queue IOVA。

borrowed payload 缺少 role、出现多余 role、logical range 重叠/有洞或长度不足时，在
identity reservation 前失败。不同 payload role 的 device-IOVA range 和 host backing
range 也不得互相重叠；允许复用同一个 mapping，但 slice 必须互不相交。ring slice 必须
覆盖完整 `ring_storage_bytes` 而不只是 logical bytes。

### 7.2 role 与所有权

新增单一 `rdma_queue_backing_role_e`，其合法值固定为：

```text
CQ_RING, SRQ_RING, SRFQ_RING, SRQ_SGB, CEQ_RING, AEQ_RING,
CQ_PD, SRQ_PD, SRFQ_PD, CEQ_PD, AEQ_PD,
CQC_CONTEXT_SHADOW, SRFQC_CONTEXT_SHADOW
```

公共 borrowed spec 只接受前六个 payload role；后七个 metadata role 只能由 builder/
executor 生成。这样 plan、registry、recovery 和 failure injection 使用同一组稳定 tag，
不依赖数组下标推断资源含义。

| 资源 | payload role（owned 或 borrowed） | 内部 metadata role（始终 control-plane-managed） |
|---|---|---|
| CQ | `CQ_RING` | `CQ_PD`、`CQC_CONTEXT_SHADOW` |
| SRQ | `SRQ_RING`、`SRFQ_RING`、条件性 `SRQ_SGB` | `SRQ_PD`、`SRFQ_PD`、`SRFQC_CONTEXT_SHADOW` |
| CEQ | `CEQ_RING` | `CEQ_PD` |
| AEQ | `AEQ_RING` | `AEQ_PD` |

SRQ_RING 和 SRFQ_RING 都使用 64-byte entry，并具有相同 depth。`max_sge <= 2` 时
没有 SGB role；`max_sge > 2` 时 SGB logical size 为 `depth * 512` bytes。SGB 不由
SRQC 直接寻址，但其 mapping authority 必须随 SRQ 资源保存，供后续 SRQ WQE 数据面
使用。

每个 ring 有独立 PD mapping。SRQ 因此有 SRQ_PD 和 SRFQ_PD 两个可独立 flush/release
的 metadata role。PAGE_DIRECTORY 永远不由 borrowed caller 提供，避免调用方伪造
VF ID、valid bit 或 page list。

### 7.3 xtr_v1 4 KiB page directory

所有 Task 14B lifecycle queue 固定使用 `RDMA_OBJECT_INDIRECT_4K`：

```text
ring_bytes         = checked(depth * entry_or_stride_bytes)
ring_storage_bytes = align_up(ring_bytes, 4096)
page_count         = ring_storage_bytes / 4096
```

`ring_storage_bytes` 必须在 4 KiB 到 2 MiB 之间，`page_count` 必须在 1 到 512
之间。即使只有一个 payload page，也创建 PD；Task 14B 不自动生成 DIRECT/HUGE/L3。

新增类型化 `rdma_xtr_v1_queue_pd_entry` 和独立 page-entry codec；其输入持有
`rdma_iova_t page_iova`，不接受 host backing address。每个 entry 为
big-endian 64 bit：

```text
[63:12] payload page DMA address >> 12
[11:4]  binding.rdma_vf_id[7:0]
[3:1]   0
[0]     valid = 1
```

一个 4 KiB PD 有 512 个 entry。前 `page_count` 个 entry 按 logical page 顺序编码，
其余 entry 必须清零。page-entry ABI 新增在聚焦的 queue-page codec 文件中，不修改已经
冻结的 xtr_v1 context/opcode definitions；对应 checker/test 固定字段和 big-endian
序列化结果。

backing plan 以 `rdma_queue_dma_page_ref` 保存 mapping ref、mapping offset 和 checked
`rdma_iova_t page_iova`。现有 hardware model 中名称为 `rdma_backing_addr_t` 的 queue-base
字段只能通过一个聚焦的 `from_iova()` checked constructor 从该 `page_iova` 投影；禁止从
`mapping.backing_addr` 赋值。该限制由静态 checker 和 IOVA/backing 不同值的 test 固定。

context builder 的投影为：

- CQC：mode=INDIRECT，`current_base=next_base=CQ_PD`，两个 valid bit 为 1，
  `sd_base=0`；
- SRQC：mode=INDIRECT，`srfq_backing=SRFQ_PD`；SRQ_PD 保存在资源快照中，供后续
  SRFQE/WQE 和 destroy flush 使用；
- CEQC/AEQC：mode=INDIRECT，`current_base=next_base=EQ_PD`，current base valid；
  EQC 没有独立 next-valid 位。

owned ring payload 可以是一段连续 mapping，也可以由 allocator adapter 返回多个 4 KiB
page mapping；borrowed ring payload 允许一个 mapping 的多个 slice 或多个 Function-scoped
mapping。两种模式都必须形成无洞、按 4 KiB 对齐的 logical page list。SGB 同样必须无洞；
每个 WQE 对应的 512-byte SGB slot 必须完整落在一段连续、512-byte 对齐的 DMA range 中。
BAR aperture 不参与 page DMA address 计算。

### 7.4 HMC/GRM context-shadow backing

CQ/SRQ 不通过 host_mem 单独分配 shadow buffer。`rdma_context_backing_api.acquire()`
返回 `rdma_context_backing_ref`，至少包含：

```text
owner/function generation
resource kind + local object ID
opaque context-slot token
HMC lease/reference
shadow_pointer_base used by CQC/SRQC
context slot view offset + length
shadow view offset + length
release_complete
```

CQC context slot 为 64 byte、64-byte 对齐；CQC 编码 `shadow_pointer_base`，shadow view
位于 offset 48、长度 8。SRFQC adapter 返回 SRQC 需要的 4 KiB-aligned pointer base，
shadow view 位于 context offset 28、长度 4。executor 只通过 context API 写 context slot/
shadow view，不能把 HMC FVM address 当作 host DMA address 写入 context。

接口契约保持窄且可 mock：

```text
acquire(binding, resource_kind, local_id, ref, status)
write(ref, slot_relative_offset, bytes, status)
release(ref, status)
query_release_completion(ref, complete, status)
```

`write()` 必须对 ref 授权的 slot/view 做 checked bounds 校验，不得覆盖共享 page 中的相邻
slot。`release()` 只消费 ref 内的 opaque token；失败或 timeout 后由 completion query
区分“未执行”和“已执行但结果丢失”。

context backing page 可以由真实 HMC/GRM manager 在多个 context slot 间共享；资源只
拥有自己的 slot token。destroy 调用 `release(slot_token)`，是否回收底层 page 由 adapter
决定。slot token 和 HMC release authority 必须支持与 Task 14A owned mapping 等价的
clone、completion-query 和 exactly-once release contract。

### 7.5 authority 与资源快照

每个 payload/PD reference 保存 role、slice range、ownership、cache-flush 状态和
release-complete。owned mapping 的 opaque release authority 必须按 Task 14A clone
contract 保留；borrowed mapping 只保存不可变投影，永不获得 release capability。

borrowed caller 必须保证所有 payload mapping 在资源达到 RELEASED，或可信 Function
teardown 完成之前一直有效且不被复用。registry/recovery 中保留 borrowed reference 是
驱动侧的生命周期证据，不能替代 caller 的该项契约。

`rdma_cq`、`rdma_srq`、`rdma_ceq`、`rdma_aeq` 的权威 registry snapshot 增加：

- 每个 ring 的 entry/stride、logical bytes、PD layout、initial polarity seed 和
  role-tagged refs；
- CQ 的 CQE size、CQC context ref；
- SRQ 的 max-SGE、limit threshold、SRQ/SRFQ/SGB refs 和 SRFQC context ref；
- CEQ/AEQ 的 Function-local/resolved hardware vector；
- 每个 type-specific OCC-flush target 和完成位。

OCC target 使用类型化 `rdma_queue_flush_target`，字段固定为 backing role、
`PRE_DELETE/POST_DELETE` phase、PD ref 和 flush-complete。CQ plan 有一个
`CQ_PD/POST_DELETE` target；SRQ plan 依次有 `SRFQ_PD/PRE_DELETE`、
`SRQ_PD/PRE_DELETE` 两个 target；CEQ/AEQ 列表为空。

destroy/recovery 只读取权威 snapshot，不能重新解释原始 create request。

## 8. Function、VF、DMA 与 MSI-X 绑定

### 8.1 DMA mapping 校验

`rdma_function_binding` 增加不可变 queue-DMA context snapshot：requester BDF、
`pasid_valid/pasid` 和 DMA domain ID。无 PASID 的真实驱动路径显式使用
`pasid_valid=0, pasid=0`，不能用未初始化值表示。`rdma_dma_request_context` 和
`rdma_dma_mapping` 相应增加 DMA-domain 字段，使 domain 检查成为 model contract，
而不是 PCIe adapter 的旁路约定。

owned allocation 在 identity reservation 后从该 snapshot 和新资源 handle 构造
`rdma_dma_request_context`；caller 不能为 owned queue 注入另一 BDF/PASID/domain。
borrowed payload mapping 必须与同一 snapshot 完全匹配。

所有 borrowed slice 和 host_mem 返回的 owned mapping 都必须匹配当前权威 Function
binding：

- Function UID、global Function ID 和 generation；
- requester BDF，以及 mapping 使用时的 PASID；
- DMA domain ID；
- ACTIVE mapping state 和所需读写方向；
- checked `offset + length` 范围；
- role 对齐和 64-bit 地址无溢出。

mapping authority 与 Function binding 不匹配时返回 invalid/stale 状态，不发送 CMQ。
BAR base/size 只用于 MMIO decode，不参与上述 DMA 地址检查。

xtr_v1 policy 的最小设备方向为：CQ/CEQ/AEQ ring 需要 DEVICE_WRITE，
SRQ_RING/SRFQ_RING/SGB 和所有 PD 需要 DEVICE_READ；BIDIRECTIONAL mapping 可以满足任一
方向。host_mem write 是 CPU/adapter 初始化动作，不改变该设备方向定义。

### 8.2 queue capability snapshot

`rdma_function_binding` 增加不可变 queue capability snapshot，至少包含：

```text
min/max CQ depth
min/max SRQ depth
max CEQ/AEQ depth
max WQ SGE
max queue ring bytes
max SGB bytes
```

PCIe/device adapter 从真实硬件 attributes 填充，standalone mock 显式提供测试值。
Task 14B 对 ring 同时校验 capability、xtr_v1 字段宽度和本任务 2 MiB indirect 上限，
三者取最严格限制；SGB 按上一节的独立上限校验。`rdma_vf_id` 必须能放入 PD entry 的
8-bit VF field。

### 8.3 interrupt vector snapshot

`rdma_function_binding` 增加类型化 interrupt mapping snapshot。每项包含：

```text
function_local_vector
hardware_eq_vector
msix_table_index
enabled
```

PCIe adapter 在 Function discovery/bind 阶段读取 capability 和 MSI-X table，构造该
snapshot。standalone test 可以使用 identity mapping。CEQ/AEQ create 查找请求中的
Function-local vector，验证 enabled 和字段宽度，并把 `hardware_eq_vector` 写入 EQC。

Task 14B 借用 interrupt mapping，不拥有 MSI-X 配置：

- EQ destroy 不关闭 MSI-X entry；
- 不直接读写 PCIe config/BAR；
- 不在 Task 14B 内强制 vector 独占。若设备要求独占，由 Function interrupt allocator
  在 binding 阶段发放不可冲突的 local vector；
- generation 改变后旧 snapshot 不可用于新 create/recovery。

## 9. Backing 初始化与可见性

owned 和 borrowed payload 使用同一初始化路径：

1. policy 生成全零 CQ/EQ/SRQ_RING/SRFQ_RING 图像；存在 SGB 时也将整个 SGB role
   清零。资源 snapshot 同时保存 CQ/CEQ/AEQ 初始期望 polarity=1、SRFQ posting
   polarity seed=0，作为后续数据面 handoff；
2. executor 通过 `rdma_host_mem_api.write()` 初始化全部 payload storage；
3. policy 生成每个 PD 的 512 个 big-endian entry，executor 写入 control-plane-owned
   PD mapping；
4. CQC builder 从同一个 typed model 生成 create CMQ context 和 canonical 64-byte context
   slot image；executor 通过 `rdma_context_backing_api` 写完整 slot，其中 offset 48 的
   8-byte shadow view 编码 CI=0、CI-wrap=0、arm-sequence=0、arm-state=NO_EVENT；
5. SRQC builder 从 typed model 生成 create CMQ context；executor 通过 context API 将
   offset 28 的 4-byte SRFQC shadow view 写成 PI=0、PI-wrap=0、`limit_threshold/4`、
   arm-sequence=0，不覆盖 adapter 未授权的相邻 slot；
6. CEQC/AEQC 的 PI、CI 和 wrap 全为 0；
7. payload、PD、context view 的写入全部成功后才允许提交 create CMQ。

初始化必须覆盖 DUT 在 create 后可能预取的整个 `ring_storage_bytes`，包括最后一个 page
中 logical ring 以外的 padding；存在 SGB 时覆盖整个 SGB role，不能只写第一个 entry。
借用 mapping 的调用方必须允许 control plane 写入；borrowed 只表示“不负责释放”。如果
create 后续失败，control plane 不保存并恢复 borrowed mapping 的旧字节，调用方会看到
已经初始化的内容。

`rdma_host_mem_api.write()` 和 context API write 的成功是 UVM 层面的可见性边界。
生产 adapter 必须在返回成功前保证 DUT DMA 可见所需的写完成/内存屏障；core control
plane 不直接调用 PCIe flush 或 VIP 专有 API。

## 10. Create 事务

每个 create 在对应 Function lock 内执行：

```text
validate configured control plane
-> snapshot and validate ACTIVE Function binding
-> acquire Function lock
-> revalidate Function/generation
-> policy preflight derives layout requirements and validates request, dependencies,
   vector and borrowed mappings
-> reserve resource identity (ALLOCATED)
-> materialize the authoritative backing plan from the preflight result
-> allocate owned payload or revalidate borrowed payload slices
-> allocate one control-plane-owned PD for each ring
-> CQ/SRQ: acquire HMC/GRM context-shadow slot
-> attach complete resource snapshot with stage_allocated()
-> build and validate typed hardware context and initialization images
-> initialize PAYLOAD -> PD -> CONTEXT_SHADOW
-> execute create CMQ
-> generation fence
-> commit_programmed()
-> activate()
```

资源只有 `activate()` 成功后才对调用方返回 ACTIVE。没有任何 create 路径发送 doorbell
或访问 BAR。

allocation/acquire 的规范顺序为 payload roles、各 ring 的 PD、CQ/SRQ context slot。
SRQ 的 payload role 顺序固定为 SRQ_RING、SRFQ_RING、条件性 SGB，PD 顺序固定为
SRQ_PD、SRFQ_PD；其他资源只有一个 ring/PD。cleanup 使用该顺序的逆序。
每个成功动作立即进入运行中事务记录；因此后续步骤失败时已经取得的 release authority
不会丢失。borrowed preflight 必须在 identity reservation 前拒绝静态非法输入；
reservation 后的 materialization/revalidation 负责填入 identity-dependent address/context
slot，并防止 authority 在事务边界发生变化。

### 10.1 create 回滚

回滚只撤销已经成功的步骤，并严格逆序：

- create CMQ 提交前失败：按 context slot、PD、owned payload 的逆序释放；borrowed
  payload 不 release，最后 `release_reserved()`；
- create CMQ terminal failure 且协议明确证明对象未创建：按提交前失败处理；
- create CMQ 成功，但 generation fence、commit 或 activate 失败：执行资源 policy 的
  完整硬件清理计划；CQ 为 delete→CQ_PD OCC flush，SRQ 为 SRFQ_PD flush→SRQ_PD
  flush→delete，CEQ/AEQ 为 delete；
- 硬件清理全部成功：再释放 context slot、PD、owned payload 和 reservation；
- create/delete/OCC timeout、reset-cancel 或结果丢失：保留 identity、依赖和全部 backing，
  标记 ERROR 并持久化 ambiguous ticket。

borrowed payload 不调用 release，但 recovery record 仍保存其 role/authority；caller 必须
遵守第 7.5 节的有效期契约。

## 11. Destroy 事务

普通 destroy 的公共前置步骤是：

```text
validate target kind and authoritative Function/generation
-> acquire Function lock and revalidate
-> lookup ACTIVE authoritative snapshot
-> begin_quiesce() atomically checks dependents/outstanding
-> execute the resource policy's ordered hardware cleanup plan
-> execute the ordered local cleanup plan
-> finalize_release()
```

`begin_quiesce()` 遇到 live dependent 或 outstanding operation 返回
`RDMA_SC_RESOURCE_BUSY`，资源保持 ACTIVE，且不发送任何 flush/delete CMQ。
具体包括 CQ 被 QP 引用、SRQ 被 QP 引用、CEQ 被 CQ 引用；PD 销毁时被
SRQ 引用也继续遵守同一 resource-manager 规则。

硬件 cleanup 顺序不能被通用 executor 重排：

| 资源 | 必须的硬件顺序 | 硬件安全后的本地 cleanup 顺序 |
|---|---|---|
| CQ | `CQC_DELETE` 明确成功/证明 ABSENT → OCC-flush `CQ_PD` | release CQC context slot → release `CQ_PD` → release/detach `CQ_RING` |
| SRQ | OCC-flush `SRFQ_PD` → OCC-flush `SRQ_PD` → `SRQC_DELETE` 明确成功/证明 ABSENT | release SRFQC context slot → release `SRFQ_PD` → release `SRQ_PD` → release/detach SGB、SRFQ ring、SRQ ring |
| CEQ | `CEQC_DELETE` 明确成功/证明 ABSENT | release `CEQ_PD` → release/detach `CEQ_RING` |
| AEQ | `AEQC_DELETE` 明确成功/证明 ABSENT | release `AEQ_PD` → release/detach `AEQ_RING` |

每个 OCC target 都从权威 snapshot 取得 role 和 PD backing，policy 为它构造
xtr_v1 OCC command。只有该 command 的可信 terminal success 才证明该 target
flush-complete；“已发送”或对象 QUERY 结果不能替代该证明。CQ delete 成功但
`CQ_PD` flush 失败时，硬件对象已 ABSENT，不能恢复 ACTIVE；必须保留 context
slot、PD 和 payload 进入 ERROR。

SRQ 的两个 flush 是 pre-delete barrier。前一个 target 未明确成功时不得发送
后一个 target；两个 target 未全部明确成功时不得发送 `SRQC_DELETE`。
在普通 destroy 中，pre-delete flush 或 delete 的 terminal failure 若明确保证未发生
destructive change，可以 `restore_active()`；flush/delete timeout 或结果丢失时不得继续
后续命令，资源进入 ERROR。create rollback 不能向调用方暴露部分创建的
ACTIVE 对象，因此同样的明确 flush failure 会保留 PRESENT ERROR 资源供
recovery 重试。

SRQ pre-delete flush 的完成证明只对当前 quiesce/cleanup attempt 有效。normal destroy
若 `restore_active()`，必须在同一 registry transaction 中清除该 attempt 的两个
flush-complete 位和 ticket；资源重新 ACTIVE 后可能再次访问 PD，下一次 destroy 必须从
`SRFQ_PD` 重新 flush。进入 ERROR 时则保留完成位，让 recovery 从第一个未完成 target
继续。

本地 cleanup 只在上表中必需的 delete/flush 全部安全后开始。owned role
恰好 release 一次；borrowed role 只从 registry detach。每个 context/mapping
release 或 borrowed detach 完成后立即持久化对应完成位，全部完成后才能释放
identity。本地 cleanup 中途失败时硬件保持 ABSENT，未完成的 role 留给
recovery，不能 `restore_active()`。

## 12. 错误分类与 recovery

### 12.1 硬件存在性

| 情况 | `hardware_presence` | 允许的本地动作 |
|---|---|---|
| create 提交前失败 | ABSENT | 释放 owned backing 和 reservation |
| create 明确成功 | PRESENT | 后续失败必须先 delete |
| delete 明确成功，或 reconcile/QUERY 证明不存在 | ABSENT | 仍须完成 policy 要求的 OCC target，之后才可本地 cleanup |
| delete timeout/reset-cancel/结果丢失且 QUERY 不能解析 | UNKNOWN | 保留 context、backing 和 ID |
| SRQ pre-delete OCC timeout/结果丢失 | PRESENT | target completion 为 UNKNOWN；不发送后续 flush/delete，不本地 cleanup |
| CQ post-delete OCC timeout/结果丢失 | ABSENT | target completion 为 UNKNOWN；不本地 cleanup |
| terminal failure 且 contract 证明对象未改变 | 保持先前状态 | 仅当仍 PRESENT 且未做 destructive cleanup 时，normal destroy 可恢复 ACTIVE |
| context/mapping release 结果不确定 | ABSENT | 保留该 authority，先 completion-query，不重复盲目 release |

`hardware_presence` 与每个 command/local cleanup step 的 completion state 是两个独立状态
轴。UNKNOWN OCC/release 不得覆盖已经证明的 PRESENT/ABSENT；同样，PRESENT/ABSENT 也
不能反向推导 OCC 或 release 已完成。

`rdma_control_step_e` 增加通用 `RDMA_CTRL_STEP_HW_CONTEXT_CREATED` 和
`RDMA_CTRL_STEP_HW_CONTEXT_DELETED`。它们适用于 CQ/SRQ/CEQ/AEQ，避免为每种资源
复制状态。现有 MR-specific step 保持兼容。多个 queue OCC target 不能只用一个
`RDMA_CTRL_STEP_HW_OCC_FLUSHED` 表示；每个 target 的 role 和完成位由下节的有序记录
单独保存。

### 12.2 recovery record

queue recovery record 至少保存：

- resource kind、handle 和 Function generation；
- recovery intent（create rollback 或 normal destroy）、create/delete opcode key；
- 当前 ambiguous operation 的 step kind、role 和 CMQ ticket；
- hardware presence；
- completed/pending steps；
- 有序的 role-tagged OCC target 列表：PD ref、pre/post-delete phase 和逐项
  flush-complete；
- role-tagged payload/PD backing refs 及逐项 release/detach-complete；
- CQ/SRQ context-slot token、context release authority 和 release-complete；
- primary error 和 rollback error history。

resource manager 的 recovery schema 必须从 MR 的单一/固定 backing 假设扩展为任意有序
role 列表，同时保持 Task 14A MR invariants。只有 authoritative owned mapping/context
ref 的 opaque release capability 可以用于恢复清理；borrowed payload 记录只允许
detach。执行器在发送下一个硬件命令前必须持久化前一 target 的完成位，使
SRQ 的两个 pre-delete barrier 不会因进程中断而越过。

### 12.3 `recover_resource()`

现有同名 API 扩展为 policy-driven，并继续要求 ERROR resource、同一 Function/generation
和 per-Function lock：

1. 加载权威 cleanup plan，并从第一个未完成步骤继续；
2. 有 ambiguous CMQ ticket 时，在发送任何新 CMQ 前先调用 `cmq.reconcile()`，
   并把 terminal success/failure 投影到该 ticket 所属的 delete 或 role-tagged flush；
3. create/delete context ticket 已丢失或无 terminal evidence 时，policy 可以发送对应
   QUERY；QUERY
   返回 context 表示 PRESENT，协议定义的 not-found 表示 ABSENT，其他结果不证明
   存在性；
4. QUERY 只能解析对象存在性，不能证明 OCC target 已 flush。OCC ticket 无法
   reconcile 出 terminal evidence 时，即使 QUERY 证明对象 PRESENT 或 ABSENT，也不得越过
   该 target 或释放 PD；
5. create rollback intent 在 QUERY/reconcile 后为 PRESENT 时进入该资源的完整硬件
   cleanup plan，为 ABSENT 时进入本地 cleanup；normal destroy intent 继续原 destroy
   plan；
6. CQ 在 PRESENT 时先完成 delete；达到 ABSENT 后才完成 `CQ_PD` post-delete
   flush，再按 context slot → PD → payload 继续本地 cleanup。因此 delete 成功但
   flush 失败的恢复记录必须保持 `hardware_presence=ABSENT`；
7. SRQ 在 PRESENT 时严格从未完成的 `SRFQ_PD`/`SRQ_PD` pre-delete target
   开始，两者全部完成后才可发送 delete。任一 pre-delete flush timeout 后都不得
   继续 delete；
8. CEQ/AEQ 在 PRESENT 时完成 delete；四类资源达到 ABSENT 且必需 flush 全部完成
   后，从第一个未完成的 context/backing role 继续 cleanup；
9. context 或 owned mapping release 返回不确定结果时，恢复必须先使用该 authority
   的 completion-query contract；已完成则只补记完成位，明确未完成才重试 release；
10. 任一必需硬件步骤仍 UNKNOWN 时返回 `RECOVERY_REQUIRED`，不释放它保护的
   context、backing 或 ID。

普通 destroy 在硬件仍 PRESENT 且 terminal failure 明确证明对象未改变时，可按第
11 节恢复 ACTIVE。create rollback intent 则保留 ERROR 并在后续 recovery 重试完整
cleanup。迟到 completion、重复 `recover_resource()` 和“外部 release 成功但完成位
持久化失败”都必须幂等；已经证明完成的 CMQ、context release 或 mapping
release 不得重复执行。

普通 generation 增加本身不证明旧硬件对象不存在。可信 Function reset/teardown 是
privileged boundary：外部 adapter 先确认硬件 generation 已整体失效，再调用现有
`release_function()` 按逆依赖顺序清除旧 generation。该路径可以清理 UNKNOWN ERROR
资源；普通 per-resource API 不获得这种强制权限。

### 12.4 结果语义

所有 API 返回 `rdma_control_result`：

- 完整成功：`status=OK`；
- 明确失败且已完整回滚/恢复 ACTIVE：`status` 为原始失败，
  `recovery_required=0`；
- 状态不确定或 cleanup 未完成：外层 `status=RDMA_SC_RECOVERY_REQUIRED`，
  `primary_status` 保存原始失败，rollback failures 追加到 `rollback_statuses`，最终资源
  状态为 ERROR。

## 13. 并发与 generation fence

- 同一 Function 的 CQ/SRQ/CEQ/AEQ create、destroy、recover 使用 Task 14A 的同一把
  lifecycle semaphore；
- 不同 Function 可以并行，CMQ engine 继续允许 multi-outstanding；
- entry 数据面操作不由全局 lifecycle lock 串行化；
- binding 在入口、获得锁后、CMQ terminal completion 后和最终 registry commit 前检查；
- 旧 generation completion 不得激活或释放新 generation 的资源；
- backing plan、interrupt mapping 和 dependency handles 必须全部属于同一 Function
  generation。

## 14. 外部组件边界

### 14.1 host_mem

control plane 只依赖 `rdma_host_mem_api`。生产 adapter 可以接入远程 `host_mem` 组件；
mock adapter 用于独立 core test。owned create 要求 host_mem 非空；borrowed create 仍需
memory write 能力完成初始化，因此也要求可访问该 mapping 的 memory port。host_mem
实现类不成为 rdma core package 的编译依赖。host_mem 只管理/访问 queue payload
和 control-plane-owned page directory，不分配 CQ/SRQ HMC/GRM context slot。

### 14.2 HMC/GRM context backing

control plane 只通过 `rdma_context_backing_api` acquire、write、completion-query 和
release CQ/SRQ context slot。生产 adapter 包装 Function HMC/GRM context manager，mock
adapter 可以在内部用 host_mem 模拟，但这不改变两个公共接口的所有权边界。

`rdma_hmc_allocator` 继续只管理强类型 FVM lease，用于 context/model 中的 HMC 索引
权威性校验。它不提供 DMA/CPU view，不允许 executor 将 FVM address 当作
`rdma_host_mem_api.write()` 的目标，也不能代替 `rdma_context_backing_api`。

### 14.3 PCIe

PCIe adapter 在 Function bind 前负责发现 BDF、BAR、BME/MSE、DMA domain、PASID 和
MSI-X vector mapping。Task 14B 不直接调用 PCIe sequencer。真实 DUT 的 EP DMA 通过
host_mem mapping 指向 RC memory；BAR 只承载后续 MMIO/doorbell。

### 14.4 AXIS/net_packet

Task 14B 不产生网络包，也不依赖 AXIS env。后续 QP/packet 数据面可以消费本任务创建的
ACTIVE CQ/SRQ，但不能反向把 AXIS adapter 注入为队列 lifecycle 的必需组件。

## 15. 验证设计

新增独立 queue lifecycle unit test，而不把四类资源矩阵继续堆入现有 MR-focused test。
生产代码也把 executor、policy 和 backing model 拆分为聚焦文件，`rdma_control_plane`
只保留 API facade 和 Task 14A 的兼容路径。

### 15.1 正向矩阵

- CQ、SRQ、CEQ、AEQ 的 owned/borrowed `INDIRECT_4K` create/destroy；
- CQE 32/64/128；SRQ 不同 max-SGE 和 limit threshold；
- SRQ_RING/SRFQ_RING 的 64-byte stride，`max_sge > 2` 时的每 WQE 512-byte
  SGB，以及 SRQ_PD/SRFQ_PD 的独立权威性；
- CQ→CEQ、SRQ→PD 的正确依赖；
- 64-bit device IOVA 高于 4 GiB，且 host `backing_addr` 故意不同，证明 PD entry 和
  queue-base context 字段只编码 IOVA；shadow pointer 则只来自 context API；
- Function-local vector 到 hardware vector/MSI-X table 的解析；
- PD entry 的 big-endian 图像、`[63:12]` page address、`[11:4]` VF ID、valid
  bit、reserved-zero，以及 512 entries/未用 entry 清零；
- ring、PD、CQC offset 48/8-byte shadow view、SRFQC offset 28/4-byte shadow view 的
  初始化图像，以及 create CMQ 前的 payload → PD → context 可见顺序；
- 全零 ring/SGB storage、CQ/CEQ/AEQ polarity seed=1、SRFQ polarity seed=0、CQC
  `last_arm_sequence=1`/current arm sequence=0 和 SRQC limit/PI shadow 初值；
- CQ `delete → CQ_PD flush`、SRQ `SRFQ_PD flush → SRQ_PD flush → delete`
  和 CEQ/AEQ 无 PD flush 的硬件顺序；
- owned 每个 payload/PD/context role release 一次，borrowed payload 从不 release。

### 15.2 非法输入与隔离

- depth 非 power-of-two、codec 宽度溢出和 checked size overflow；
- 不支持的 CQE size、DIRECT/HUGE/L3 mode、indirect 页数超限；
- 缺失/多余/重叠 borrowed role、长度不足和对齐错误；
- mapping owner、BDF、PASID、DMA domain、generation 或访问方向不匹配；
- disabled/不存在/字段溢出的 interrupt vector；
- stale PD/CEQ dependency 和跨 Function dependency；
- live CQ/SRQ/CEQ/PD dependent 导致 destroy busy，且不发送 delete CMQ。

### 15.3 逐点失败注入

每类资源覆盖：

- identity reservation；
- 每个 payload ring/SGB 和 PD mapping 的 allocate/write；
- CQ/SRQ context slot 的 acquire、shadow-view write、completion-query 和 release；
- `stage_allocated()`；
- create submit、terminal failure、timeout；
- `commit_programmed()` 和 `activate()`；
- rollback 的每个 pre/post-delete OCC target 和 delete failure/timeout；
- normal destroy 的每个 pre/post-delete OCC target 和 delete failure/timeout；
- 每个 owned payload/PD/context role release 和 borrowed detach；
- `finalize_release()`。

每条失败路径断言：resource state、completed/pending steps、CMQ call order、allocation count、
mapping release count、ID pool、dependency graph 和 recovery record 都与设计一致。

### 15.4 recovery、并发与集成

- create/delete timeout 的 late success、late failure 和 still-pending；
- QUERY present、not-found、failure 和 timeout，以及 QUERY 不能证明 OCC-complete；
- CQ delete 成功后 `CQ_PD` flush failure/timeout：对象保持 ABSENT，context/PD/payload
  保留并从 flush 继续 recovery；
- SRQ 第一/第二个 pre-delete flush failure/timeout：未明确成功前绝不发送
  后续 flush/delete；成功路径验证两个 target 的逐项完成位；
- SRQ normal destroy 明确失败并恢复 ACTIVE 时清除本次 pre-delete 完成位，下一次 destroy
  重新执行两个 flush；ERROR recovery 则保留已完成 target；
- context slot、PD 和 payload 多 role cleanup 中途失败后的重复 recovery；
- recovery delete 重试和幂等；
- 同 Function 串行、不同 Function 并行；
- 等锁期间 rebind、CMQ 返回后 generation 改变；
- standalone identity vector map 与 PCIe adapter contract；
- production host_mem adapter 的 64-bit allocation/write/release integration。

## 16. 完成标准

Task 14B 只有同时满足以下条件才完成：

1. 新增 Python/静态 unit tests 全部通过；
2. 在 `10.11.10.53` login shell 上运行新增 VCS queue lifecycle test，结果为
   `0 UVM_ERROR / 0 UVM_FATAL`；
3. 现有已注册 core tests 全量通过；
4. host_mem integration test 通过；
5. HMC/GRM context adapter contract test 通过；
6. frozen xtr checker 通过，证明没有修改冻结 ABI；
7. 所有失败注入路径没有 allocation、mapping、context slot、ID、dependency、CMQ ticket 或 recovery
   metadata 泄漏；
8. UNKNOWN hardware/step completion 路径保留 resource/backing，且不会被普通 API 复用；
9. 核心 package 和 core test 不依赖 PCIe env、AXIS env 或具体 VIP。
