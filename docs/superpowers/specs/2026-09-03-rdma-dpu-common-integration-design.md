# RDMA 与 dpu_common 集成及多 Host/PF/VF 架构设计

## 状态

- 日期：2026-09-03
- 状态：已完成架构评审，等待实施计划
- 适用仓库：`rdma_work`
- 硬件 profile：`rdma`
- 硬件 ABI 版本：`1`

## 1. 背景与目标

`virtio_work/dpu_common` 已经承担 DPU 的全局设备配置、PCIe 拓扑、Host、PF/VF、BAR、全局 Function ID、跨服务资源以及 Host-memory/PCIe 路由职责。RDMA 项目不应重新解析这些信息，而应在其上建立每个 Function 独立的 RDMA 运行时。

本设计的目标是：

1. 以 `dpu_resource_pkg` 为 RDMA 集成层的唯一全局拓扑来源。
2. 支持多个 Host、多个 PF、PF 下多个 VF，以及多个 PCIe root。
3. 让每个 PF/VF 拥有独立的 RDMA Function context，同时保持不同 Function 间的资源、DMA、doorbell 和 completion 隔离。
4. 将控制面、数据面、codec、Host-memory 和 PCIe 适配器分层，避免协议逻辑与外部组件实现耦合。
5. 使 SQ/RQ/CQ/CEQ/AEQ 的 PI、CI、wrap、credit 和 slot ledger 只有一个状态权威，并在失败和 reset 后可恢复或安全隔离。
6. 保持底层 types/model/codec/core 可以脱离 `dpu_common` 做单元测试；集成 filelist 再引入实际 DPU 环境。
7. 统一内部 profile 命名为 `rdma`，保留数值硬件 ABI 版本 `1`。
8. 所有新增普通源码和测试使用 `.sv`；`.svh` 仅用于宏和固定 mask 等头文件内容。

## 2. 范围和非目标

### 2.1 范围

- 新增 RDMA 与 `dpu_common` 的集成层。
- 建立全局 `rdma_device_env` 和每个 Function 的 `rdma_function_context`。
- 引入只读 Function identity、完整路由键和 reset epoch。
- 为 Host-memory 和 PCIe 建立按 Function/Host 路由的 RDMA wrapper。
- 明确 CMQ、SQ、RQ、CQ、CEQ、AEQ 的事务顺序、pending journal 和恢复策略。
- 将当前 `xtr_v1` 内部 profile 名称一次性迁移为 `rdma`，同时保持 ABI 版本为 1。
- 增加多 Host/PF/VF/root、错误恢复和 reset 级联的单元及集成验证。

### 2.2 非目标

- 不修改外部 `dpu_common`、PCIe endpoint/backend、Host-memory manager 或网络组件的实现。
- 不在本项目重新实现 PCIe 枚举、Host-memory 分配算法或 DPU 全局资源仲裁。
- 不在本设计中定义新的 RDMA 协议 opcode、QPC 字段或硬件 bit layout；这些仍由 codec/profile 层管理。
- 不把构建产物、仿真日志、缓存、SSH wrapper 或访问凭据同步到仓库。

## 3. 总体架构

```text
dpu_device_env                         （virtio_work，全局权威）
├── dpu_device_snapshot
├── dpu_resource_snapshot
├── dpu_resource_manager
├── host_mem_pool_ref
└── rdma_device_env                    （本项目集成层）
    ├── rdma_function_context[Function]
    │   ├── rdma_function_identity
    │   ├── rdma_function_binding
    │   ├── rdma_resource_manager
    │   ├── rdma_control_plane
    │   │   └── rdma_cmq_engine
    │   ├── rdma_sq_engine
    │   ├── rdma_rq_engine
    │   ├── rdma_cq_engine
    │   ├── rdma_eq_engine
    │   ├── rdma_queue_runtime
    │   ├── rdma_doorbell_scheduler
    │   └── rdma_recovery_coordinator
    ├── rdma_pcie_router
    └── rdma_host_mem_router
```

