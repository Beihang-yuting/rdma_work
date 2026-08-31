# RDMA Task 14C QP 生命周期设计

日期：2026-08-31
状态：待实现

## 1. 目标

Task 14C 在 Task 14A 的事务、CMQ、resource manager、generation fence 和
recovery 基础，以及 Task 14B 的 host-memory、context-backing 和可恢复队列 backing
基础上，实现 QP 的完整控制面生命周期：

1. 提供类型化 `create_qp`、`modify_qp`、`destroy_qp` facade；
2. 管理 QPN、PD、send-CQ、recv-CQ、可选 SRQ 依赖；
3. 管理 SQ、私有 RQ、page directory、URC 内部队列和 HMC QPC context；
4. 使用 RC、UD、URC 专用 QPC codec 生成 512-byte QPC image；
5. 以 QPC create/modify/delete/query 和 OCC flush CMQ 命令驱动硬件状态；
6. 对失败、timeout、reset cancel、generation 改变和 recovery 提供明确的
   exactly-once 语义；
7. 在成功 create 后发布 `ACTIVE + RESET` QP，在成功 modify 后原子发布新的语义状态，
   在成功 destroy 后释放硬件、context、owned backing 和 identity。

## 2. 本轮不做的内容

- SQE、RQE、CQE 的构造、投递、解析或完成匹配；
- SQ/RQ PI/CI 推进、doorbell、QP engine、真实 PCIe/VIP 接线；
- RTS↔SQD doorbell handshake、SQD completion event 和 SQE recovery；
- CQ 中遗留 CQE 的数据面清理；
- address handle、multicast、memory window 或 work-request lifecycle；
- CQ resize、URC shared-CQ 创建/回收或动态改变 PD/CQ/SRQ 依赖；
- QP SQ/RQ 的 huge-page、direct 或 L3 backing 自动生成；
- caller 控制 URC 内部 RSQ/RDSQ/DSQ backing；
- 修改冻结的 xtr_v1 opcode、bit field 或 golden ABI；
- 修改 pinned 外部 `host_mem` 项目。

由于本轮没有 QP engine，任何带 outstanding operation 的 QP 在 modify/destroy 时返回
`RDMA_SC_RESOURCE_BUSY`。这样不会用控制面成功掩盖尚未排空的数据面。

## 3. 事实基线

### 3.1 仓库已有能力

- `rdma_create_qp_req`、`rdma_modify_qp_req`、`rdma_qp_state_e` 和 `rdma_qp`
  已存在，但 create 请求没有 backing/context 属性，control plane 没有 typed QP API。
- `rdma_resource_manager.create_qp()` 已预留 QPN，并记录 QP→PD、send-CQ、recv-CQ、
  可选 SRQ 依赖。
- `rdma_xtr_v1_qpc_rc_codec`、`rdma_xtr_v1_qpc_ud_codec`、
  `rdma_xtr_v1_qpc_urc_codec` 已能编码和校验 512-byte QPC image。
- QPC create/modify/delete/query CMQ body、signature composition、opcode registry 和
  completion correlation 已存在。
- Task 14B 已提供 host-memory mapping 权威、owned/borrowed payload、4 KiB page
  directory、context slot、逐 role cleanup、ambiguous CMQ recovery 和 generation fence。
- `rdma_resource_manager.begin_quiesce()` 已统一检查 live dependents 和
  `outstanding_ids`，失败返回 `RDMA_SC_RESOURCE_BUSY`。

### 3.2 固定驱动事实

审计来源为 VCS53 上的：

```text
/home/ubuntu/workspace/Desktop.zip
dpu_kernel_rdma-version_0.1.32/qp.c
```

固定驱动给出以下 QP lifecycle 约束：

- HMC 中的 QPC context 与临时 CMQ QPC image 是两份不同的 authority。
  `SHADOW_PBA` 指向 `qp_ctx.ctx_addr.iova`，而 QPC_CREATE/QPC_MODIFY 命令指向
  临时 `cmdq_qpc_buf.iova`。临时 buffer 只用于硬件搬运和 signature。
- QPC context address 和临时 QPC image 都以 512 bytes 为编码粒度；QPC image
  长度固定为 512 bytes。
