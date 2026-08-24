# RDMA Task 14A 控制面事务框架与 PD/MR 生命周期设计

日期：2026-08-24
状态：设计已确认，等待规格复核

## 1. 目标

Task 14 原计划一次实现 PD、MR、CQ、QP、SRQ、CEQ 和 AEQ 的完整控制面，范围已经超过一个可安全验证的实现批次。本设计先统一控制面事务边界，再只实施 Task 14A：

1. 建立同步、可恢复的资源事务框架；
2. 为现有 `rdma_cmq_engine` 增加可替换的窄 CMQ port；
3. 补全 `rdma_resource_manager` 的生命周期提交、依赖检查和 ERROR 恢复状态；
4. 实现软件 PD 的 create/destroy；
5. 实现普通 MR 的 register/deregister 以及可选的 host_mem 分配 helper；
6. 为后续 14B 的 CQ/SRQ/CEQ/AEQ 和 14C 的 QP create/modify/destroy 固定可复用接口。

Task 14A 完成后，控制面可以在不依赖 PCIe env、AXIS env 或具体 VIP 的情况下生成准确 CMQ 命令、管理资源状态并验证失败回滚；实际环境只需注入生产 adapter。

## 2. 本轮不做的内容

- CQ、SRQ、CEQ、AEQ 生命周期；这些属于 14B。
- QP create/modify/destroy、SQ/RQ backing 和 512B QPC command buffer；这些属于 14C。
- 数据面 `REG_MR`/fast-register；普通软件注册只使用 `KEY_ALLOC(0x04)`，`MR_REGISTER(0x05)` 保留给后续数据面语义。
- 把 `pcie_env`、`axis_env`、`host_mem` 实现类或任意 VIP 变成控制面的固定子组件。
- 重新定义已经冻结的 xtr_v1 opcode、context body、CMQ envelope、doorbell 或 error-code codec。
- 为 PBL2 新造 HMC memory writer。14A 可以消费已准备好的 PBL2 描述和 lease，但不会在没有外部 HMC 写接口时假装完成 PBLE 初始化。

## 3. 事实基线

### 3.1 当前仓库

- `rdma_resource_manager.create_*()` 目前只保留身份并发布 `ALLOCATED` 资源。
- `freeze()` 只能执行 `ALLOCATED -> PROGRAMMED`；普通 `release()` 只能释放 `ALLOCATED` 资源，尚不能表达 ACTIVE、QUIESCING、hardware-delete commit 或 ERROR recovery。
- `rdma_cmq_engine` 是具体类，已经实现 submit、wait、timeout quarantine、late completion、reset cancellation 和 multi-outstanding，但控制面尚无可注入的提交接口。
- `rdma_host_mem_api` 已经提供 allocate/write/read/release，地址和 mapping 为 64 bit。
- `rdma_hmc_allocator` 管理独立的 HMC/FVM aperture 和 lease，不调用 host_mem，也不能把 HMC 地址混入 backing/IOVA。
- xtr_v1 composer/codec 已支持 `KEY_ALLOC`、`MR_REGISTER`、`MR_DEREGISTER`、`OCC_FLUSH` 和 `TQ_FLUSH`。

### 3.2 53 上真实驱动

审计基线为：

```text
10.11.10.53:/home/ubuntu/workspace/Desktop.zip
dpu_kernel_rdma-version_0.1.32/
```

真实驱动行为固定为：

- `pd.c` 只分配和释放软件 PD ID，不发送 PD create/delete CMQ。
- 普通 `mr.c:xtrdma_hwreg_mr()` 使用 `KEY_ALLOC(0x04)`，不是 `MR_REGISTER(0x05)`。
- MR 先分配 STAG/PBL，再发送硬件注册命令；失败按 PBL、STAG 的逆序释放。
- PBL2 注销前发送 OCC flush，之后发送 `MR_DEREGISTER`，再执行必要的 TX drain/flush，最后释放 STAG/PBL/backing。
- STAG 的硬件格式为 24-bit index 加 8-bit key；PD 硬件字段为 16-bit index。