一个 PF 或 VF 对应一个 `rdma_function_context`。Context 是 Function 级资源和状态的所有者；`rdma_device_env` 负责创建、查找、quiesce、reset 和销毁 Context，但不直接编码队列 entry。

## 4. 包依赖和编译边界

底层 package 的依赖方向，以及集成层的组装关系如下（箭头表示“使用”）：

```text
dpu_resource_pkg                 （外部 virtio_work）
        ↓
rdma_dpu_env_pkg                 （读取 DPU snapshot，组装 integration）
        ↓
rdma_device_env / rdma_function_context

rdma_types_pkg → rdma_model_pkg → rdma_codec_pkg → rdma_adapter_pkg → rdma_core_pkg
                                                                    ↑
                                               rdma_dpu_env_pkg ────┘
```

`rdma_types_pkg`、`rdma_model_pkg`、`rdma_codec_pkg` 和 `rdma_core_pkg` 不直接导入 `dpu_resource_pkg`。`rdma_dpu_env_pkg` 只负责把 DPU 快照转换为 RDMA 可消费的值快照，并把外部 Host-memory/PCIe 引用接到 router。这样既可保持 core 的独立单元测试，又可避免在多个底层文件重复解析拓扑。

集成 filelist 按以下顺序编译：

1. 外部 `dpu_common` 定义及其 `dpu_resource_pkg`。
2. RDMA `types`、`model`、`codec`、`adapter`、`core` package。
3. `src/integration/rdma_dpu_env_pkg.sv` 及其包含的集成 class。
4. 集成测试 package 和 testbench。

纯 RDMA 单元测试继续使用现有 core filelist，不需要 `dpu_common`。

## 5. Function identity 和路由

### 5.1 身份结构

`src/types/rdma_identity_types.sv` 已定义 `rdma_function_key_t`，包含：

- `root_id`；
- `host_topology_key`；
- Function 类型（PF/VF）；
- parent PF BDF；
- VF index；
- Function BDF（含 segment）。

新增 `rdma_function_identity` 值对象，至少包含：

```text
rdma_function_key_t key
global_function_id
function_uid
generation
reset_epoch
```

字段语义如下：

- `key` 是跨 Host/root/Function 的稳定拓扑身份。
- `global_function_id` 来源于 `dpu_common`，用于跨服务资源索引。
- `function_uid` 是 RDMA 运行时的 opaque incarnation token，只表示一次 RDMA Function 实例，不能代替完整 key。
- `generation` 用于句柄和资源生命周期检查。
- `reset_epoch` 用于隔离旧 DMA mapping、doorbell、CMQ ticket、queue slot 和 completion。

`rdma_dpu_identity_adapter` 将 `dpu_function_key_t`、`dpu_pcie_function_id_t`、`dpu_service_key_t` 及相关 snapshot 转换为上述 identity。转换完成后，RDMA core 不再读取 DPU class 对象。

### 5.2 兼容 binding

`rdma_function_binding` 中现有的 `host_id`、`pfvf_id`、`rdma_vf_id`、`global_function_id` 和 `pcie.bdf` 暂时保留，作为从 identity 派生的兼容字段。新代码必须通过 identity 或只读 accessor 获取 Function 信息，不得把这些字段重新当作独立权威。

binding 的 `make_handle()` 生成带有 Function kind、global ID 和 generation 的 Function handle；所有 handle 比较仍需同时检查 Function UID、object ID 和 generation，跨 Function 不能仅凭本地编号相等而视为同一对象。

### 5.3 外部路由键

所有 PCIe 和 Host-memory 选择均使用：

```text
{host_topology_key, root_id, segment, bdf}
```

Root index 只是仿真或 fabric 路由位置，不是 Function identity。多 root 场景禁止隐式回退到 root0。

## 6. 集成层组件和接口边界

### 6.1 `rdma_device_env`

输入：