- SQ/RQ WQE stride 由设备能力给出，当前固定路径为 64 bytes；buffer 大小按 4 KiB
  向上取整。普通 backing 的硬件 mode 为 `INDIRECT_4K`，QPC 中保存 page-directory
  base，而不是 host virtual address。
- 使用 SRQ 时，QPC 的 receive base/mode/depth 来自 SRQ backing，不再拥有私有 RQ；
  URC 不支持 SRQ。
- URC create 额外拥有 4 KiB RSQ、4 KiB RDSQ 和连续 8 KiB DSQ backing。
- create 成功后临时 QPC image 立即释放；full modify 每次重新创建临时 image。
- INIT→RTR 和 RTR→RTS 使用 full-QPC modify；其余驱动支持的状态改变使用
  state-only modify。RESET→INIT 不提交 CMQ。
- destroy 在需要时先将 QP 转为 ERROR，等待数据面排空，然后依次 OCC-flush
  QPN cache、SQ PD、无 SRQ 时的 RQ PD，最后 QPC_DELETE。

Task 14C 镜像这些控制面事实。真实驱动中的 QP flush doorbell、CQ cleanup 和 event
等待属于 QP engine/data plane，因此不在本轮伪造；本轮以 `outstanding_ids == 0`
作为进入硬件 destroy 的前置条件。

## 4. 方案比较与选择

### 4.1 选择：QP 专用 executor + 复用 backing/context primitive

新增 `rdma_qp_lifecycle_executor`。它复用 Task 14B 的 mapping、PD、context slot、
CMQ outcome、generation fence 和 recovery 纪律，但拥有 QP 专用 plan、transport codec
选择和状态机。

这是选定方案，因为 QP 同时包含两个公开 WQ、可选 SRQ projection、URC 内部队列、
长期 HMC context 和短期 QPC staging image；这些语义不是现有
`rdma_queue_lifecycle_policy` 的单 ring/context create-delete 模型。

### 4.2 未选：把 QP 加入现有 queue lifecycle policy

该方案可以少一个 executor，但会迫使 `rdma_queue_resource`、通用 queue policy 和
queue recovery schema 理解 modify 状态机、transport extension 和临时 QPC image，
扩大所有 CQ/SRQ/CEQ/AEQ 路径的回归面，故不采用。

### 4.3 未选：在 `rdma_control_plane` 内复制一套过程式事务

该方案实现直接，但会复制 Task 14B 已解决的 mapping authority、ambiguous CMQ、
cleanup progress 和 recovery 规则，并继续放大已经很长的 control-plane 文件，故不采用。

## 5. 总体架构

```text
typed create/modify/destroy request
                 |
                 v
          rdma_control_plane
      transaction ID / Function lock
                 |
                 v
      rdma_qp_lifecycle_executor
       |        |        |       |
       |        |        |       +--> transport-specific QPC codec
       |        |        +----------> rdma_cmq_port
       |        +-------------------> host_mem/context_backing
       +----------------------------> rdma_resource_manager
```

`rdma_control_plane` 只负责 facade、transaction ID、配置检查、Function lock、输入和
post-lock generation fence。executor 负责 QP 事务。codec 只接受完整语义 model，
executor 和 facade 都不得直接修改 QPC raw byte 或 CMQ field bit。

## 6. 公共 API 和请求模型

`rdma_control_plane` 增加：

```systemverilog
task create_qp(
  rdma_function_binding binding,
  rdma_create_qp_req request,
  output rdma_qp qp,
  output rdma_control_result result
);

task modify_qp(
  rdma_function_binding binding,
  rdma_modify_qp_req request,
  output rdma_qp qp,
  output rdma_control_result result
);

task destroy_qp(
  rdma_function_binding binding,
  rdma_destroy_resource_req request,
  output rdma_control_result result
);
```

成功的 create/modify 返回 detached authoritative snapshot。失败 create/modify 返回
`qp == null`，但 recovery-required create 可以通过 `result.resource_h` 查到 ERROR QP。
destroy 只接受 `RDMA_RESOURCE_QP` target。

### 6.1 Create 请求

`rdma_create_qp_req` 保留 transport、SQ/RQ depth、max SGE 和依赖字段，并增加：

```text
sq_backing       rdma_queue_backing_spec
rq_backing       rdma_queue_backing_spec
context_attrs    rdma_qp_context_attributes
```

`rdma_qp_context_attributes` 只包含调用者真正拥有的 QPC 语义：