## 4. 已确认的设计选择

1. Task 14 分三批实施：14A 事务框架和 PD/MR，14B CQ/SRQ/EQ，14C QP。
2. PD 为纯软件资源，不生成不存在的硬件命令。
3. 所有 control-plane API 使用同步事务语义；返回前要么完整提交，要么完成可证明的逆序回滚。
4. MR 注册与 backing 所有权分离；额外提供驱动自持 backing 的便捷事务。
5. 有 live dependent 时销毁返回 `RESOURCE_BUSY`，不做隐式级联销毁。
6. rollback/cleanup 失败时保留 `ERROR/RECOVERY_REQUIRED`，不删除仍可能在 DUT 中有效的资源。
7. 采用“事务协调器 + 类型化依赖接口”，不为每类资源复制事务框架，也不构造通用声明式脚本引擎。

## 5. 总体架构

```text
typed request + backing descriptor
                |
                v
       rdma_control_plane
       |       |       |
       |       |       +--> context model/composer/codec
       |       +----------> rdma_cmq_port
       |                       |-- production adapter -> rdma_cmq_engine
       |                       `-- mock port
       +------------------> rdma_resource_manager
       +------------------> rdma_host_mem_api (仅 owned helper/cleanup)
       `------------------> rdma_hmc_allocator (存在 HMC lease 时)
```

控制面是编排者，不保存第二份权威资源状态。registry、资源字段、生命周期状态和 persistent recovery record 由 resource manager 统一管理。CMQ、host_mem 和 HMC 的实际访问只能通过注入接口完成。

### 5.1 `rdma_control_plane`

公开同步 task：

```text
create_pd()
destroy_pd()
register_mr()
alloc_and_register_mr()
deregister_mr()
recover_resource()
```

它负责：请求校验、事务加锁、硬件 ID 投影、context 构造、CMQ 执行、状态提交、逆序回滚和结果汇总。它不手工拼接 bit，也不拥有 PCIe/AXIS/VIP 实例。

### 5.2 `rdma_cmq_port`

port 提供两个能力：

- `execute()`：提交一条类型化 command descriptor 并等待 terminal completion；
- `reconcile()`：对 timeout/quarantined ticket 查询 late completion、reset 或仍不确定的状态。

生产 adapter 包装现有 `rdma_cmq_engine.submit()` 和 `wait_for()`；mock port 可以按 opcode、第 N 次调用或事务阶段注入 submit、completion、timeout 和 rollback failure。控制面不得 down-cast 到生产 engine。

### 5.3 `rdma_resource_manager`

现有 `create_pd()`/`create_mr()` 继续作为身份 reservation 入口。新增受控提交接口：

```text
commit_programmed()
activate()
begin_quiesce()
restore_active()
mark_error()
finalize_release()
release_reserved()
```

每个接口校验 expected state，并在一次原子 registry 更新中提交资源字段和状态。lookup 仍只返回 deep-copy snapshot；调用者不能直接修改 registry。

resource manager 维护反向依赖检查。PD 下存在 MR/QP/SRQ 等 live dependent 时，`begin_quiesce()` 返回 `RDMA_SC_RESOURCE_BUSY`。

### 5.4 host_mem 与 HMC

- borrowed MR 路径只校验并引用 caller-owned mapping，不需要 control plane 拥有 host_mem。
- `alloc_and_register_mr()` 要求注入 `rdma_host_mem_api`，由控制面申请 mapping，并标记为 control-plane-owned。
- HMC lease 保持强类型 `rdma_hmc_fvm_addr_t`，不能转换成 IOVA/backing address。
- PBL2 描述必须引用已准备且归属一致的 lease/first-PBL index。14A 验证和追踪该 lease，但 PBLE 的实际准备必须由拥有 HMC 写能力的上层或后续 adapter 完成。

## 6. 数据对象

### 6.1 MR backing 描述

新增 `rdma_mr_backing_desc`，包含：