- `dpu_device_snapshot`；
- `dpu_resource_snapshot`；
- `dpu_resource_manager`；
- Host-memory pool 引用；
- PCIe fabric/endpoint 引用；
- codec registry 或 hardware profile。

职责：

- 根据 DPU snapshot 枚举可用 PF/VF，并验证 VF parent PF 存在且属于同一 Host/root。
- 为每个 RDMA-enabled Function 创建一个 `rdma_function_context`。
- 保存完整 identity 到 context 的索引，提供按 identity 和 Function handle 查找的接口。
- 实施 Host reset、Device reset 的级联 quiesce 和重建顺序。
- 不直接访问 QP/CQ 资源，不编码或解码 SQE/CQE。

### 6.2 `rdma_function_context`

Context 持有一个不可变 identity 和当前的 binding、generation、reset epoch。其组装的核心对象包括：

- 一个 Function 专属 `rdma_resource_manager`；
- `rdma_control_plane` 和 `rdma_cmq_engine`；
- SQ、RQ、CQ、CEQ、AEQ engine；
- 对应的 `rdma_queue_runtime`；
- 一个 `rdma_doorbell_scheduler`；
- 一个 `rdma_recovery_coordinator`。

Context 对外提供按 Function 作用域检查的控制面和数据面操作。所有公共操作必须先检查 Context 状态、owner、generation 和 reset epoch。Quiesce 或 reset 时先阻止新请求，再处理 pending journal，最后释放资源和 mapping。

### 6.3 `rdma_host_mem_router`

该 router 实现现有 `rdma_host_mem_api`，但不拥有 RDMA 资源：

- `allocate()` 根据 request context 的 Function identity 选择 Host-memory manager。
- 同一 Host 的 PF/VF 可以共享 manager；不同 Host 永不共享 manager。
- 产生的 mapping 保存 requester BDF、Host/root route、DMA domain、PASID、generation 和 reset epoch。
- `write()`、`read()`、`release()` 在访问前验证 mapping 的 Function owner、route、generation 和 reset epoch。
- 旧 epoch mapping 只返回 stale/quarantine 状态，不得重新指向新 Function 的内存。

现有 `rdma_dma_request_context` 和 `rdma_dma_mapping` 增加 route key/reset epoch 的值快照；外部 Host-memory manager 的分配和释放 API 不变。

### 6.4 `rdma_pcie_router`

该 router 实现现有 `rdma_pcie_api`，并维护完整 route key 到 endpoint 的映射：

- `mmio_write()`、DMA visibility barrier、MMIO ordering barrier 通过 Function handle 反查 route key。
- 配置空间访问使用明确的 Host/root/BDF 路由；旧的仅 BDF 接口在映射不唯一时必须返回 ambiguity。
- `get_function_info()` 和 `decode_bar()` 返回对应 route 的 snapshot，不从另一个 Host 或 root 借用 BAR。
- router 不解析 RDMA opcode，不维护 QP/CQ 状态，也不修改 PCIe endpoint/backend。

## 7. 控制面和数据面

控制面保持以下调用方向：

```text
rdma_control_plane
    ↓
queue_lifecycle_executor / qp_lifecycle_executor
    ↓
rdma_cmq_port
    ↓
rdma_cmq_engine
    ↓
codec + Host-memory + doorbell
```

数据面拆分成窄 facade：

```text
rdma_sq_engine
rdma_rq_engine
rdma_cq_engine
rdma_eq_engine
        ↓
rdma_queue_runtime + rdma_queue_txn_journal
```

每个 ring 只有一个 runtime 保存 PI/CI、wrap、used/available credit 和 slot ledger。SQ/RQ/CQ/CEQ/AEQ engine 不得各自复制游标或 credit。

codec 只做语义模型与硬件图像之间的转换和校验；资源分配、Host-memory 访问、PCIe doorbell 和拓扑解析分别由对应层完成。

## 8. 队列事务和 pending journal

### 8.1 公共阶段