```text
path_mtu_bytes
pkey
access
address_vector
signature_enable
tx_flow_control / rx_flow_control
behavior
transport_ext
```

它不包含 QPN、PD/CQ/SRQ local ID、SQ/RQ/URC backing、HMC context address、host/VF
identity、state、stat index 或 QP sequence；这些字段只能由 executor 从已验证的
binding、dependency snapshot、identity 和 backing plan 派生。

`transport_ext` 必须与 request transport 匹配。当前 QPC model 的既有契约要求 RC/URC
remote QPN 非零、UD qkey 非零，因此 create attributes 也遵守该契约；Task 14C 不用
虚构默认 remote identity 绕过 codec 校验。URC transport attributes 中的
RSQ/RDSQ/DSQ backing address 必须全为零；depth、fetch count 和 threshold 由调用者
提供，三个 address 只能由 executor 在 allocation 后覆盖。

SQ/RQ depth 必须为非零 2 的幂，`depth * 64` checked-align-up 到 4 KiB 后不得超过
Function `max_queue_ring_bytes` 或一个 4 KiB PD 的 2 MiB 覆盖范围。max SGE 必须在
`1..queue_caps.max_wq_sge`。本轮不创建 SGB 数据面，所以 max SGE 只作为未来 SQE/RQE
能力和请求一致性保留，不分配或编码 SGB。

有 SRQ 时：

- transport 必须是 RC；
- `rq_backing` 必须是 canonical empty spec；
- `rq_depth` 必须等于 authoritative SRQ depth；
- QPC receive base/mode 从 SRQ plan 投影；
- QP plan 不复制 SRQ 的 release authority，也不在 destroy 时释放或 flush SRQ backing。

无 SRQ 时，SQ 和 RQ payload 分别支持 control-plane-owned 或 caller-borrowed mapping。
owned/borrowed 的校验、IOVA/domain 检查、覆盖、重叠和 release authority 与 Task 14B
相同。SQ 与私有 RQ 的 PD 始终由 control plane 创建。

### 6.2 Modify 请求

`rdma_modify_qp_req` 保留现有字段并增加显式有效位：

```text
destination_qpn_valid
send_psn_valid
recv_psn_valid
```

没有有效位的值不得覆盖已有 QPC semantic state。RC 可以更新 destination QPN 和两个
PSN；URC 可以更新 destination QPN，并把 send/recv PSN 投影到既有 URC canonical
sequence owner；UD 本轮只支持状态改变，三个有效位必须为零。QKey、AV、PMTU、access、
PD/CQ/SRQ 和 transport 的动态修改不在本轮 API 中。

## 7. QP backing 和 context authority

### 7.1 持久 plan

`rdma_qp` 增加唯一权威 `rdma_qp_backing_plan qp_plan` 和最后一次硬件已编程的
`rdma_qpc_model programmed_qpc`。当 resource state 为 PROGRAMMED、ACTIVE、
QUIESCING 或 ERROR 时，两者必须非空且通过完整校验。此时普通 `backing_refs` 和
`hmc_refs` 必须为空，防止 split authority。

plan 包含：

- SQ ring layout、payload ref 和 SQ PD ref；
- 无 SRQ 时的 RQ ring layout、payload ref 和 RQ PD ref；
- 有 SRQ 时的 `rq_source_h`，但不复制 SRQ mapping release authority；
- URC 时的 owned RSQ、RDSQ、DSQ refs；
- control-plane-owned QPC context ref；
- cleanup/flush completion bit；
- transport、depth、entry size 和 object mode 的 immutable snapshot。

QP backing role 使用明确的新枚举值，至少包括：

```text
QP_SQ_RING, QP_RQ_RING, QP_SQ_PD, QP_RQ_PD,
QP_URC_RSQ, QP_URC_RDSQ, QP_URC_DSQ
```

现有 CQ/SRQ/EQ plan 的合法 role 集合保持不变；增加枚举值不能让旧 plan 接受 QP role。

### 7.2 SQ/RQ layout

SQ 和私有 RQ entry size 固定为 64 bytes，storage size 为
`align_up(depth * 64, 4096)`。payload 初始化为零。每个 payload page 由一个 big-endian
PD entry 指向，PD entry 继续使用 Task 14B 已验证的 VF ID、valid bit 和 device IOVA
投影。QPC `SQ_PBA/RQ_PBA` 写 PD mapping 的 device IOVA，mode 固定为
`RDMA_OBJECT_INDIRECT_4K`。