- `rdma_dma_mapping mappings[$]`；
- `rdma_mr_page_layout page_layout`；
- 每个 mapping 的 ownership；
- 可选 PBL2 lease reference 及其 ownership；
- descriptor 所属 Function/generation 和 requester BDF/PASID 快照。

ownership 只有两个值：

```text
BORROWED
CONTROL_PLANE_OWNED
```

borrowed 对象在 deregister/recovery 时永不调用 release。owned 对象恰好释放一次；release 失败时保持 residual 标志并进入 ERROR。

为避免 mapping 与 ownership 使用易失配的平行数组，resource snapshot 保存成带 ownership 的 backing reference value object。旧 `backing_mappings` 的调用方在本任务内迁移到该包装对象，不能同时维护两个权威列表。

### 6.2 软件 handle 与硬件 projection

registry handle 的 `object_id` 是带 kind/incarnation 的 32-bit 软件身份，不是硬件 ID。控制面从 authoritative resource 的 local ID 构造只用于 context/codec 的 projection handle：

| 对象 | 软件身份 | xtr_v1 投影 |
|---|---|---:|
| PD | registry handle | `local_pd_id[15:0]` |
| MR | registry handle | `local_mr_id[23:0]` STAG index |

projection 继承 Function UID/generation 和正确 kind，但 `object_id` 只携带硬件 local ID。它不能用于 registry lookup/release。resource manager 必须在 reservation 时执行 per-kind 宽度限制，不能等到 codec 才发现 local ID 溢出。

MR key 的权威值为：

```text
lkey = {24-bit STAG index, 8-bit STAG key}
rkey = remote permission present ? lkey : 0
```

8-bit key 由可确定、可注入的 STAG-key policy 生成，默认策略保证同一 local index 的相邻 incarnation 使用不同 key。测试使用固定 policy；控制面不接受与 index/权限矛盾的任意 lkey/rkey。

### 6.3 事务结果与恢复记录

`rdma_control_result` 是每次调用的不可变结果快照：

```text
transaction_id
status
primary_status
rollback_statuses[]
resource_handle
completed_steps[]
final_resource_state
recovery_required
```

`rdma_resource_txn` 是运行中的显式事务记录，只追踪已定义的资源步骤，不执行任意 callback/脚本。事务终止时：

- 成功或完整回滚：运行记录可丢弃；
- 未完整回滚：冻结成 persistent recovery record，并与 ERROR resource 一同存入 resource manager。

recovery record 至少保存：最后一个确认完成的步骤、残留 owned mapping/HMC lease、CMQ ticket、硬件对象是否已确认存在/删除，以及每个 undo step 的完成位。

## 7. 状态机与并发

### 7.1 PD

```text
NEW -> ALLOCATED -> ACTIVE -> QUIESCING -> RELEASED
                         `--------------> ERROR
```

PD 没有 PROGRAMMED 阶段，因为没有硬件命令。PD create 的本地提交失败时直接释放 reservation。

### 7.2 MR

```text
NEW -> ALLOCATED -> PROGRAMMED -> ACTIVE -> QUIESCING -> RELEASED
          |             |           |           |
          `-------------+-----------+-----------+--> ERROR
```

- `PROGRAMMED` 只表示 `KEY_ALLOC` 已收到成功 completion。
- `ACTIVE` 表示硬件成功且 registry/backing/dependency 字段已经提交。
- `QUIESCING` 阻止新的动态引用。
- `ERROR` 表示硬件或 cleanup 状态不能由普通 API 安全推进。

### 7.3 并发和 generation fence

每个 Function 使用一把 lifecycle semaphore：

- 同一 Function 的 create/destroy/recover 串行；
- 不同 Function 的事务可以并行并使用 CMQ multi-outstanding；
- 数据面提交不被全局锁序列化。

事务在入口、CMQ terminal completion 后和最终 registry commit 前检查 binding generation。发生 rebind/reset 后，旧 generation 的 completion 不得激活资源；事务必须回滚或进入 ERROR。

## 8. API 语义与事务顺序

### 8.1 PD create