`rdma_queue_txn_journal` 为每个未完成事务保存 value-only evidence，至少包括：

- Function identity、generation、reset epoch；
- queue handle、queue kind、当前 cursor 和 next cursor；
- 编码 image；
- producer 请求快照或 consumer CQE/事件快照；
- QP/CQ route 和 WQE release plan；
- MMIO 是否可能提交；
- 失败阶段、状态码和创建时间。

阶段枚举固定为：

```text
NONE
RESERVED
PAYLOAD_WRITTEN
DOORBELL_MAYBE_SUBMITTED
CONSUMER_COMMITTED
WQE_RELEASE_PARTIAL
COMPLETED
```

pending journal 为 runtime 私有所有权。只有事务完成或明确 abort/detach 后才能销毁，调用方不能直接清空 pending。

### 8.2 SQ/RQ/SRQ producer 顺序

```text
请求快照
  → 校验 Function、owner、queue handle、generation、reset_epoch
  → runtime.reserve_producer()
  → 纯函数编码 SQE/RQE
  → Host-memory write
  → 仿真/策略启用 readback 校验
  → DMA visibility barrier
  → producer doorbell（PI/wrap）
  → runtime.commit_producer()
       ├─ 提交 PI/wrap
       ├─ 增加 used/credit
       └─ 写入 slot ledger
  → 发布 post result
```

`reserve_producer()` 只产生临时 cursor，不更新对外 PI/credit。commit 失败时保留 producer pending，不得返回成功结果。SQ 的 doorbell payload 必须来自本次事务的同一 SQE image，RQ/SRQ 的 doorbell 必须携带同一 reservation 计算出的 PI/wrap。

### 8.3 CQ/CEQ/AEQ consumer 顺序

```text
peek current CI
  → Host-memory read
  → owner/polarity 校验
  → 解码并验证 CQE/CEQE/AEQE
  → 在本 Function 内唯一 QPN/CQN 路由
  → 生成只读 release plan
  → DMA visibility barrier
  → consumer doorbell（CI/wrap）
  → runtime.commit_consumer()
  → CQ 执行幂等 WQE release plan（CEQ/AEQ 无此步骤）
  → 发布 completion/event result
```

当前实现中 CQ 的 `match_and_release()` 位于 CI commit 之前；实施时必须改为上述顺序，或引入等价的“两阶段 release token”。CI doorbell 成功、但本地 commit 或 release 失败时，pending 记录已完成的阶段，恢复不得重复 doorbell 或重复释放 WQE。

CQE 的路由必须同时匹配 CQ handle、QPN 和 receive/send 方向；SRQ 关联、共享 CQ、send/recv CQ 分离都必须保持唯一。CEQ/AEQ 没有关联 WQE，CI commit 后即可发布事件。

### 8.4 CMQ 事务

CMQ producer 也使用 descriptor snapshot、ring reservation、Host-memory write、DMA barrier、doorbell、local commit 的顺序。CMQ completion 通过 ticket 和 generation 关联原始命令。

命令 timeout 或 MMIO ambiguous 时，ticket 进入 quarantine，CMQ 状态变为 `POISONED`，控制面停止新命令。只有确认命令尚未提交、或平台提供明确硬件完成查询时，才允许恢复；不得通过重复 command 规避未知状态。

## 9. 错误、重试和恢复

### 9.1 故障语义

| 故障 | 默认处理 | 允许的后续动作 |
|---|---|---|
| Host-memory write/translation 失败 | `RECOVERY_REQUIRED`，标记 known-no-MMIO | 重试相同 image；再次失败则 abort/detach |
| readback mismatch | `RECOVERY_REQUIRED`，不推进 PI/CI | 重新写入并重新校验 |
| DMA barrier timeout | 根据是否进入 PCIe 标记 known-no-MMIO 或 ambiguous | 仅确认未提交后 retry |
| MMIO 失败或 timeout | `mmio_maybe_submitted=1` | 确认未提交后 retry；确认已提交后 finalize；否则 abort |
| generation/reset epoch 变化 | 事务作废并 quarantine | 丢弃旧 mapping、doorbell、ticket 和 completion |
| malformed CQE/CEQE/AEQ | 不推进 CI、不释放 WQE | 修复状态后显式恢复或 abort，不能盲目跳过 |
| QPN/CQN 路由不唯一 | 同上 | 修复路由或执行 Function reset |
| reset 期间到达旧 completion | 丢弃并记录 stale completion | 不写入新 generation ledger |