`rdma_qp.sq_iova/rq_iova` 保留 payload 首字节 IOVA，不得误装 PD IOVA。QPC model 的
`sq_backing/rq_backing` 则保存硬件 mode 对应的 PD base。host `backing_addr` 只供
host_mem read/write/release，不能进入 QPC 或 PD entry。

### 7.3 URC 内部 backing

URC 专用 RSQ 和 RDSQ 各分配 4 KiB，DSQ 分配连续且 4 KiB 对齐的 8 KiB；三者均为
control-plane-owned、device-readable/writable 的内部 backing，不暴露 borrowed mode。
transport attributes 提供 RSQ/RDSQ depth、fetch count 和 threshold 语义；executor
覆盖其中三个 backing address 后，交给 URC codec 做 3-bit/4-bit/6-bit profile 校验。
RC/UD plan 不得携带这些 role。

### 7.4 HMC QPC context 与临时 image

`rdma_context_backing_api` 扩展支持 `RDMA_RESOURCE_QP`：

- local ID 为 resource manager 分配的 21-bit QPN；
- slot length 为 512 bytes；
- `shadow_pointer_base` 为 512-byte aligned device IOVA；
- HMC lease 和 opaque release token 属于 control plane；
- QP context 不通过 host_mem `write()` 直接写入，硬件由 QPC CMQ command 更新。

该 context ref 在 create 成功后一直保留到 destroy/recovery 完成。它的
`shadow_pointer_base` 投影到 QPC model `context_backing`，即 `SHADOW_PBA` 的 byte
address owner。

create、full modify 和 query 另行分配一个 512-byte、512-byte aligned 的临时
host_mem mapping。它承载 standalone QPC image，CMQ body 的 `qpc_buffer` 指向其
device IOVA。正常 terminal completion 后立即释放。CMQ outcome 不确定时，mapping
随 recovery record 保留，直到 ticket/query 证明硬件不再访问它；不得提前释放，也不得
把它保存为长期 QPC context。

## 8. QPC model 构建和 codec 选择

executor 通过单一 builder 构造完整 `rdma_qpc_model`：

1. 从 manager snapshot 投影 QP、PD、send-CQ、recv-CQ、可选 SRQ 的 local ID；
2. 从 binding 投影 host ID、RDMA VF ID 和 Function generation；
3. stat index 按 Function policy 从 local QPN 投影；QP sequence 使用 resource manager
   维护的 per-local-QPN 8-bit incarnation counter，每次重新分配该 local QPN 时递增；
4. 从 plan 投影 SQ/RQ mode、PD base、depth 和 HMC context address；
5. 从 request context attributes 投影 PMTU、access、AV、behavior 和 transport ext；
6. create state 固定为 RESET；
7. 运行完整 model validation，再根据 transport 选择 codec registry key：
   `rc`、`ud` 或 `urc`；
8. encode 得到 512-byte image，并用同一个 codec decode/serialized-equal 做防御性
   round-trip 检查后才允许 host_mem write。

modify 先 deep-copy `programmed_qpc`，在 typed semantic object 上应用 request patch，
再重复 validate/encode/round-trip。任何路径都不得在 `image.bytes[]` 中搜索或改写 state、
QPN、PSN 或 transport bit。

## 9. Create 事务

在同一 per-Function lock 下执行：

1. 重新验证 binding generation、请求和依赖；
2. manager 预留 QPN 和静态依赖，resource 为 ALLOCATED；
3. 验证 local QPN 小于 `2^21`；
4. 生成并 acquire SQ、可选私有 RQ、对应 PD；
5. URC 时 acquire RSQ/RDSQ/DSQ；
6. acquire HMC QPC context；
7. 构造并 codec-encode RESET QPC model；
8. acquire 临时 512-byte QPC image mapping并写入 image；
9. manager 原子 attach `qp_plan + programmed_qpc`，resource 进入 PROGRAMMED；
10. 提交 QPC_CREATE，CMQ body 只引用 projected QPN/CQN 和 staging IOVA；
11. terminal success 后释放 staging mapping；
12. manager activate，发布 `ACTIVE + qp_state=RESET` snapshot。