```text
validate ACTIVE Function binding
-> reserve PD identity (ALLOCATED)
-> validate 16-bit local PD ID
-> activate PD
```

全过程不调用 CMQ/HMC/host_mem。返回成功时 PD 已经 ACTIVE。

### 8.2 PD destroy

```text
lookup ACTIVE PD
-> check reverse dependents
-> begin_quiesce
-> finalize_release
```

有 dependent 时返回 `RDMA_SC_RESOURCE_BUSY`，状态仍为 ACTIVE。禁止隐式递归销毁 MR/QP/SRQ。

### 8.3 borrowed MR register

```text
validate request, ACTIVE PD and backing descriptor
-> verify Function/generation/BDF/PASID/IOVA/length/permissions
-> reserve MR identity (ALLOCATED)
-> validate 24-bit STAG index and derive key/lkey/rkey
-> attach borrowed backing and optional HMC lease
-> construct projected PD/MR handles
-> build and validate rdma_mrt_model
-> compose KEY_ALLOC(0x04)
-> CMQ execute and wait
-> commit_programmed
-> activate
```

普通 MR 路径固定使用 `KEY_ALLOC`。`MR_REGISTER(0x05)` 不得作为失败后的 fallback，也不能根据 body 中非零字段猜测。

### 8.4 owned helper

`alloc_and_register_mr()` 先用 host_mem 分配连续、对齐的 mapping，再调用同一个内部 register 事务。14A helper 生成 PBL0 descriptor；调用者可以在注册前后通过 host_mem write 注入数据。

如果 register 失败，helper 只有在 mapping ownership 已转移给事务后才负责释放；ownership 转移前的失败由 helper 自身释放。任何路径都不能双重 release。

### 8.5 MR deregister

```text
lookup ACTIVE MR
-> check static/dynamic use
-> begin_quiesce
-> PBL2: OCC_FLUSH
-> MR_DEREGISTER
-> required drain/TQ_FLUSH policy
-> release owned HMC lease/backing
-> finalize_release
```

xtr_v1 默认策略镜像真实驱动：PBL2 先 OCC flush，deregister 后执行必要的 TX drain/flush。borrowed backing 只解除 registry 引用，不调用 host_mem release。

## 9. 回滚与恢复规则

回滚只撤销“已经收到成功确认”的步骤，并严格逆序执行。

### 9.1 create/register 失败

- `KEY_ALLOC` 前失败：释放 owned HMC/backing 和 reservation。
- `KEY_ALLOC` 明确失败：不发送 deregister，释放本地 owned 资源。
- `KEY_ALLOC` 成功、后续 registry commit 失败：发送 `MR_DEREGISTER`，再释放 owned 资源和 reservation。
- rollback deregister 或 cleanup 失败：资源保留为 ERROR，顶层结果为 `RECOVERY_REQUIRED`。

### 9.2 destroy 失败

- OCC flush 明确失败且没有 destructive command 成功：可恢复 ACTIVE。
- `MR_DEREGISTER` 明确失败：若 completion 明确证明命令未生效，可恢复 ACTIVE；状态不确定则进入 ERROR。
- deregister 已成功而 drain/cleanup 失败：硬件对象不能恢复，资源进入 ERROR；recovery 从 drain/cleanup 继续，不重复 deregister。

### 9.3 timeout 和 reset

CMQ timeout 后 command ticket 处于 quarantine，命令可能 late-complete。控制面不得释放 STAG、mapping 或 HMC lease，也不得复用 local ID。

`recover_resource()` 先通过 CMQ port reconcile：

- late success：按成功后的剩余 rollback/cleanup 继续；
- late hardware failure：按“硬件命令未成功”的路径清理；
- 仍不确定：保持 ERROR；
- 仅有 `RESET_CANCELLED` 状态并不能证明硬件未执行。只有 Function/device reset teardown 提供硬件状态失效证明后，才能跳过 delete 并释放本地资源。

recovery 必须幂等；每个成功 undo step 标记完成，重复调用不会重复 deregister、release 或回收 ID。

## 10. 状态码和结果优先级