### 9.2 恢复动作

恢复 API 使用三个显式动作：

```text
RETRY_NO_SUBMIT       // 调用方确认原 MMIO 未发出
FINALIZE_SUBMITTED    // 已确认硬件接受，只补本地 commit/release
ABORT_AND_DETACH      // 放弃该 queue，隔离旧事务
```

`FINALIZE_SUBMITTED` 只能在硬件状态查询或平台侧明确确认后使用。`mmio_maybe_submitted` 为真时，系统不得自动重放。

### 9.3 恢复级联

```text
CMQ 单事务异常
  → ticket quarantine
  → CMQ POISONED
  → 控制面停止新命令

SQ/RQ/CQ 数据面异常
  → 对应 queue runtime = RECOVERY_REQUIRED
  → 只停止该 ring 的新事务
  → 通过 pending journal 恢复或隔离

Function reset/generation 变化
  → Function context QUIESCING/QUARANTINED
  → 隔离该 Function 全部资源、mapping、doorbell 和 completion

Host/device reset
  → 由 rdma_device_env 级联停止并重建受影响的 contexts
```

reset 层级固定为：VF FLR 只影响该 VF；PF reset 影响 PF 及其所有 VF；Host reset 影响该 Host 下全部 Function；Device reset 影响整个 `dpu_device_env`。

## 10. 文件布局和迁移清单

目标布局如下：

```text
src/
├── types/
│   ├── rdma_types_pkg.sv
│   ├── rdma_enum_types.sv
│   ├── rdma_address_types.sv
│   ├── rdma_identity_types.sv
│   └── rdma_status.sv
├── model/
│   ├── rdma_model_pkg.sv
│   ├── rdma_function_identity.sv
│   ├── rdma_function_binding.sv
│   ├── rdma_dma_request_context.sv
│   ├── rdma_dma_mapping.sv
│   ├── rdma_queue_txn_types.sv
│   └── 其余资源、请求、快照模型
├── codec/
│   ├── rdma_codec_pkg.sv
│   ├── rdma_codec_base.sv
│   ├── rdma_codec_registry.sv
│   └── rdma/
├── adapter/
│   ├── rdma_adapter_pkg.sv
│   ├── rdma_host_mem_api.sv
│   ├── rdma_pcie_api.sv
│   ├── rdma_net_api.sv
│   └── rdma_context_backing_api.sv
├── core/
│   ├── rdma_core_pkg.sv
│   ├── rdma_queue_runtime.sv
│   ├── rdma_queue_txn_journal.sv
│   ├── rdma_sq_engine.sv
│   ├── rdma_rq_engine.sv
│   ├── rdma_cq_engine.sv
│   ├── rdma_eq_engine.sv
│   ├── rdma_cmq_engine.sv
│   ├── rdma_doorbell_scheduler.sv
│   └── 其余 control/resource/lifecycle 文件
└── integration/
    ├── rdma_dpu_env_pkg.sv
    ├── rdma_dpu_identity_adapter.sv
    ├── rdma_device_env.sv
    ├── rdma_function_context.sv
    ├── rdma_pcie_router.sv
    ├── rdma_host_mem_router.sv
    └── rdma_reset_coordinator.sv
```

`src/codec/xtr_v1` 一次性迁移为 `src/codec/rdma`，内部 class、宏、registry key、golden reader、测试文件和工具名统一使用 `rdma`。内部 registry key 使用 `"rdma|..."`，数值 `RDMA_HW_VERSION=1` 不变。外部硬件资料若仍称 XTR v1，只在来源文档或注释中保留说明。