每个外部 side effect 前后都执行 live generation fence。成功结果至少记录
RESOURCE_RESERVED、BACKING_ATTACHED、HMC_ATTACHED、HW_CONTEXT_CREATED、
REGISTRY_PROGRAMMED 和 REGISTRY_ACTIVE。

### 9.1 Create 失败和回滚

CMQ submit 前的 definitive 失败按相反顺序释放 context、URC internal、PD、owned
payload 和 identity；borrowed payload 只 detach，不 release。

QPC_CREATE definitive no-submit 或 terminal failure 同样执行本地回滚。QPC_CREATE
terminal success 后若 registry activation 失败，必须先执行完整 QP hardware destroy
recipe，再释放本地 authority。

timeout、reset cancel、null/incomplete completion 或无法证明 no-submit 的失败不得猜测
硬件不存在。resource 进入 ERROR，保留 identity、依赖、plan、context、staging mapping、
ticket、create/delete/query descriptor 和未完成步骤，结果为
`RDMA_SC_RECOVERY_REQUIRED`。

## 10. Modify 状态机和事务

### 10.1 支持的转换

Task 14C 支持以下转换：

| 当前状态 | 下一状态 | 硬件动作 |
|---|---|---|
| RESET | INIT | software-only；保存 semantic state，不提交 CMQ |
| INIT | RTR | full QPC modify |
| RTR | RTS | full QPC modify |
| INIT/RTR/RTS | ERROR | state-only QPC modify |
| INIT/RTR/RTS/ERROR | RESET | state-only QPC modify |

same-state request、跳级、RESET→RTR/RTS 和 ERROR→INIT/RTR/RTS 返回
`RDMA_SC_INVALID_STATE`；涉及 SQD/SQE 的转换返回
`RDMA_SC_UNSUPPORTED_OPCODE`。RTS↔SQD 需要 doorbell/event handshake，明确留给
QP engine 任务。

RESET→INIT 后，resource `qp_state` 为 INIT，而 `programmed_qpc.state` 仍表示硬件最后
编程的 RESET。INIT→RTR full modify 从 create attributes 和当前 semantic patch 构建
完整 RTR image；成功后两者重新一致。这一差异必须在 model 中显式表示，不能伪造一次
不存在的 CMQ completion。

### 10.2 Modify 顺序

1. facade 校验 owner、generation、QP kind 和 request valid bits；
2. 获取 Function lock 后再次 fence；
3. lookup ACTIVE QP；任何 outstanding operation 返回 `RDMA_SC_RESOURCE_BUSY`；
4. 校验状态转换，构造 candidate semantic QPC；
5. 对 candidate 运行 transport codec validation；
6. RESET→INIT 直接调用 manager 的原子 semantic-state commit；
7. full modify acquire/write临时 QPC image；state-only 不携带 image；
8. 构造 QPC_MODIFY body，full mode 的 WBE template 由 transport 选择，调用 CMQ；
9. terminal success 后释放临时 image，并原子发布 candidate QPC 和新 `qp_state`；
10. definitive failure 保持 prior QPC/state 不变并释放临时 image。

若 CMQ modify outcome 不确定，resource 进入 ERROR recovery state，同时保存 prior 和
candidate QPC、原始 semantic state、staging mapping、ticket 和 query descriptor。
调用者收到 `RDMA_SC_RECOVERY_REQUIRED`，不得收到看似成功的新 QP snapshot。

## 11. Destroy 事务

destroy 在任何硬件 side effect 前执行 owner/generation 检查和
`manager.begin_quiesce()`。live dependent 或 outstanding operation 直接返回
`RDMA_SC_RESOURCE_BUSY`，QP 保持 ACTIVE，不发送 modify、flush 或 delete。

进入 QUIESCING 后按固定顺序执行：

1. 若 semantic state 不是 ERROR，提交 state-only QPC_MODIFY 到 ERROR；
2. OCC-flush QPN cache（EIRQ/ORQ/UAQ pattern）；
3. OCC-flush SQ PD；
4. 无 SRQ 时 OCC-flush私有 RQ PD；
5. QPC_DELETE；
6. release HMC QPC context；
7. reverse-release URC internal、owned PD 和 owned payload；
8. borrowed payload 只 detach；
9. `manager.finalize_release()` 回收 identity 和 dependency edges。