在现有 5-bit `rdma_status_code_e` 中增加：

- `RDMA_SC_RESOURCE_BUSY`，category 为 RESOURCE；
- `RDMA_SC_RECOVERY_REQUIRED`，category 为 STATE。

结果优先级：

1. 原操作失败且完整回滚：对外 `result.status` 为原错误；
2. 原操作失败且回滚失败：`result.status` 为 `RECOVERY_REQUIRED`，`primary_status` 保留原错误，`rollback_statuses[]` 保存全部后续错误；
3. 操作成功但最终 cleanup 失败：`result.status` 为 `RECOVERY_REQUIRED`，资源保留 ERROR；
4. UVM fatal 只用于内部类型/registry 不变量破坏，不能用于可预期的 DUT、CMQ、timeout 或资源繁忙错误。

## 11. 测试设计

### 11.1 单元测试

新增 `rdma_control_plane_test`，使用 mock CMQ port、现有 mock host_mem 和真实 resource/HMC/model/composer：

- PD create/destroy 不产生 CMQ 调用；
- PD 有 MR dependent 时返回 RESOURCE_BUSY；
- stale Function/handle 被拒绝；
- borrowed mapping deregister 后仍 active 且未 release；
- owned helper deregister 后恰好 release 一次；
- 普通 register 只发送 KEY_ALLOC，destroy 发送 MR_DEREGISTER；
- software incarnation 与 PD/STAG projection 完全分离；
- lkey/rkey、权限、IOVA、长度、BDF、PASID 和 page layout 校验；
- PBL2 destroy 顺序为 `OCC_FLUSH -> MR_DEREGISTER -> drain/TQ_FLUSH -> cleanup`；
- 同 Function 事务串行，不同 Function 可并行；
- generation 在 CMQ outstanding 期间变化时不提交 ACTIVE。

### 11.2 故障矩阵

对下列阶段逐点注入失败：

```text
reserve
host_mem allocate/release
HMC lookup/release
model validation
codec/composer
CMQ submit
CMQ completion
registry commit
rollback command
final cleanup
```

每行检查：primary status、rollback chain、最终 resource state、CMQ 命令顺序，以及 mapping、HMC lease、STAG/local ID、CMQ ticket 是否回到预期基线。

### 11.3 timeout/recovery

覆盖 timeout 后的 late success、late failure、仍不确定和 generation reset teardown。重复 recovery 必须证明 delete/release 的 call count 不增加。

### 11.4 生产 adapter 组合测试

增加一条不依赖完整外部 env 的组合测试：

```text
rdma_control_plane
-> production rdma_cmq_port adapter
-> real rdma_cmq_engine
-> existing host_mem mock/adapter + VIP completion responder
```

该测试证明 mock port 与真实 engine 的 submit/wait/reconcile 契约一致。真实 DUT 环境后续复用同一个 production adapter，不改变 control-plane API。

## 12. 验收标准

所有仿真在 `10.11.10.53` 上通过 bash login shell 执行：

1. 新增 control-plane 单元测试 UVM warning/error/fatal 为 `0/0/0`；
2. 生产 CMQ adapter 组合测试为 `0/0/0`；
3. 现有 resource manager、HMC、codec、doorbell、CMQ engine 和 host_mem integration 回归不退化；
4. Python tests 和 xtr frozen checker 全部通过；
5. 测试结束时 resource、owned mapping、HMC lease 和 CMQ ticket live count 回到基线；
6. borrowed mapping 在 MR 注销后仍由调用者拥有；
7. 任意不确定硬件状态都保留 ERROR/RECOVERY_REQUIRED，不出现“registry 已释放但 DUT 可能仍有效”的假成功。

## 13. 后续边界

14B 在本事务框架上增加 CQ/SRQ/CEQ/AEQ 的 backing、context create/delete 和 rollback；14C 增加 QP 的多 backing、512B QPC buffer、transport-specific create/modify、状态机和 flush。两批都复用本设计的 CMQ port、result/recovery record、ownership、projection 和 resource-manager transition API，不重新定义另一套控制面。