每个新增源码文件必须有中文文件头，说明所属层次、职责和依赖；公共 class 必须说明创建者、所有权和释放规则；外部接口必须说明 timeout、失败语义和调用方向。新 RDMA 代码使用两空格缩进、一个声明一行，复杂状态迁移配中文注释。诊断字符串至少包含 Host、PF/VF、Function 和 queue 信息（若相关）。

## 11. 验证策略和验收矩阵

### 11.1 单元验证

- types/model/codec/core 在无 `dpu_common` 条件下继续编译和运行。
- identity/accessor 验证 key、global ID、function UID、generation 和 reset epoch 的比较语义。
- queue runtime 验证 power-of-two depth、PI/CI、wrap、credit、slot ledger、reservation stale 和幂等 release。
- queue engine 验证 producer/consumer 的调用顺序、pending 阶段和恢复动作。
- doorbell scheduler 验证 DMA barrier、MMIO barrier、timeout、readback、merge 禁止和 ambiguous MMIO。
- Host-memory/PCIe router 验证路由、权限、owner、generation 和 epoch 检查。

### 11.2 多 Function 集成验证

必须覆盖：

1. Host0/PF0 与 Host1/PF0 使用相同 BDF 时不串线。
2. 不同 Host 使用相同 IOVA 时不 alias。
3. 同一 Host 的 PF/VF 共享对应 Host-memory manager；跨 Host 不共享。
4. 稀疏 PF/VF ID、缺失 parent PF、跨 Host parent PF 均在绑定阶段拒绝。
5. 两个 Function 使用相同本地 QPN/CQN 时仍能唯一由完整 Function key 路由。
6. Root0/Root1 均能正确访问，且没有 root0 隐式 fallback。
7. VF FLR、PF reset、Host reset、Device reset 的影响范围符合第 9.3 节。
8. reset 后旧 mapping、旧 completion、旧 CMQ ticket 和旧 doorbell 不进入新 epoch。
9. 共享 CQ、send/recv CQ 分离、SRQ receive completion 和重复 QPN 路由均覆盖成功及拒绝路径。
10. CI doorbell 成功但本地 commit/release 失败时，不重复 doorbell、不重复释放 WQE。
11. ambiguous MMIO 不自动 retry；只有显式确认后才执行 retry 或 finalize。

### 11.3 VCS 验证约束

需要仿真时，在 `ubuntu@10.11.10.53` 上使用 login bash shell 执行 core、Host-memory 和 integration regression。构建目录、日志和临时 wrapper 只保留在仿真主机，不加入 git。外部 Host-memory 源继续使用项目现有的 pinned commit/hash preflight。

## 12. 实施顺序和完成标准

实施分为四个可独立验证的阶段：

1. **身份和集成层**：增加 identity、DPU snapshot translator、Function context、Host-memory/PCIe router 及 integration filelist。
2. **事务一致性**：增加 queue transaction phase/release token，修正 CQ release 顺序，补齐 producer/consumer/CMQ recovery API。
3. **engine facade**：将现有 queue data facade 拆为 SQ/RQ/CQ/EQ engine，保持 runtime 为唯一 PI/CI/credit 权威。
4. **profile 和回归迁移**：完成 `xtr_v1` 到 `rdma` 的目录、class、key、golden 和测试命名迁移，运行全部单元和多 Function 集成回归。

完成标准：

- 目标包依赖和目录布局与本设计一致。
- 所有公共接口具备明确 owner、timeout、失败和 reset 语义。
- 多 Host/PF/VF/root 验证矩阵全部有自动化测试。
- VCS core、Host-memory 和 integration regression 在指定主机通过，且没有将外部组件源码或环境产物提交到本项目。
- git 工作树只包含源代码、测试、文档和必要的 `.sv`/`.svh` 文件；无凭据和环境无关文件。