QPC_DELETE body 必须使用 authoritative local QPN、send CQN 和 recv CQN。使用 SRQ 时
不得 flush/release SRQ PD；SRQ 的 dependency edge 直到 QP finalize_release 后才消失。

任一硬件命令 outcome 不确定时进入 ERROR，保留所有尚未证明可释放的 authority。
definitive hardware failure也保留 ERROR recovery record，使 retry 从第一个未完成步骤继续，
而不是恢复 ACTIVE 后丢失已完成的 ERROR/flush side effect。

## 12. Recovery 和 exactly-once 规则

QP recovery schema 独立于现有 queue schema，但复用相同的 completed/pending step、
hardware presence、ambiguous ticket 和 cloned authority 契约。record 至少保存：

```text
intent: CREATE_ROLLBACK / MODIFY_RECONCILE / NORMAL_DESTROY
prior_qpc / candidate_qpc
qp_plan / context_ref
staging_or_query_mapping
create/modify/delete/query opcode keys
ambiguous operation and ticket
per-flush and per-release completion bits
```

规则如下：

- ambiguous create/delete 先 reconcile ticket；仍无法确定时使用 QPC_QUERY 和独立
  query mapping 判断 context present/absent；
- ambiguous modify 通过 QPC_QUERY 读回 512-byte image，再用对应 transport codec
  decode，并与 prior/candidate 做 serialized equality；
- query 等于 candidate 时发布 candidate，等于 prior 时恢复 prior；两者都不等时继续
  ERROR/RECOVERY_REQUIRED；
- create rollback 查询为 absent 时只做本地 cleanup；查询为 present 时先执行 destroy
  recipe；
- destroy 查询为 absent 时跳过重复 delete并继续本地 cleanup；查询为 present 时从第一个
  未完成 flush/delete 步骤继续；
- context release 和 host_mem release 前先查询 opaque completion authority；已完成的
  release 只记录 progress，不重复调用 adapter；
- 每个物理 release 成功后立即由 manager 原子记录 completion bit；后续失败不得丢失；
- ID 只由 `finalize_release()` 回收一次；ERROR resource 和 recovery record 存在期间不可
  重用同一 incarnation；
- 任意 stale generation 在物理 side effect 前停止；若 side effect 已发生，则先把它的
  completion 安全记录到旧 generation 的 ERROR authority，不得写入新 generation。

QPC_QUERY 的 completion payload 不来自 CMQ CQE；命令完成后通过 host_mem read query
mapping 获得 512-byte image。codec 校验 metadata、reserved mask 和 transport-specific
字段后才允许用于 presence/state 判断。

## 13. Resource manager 边界

resource manager 增加窄而原子的 QP mutation：

- attach/project `rdma_qp_backing_plan` 和 `programmed_qpc`；
- commit RESET→INIT semantic-only state；
- commit successful programmed QPC/state；
- mark QP ERROR with QP recovery schema；
- record QPN/SQ-PD/RQ-PD flush completion；
- record context/backing cleanup completion；
- restore prior/candidate ACTIVE QP after modify reconciliation；
- finalize ERROR create rollback或 normal destroy。

所有输入先投影到 built-in model，不能保存 caller subclass、borrowed nested alias 或
未经检查的 mapping clone。manager replacement 必须完整 validate 后一次发布；不能先改
registry 中的 `qp_state`，再等待 codec/CMQ 成功。

QP local ID 上限补为 21 bits，并增加 per-local-QPN 8-bit sequence counter。global
incarnation handle 与 QPC local QPN 继续分离；所有 QPC/CMQ builder 必须显式 project
local ID，不能把 opaque `handle.object_id` 当 QPN 或 QP sequence。

## 14. Error code 约定

- 请求 shape、kind、transport extension 或 backing spec 非法：
  `RDMA_SC_INVALID_ARGUMENT`；
- 非法状态转换、错误 resource state 或 authority 不完整：
  `RDMA_SC_INVALID_STATE`；
- SQD/SQE 等本轮未支持行为：`RDMA_SC_UNSUPPORTED_OPCODE`；
- stale binding/handle generation：`RDMA_SC_STALE_GENERATION`；
- live dependent/outstanding operation：`RDMA_SC_RESOURCE_BUSY`；
- mapping domain/range 错误：`RDMA_SC_DMA_TRANSLATION`；
- codec/CMQ/adapter definitive failure：保留原始具体 status；
- 硬件或 cleanup outcome 不确定且有 durable recovery authority：
  `RDMA_SC_RECOVERY_REQUIRED`。

`rdma_control_result.primary_status` 保存触发 recovery 的原始 status，
`rollback_statuses` 保存后续 cleanup/reconcile 失败，不能用最后一个 rollback failure
覆盖 primary cause。

## 15. 测试矩阵

### 15.1 Model、planner 和 manager 单元测试

- create/modify request deep-copy、有效位和非法 transport/SRQ 组合；
- QP plan owned/borrowed SQ/RQ、SRQ projection、URC role 完整性；
- 64-byte stride、4 KiB rounding、2 MiB 上限、PD entry endian 和 IOVA/backing 分离；
- 21-bit local QPN、PD/CQ/SRQ local-ID projection；
- no split authority、subclass projection、mapping release authority 和 clone isolation；
- QP plan attach、state commit、ERROR recovery 和逐 role progress 原子性。

### 15.2 Create 测试

- RC、UD、URC 成功 create；RC with/without SRQ；same send/recv CQ；
- owned 和 borrowed SQ/RQ，borrowed mapping 在 destroy 后仍 active；
- URC RSQ/RDSQ/DSQ geometry和 codec image；
- HMC QPC context address与临时 QPC image address明确不同；
- 每个 allocation/context/write/codec/CMQ/activate checkpoint 的失败注入；
- create timeout/no-submit/terminal failure和 rollback/recovery；
- post-lock rebind、CMQ held-gate rebind和 terminal fence；
- 成功后 staging mapping live count 回到基线。

### 15.3 Modify 测试

- RESET→INIT→RTR→RTS、ERROR 和 RESET 返回路径；
- 所有非法跳转、same-state、SQD/SQE 拒绝；
- RC/URC destination和PSN valid-bit patch；UD state-only；
- full/state-only CMQ mode、URC WBE template、codec round-trip；
- definitive failure保留 prior snapshot；
- ambiguous modify query匹配 prior、candidate、neither 三种结果；
- stale generation和 outstanding operation busy。

### 15.4 Destroy 测试

- RESET/INIT/RTR/RTS/ERROR QP destroy；
- live dependent/outstanding busy且零硬件 side effect；
- QPN→SQ-PD→可选 RQ-PD→DELETE 的精确顺序；
- SRQ QP 不 flush/release RQ/SRQ backing；
- RC/UD/URC cleanup和owned/borrowed exactly-once；
- 每个 flush/delete/context/release/finalize checkpoint失败；
- ambiguous delete query present/absent、retry和多次 recover 幂等；
- 所有成功路径 ID、context、owned mapping、ticket live count回到基线。

### 15.5 回归

- Python unittest 与 `tools/check_queue_lifecycle.py`；
- frozen xtr_v1 defs/golden checker；
- 既有 model、resource manager、QPC codec、CMQ codec/engine、Task 14A control-plane、
  Task 14B queue lifecycle 和 host_mem integration；
- 新增 Task 14C runner manifest，并在 `10.11.10.53` 使用 bash login shell 执行 VCS；
- 所有 UVM `WARNING/ERROR/FATAL = 0/0/0`。

## 16. 完成标准

Task 14C 只有在以下条件全部满足时完成：

1. typed create/modify/destroy facade 和 generic recovery 都有正反向测试；
2. RC、UD、URC 以及 RC+SRQ lifecycle 均通过；
3. modify 只通过 semantic model + transport codec 改变 QPC；
4. QPC context、staging image、SQ/RQ payload、PD 和 host backing 地址类型不混用；
5. destroy busy 检查发生在任何硬件 side effect 之前；
6. ambiguous outcome 不假成功、不提前 release，recovery 可重复且 exactly-once；
7. stale generation 不向新 generation 发布旧事务进度；
8. 成功 create/modify 不泄漏 staging mapping，成功 destroy 不泄漏 owned mapping、
   HMC context、identity、dependency 或 CMQ ticket；
9. VCS53 新增测试和全部相关回归通过；
10. 仓库不包含 build 输出、VCS 日志、`__pycache__` 或外部 `host_mem` 修改。
