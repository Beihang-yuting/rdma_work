# RDMA Task 28～31 集成与多 VF 设计

## 状态

- 日期：2026-09-06
- 状态：Task 28～30 已实现并完成验证；Task 31 待实施
- 适用仓库：`rdma_work`
- 前置结果：Task 26 `net_packet` 适配、SR-IOV 枚举、双 env RC SEND E2E 已验证
- 明确跳过：Task 27 AXIS VIP adapter，本阶段不接入 AXIS 外部源码

## 1. 背景与目标

当前 RDMA core 已经具备 queue data engine、真实 host-memory adapter、PCIe SR-IOV
枚举器和 `net_packet` 语义报文适配器。现有双 env E2E 通过发送/接收 sink loopback
完成 RC SEND，但尚未统一管理多个 responder，也没有一个可按模式装配的 `rdma_env`。

本设计覆盖架构计划 Task 28～31，目标是：

1. 防止 DUT、PCIe model、host-memory responder 和 network model 对同一地址/事务区域
   重复响应。
2. 用一个硬件无关的 `rdma_env` 组合层装配 core、codec 和可选 adapter；core-only
   回归不引入任何外部 VIP package。
3. 在现有真实 host-memory 双 env 基础上，扩展 RC、UD、URC 的可复用端到端场景。
4. 支持多个 VF 并发提交和独立故障恢复，验证 DMA domain、Function identity 和
   generation fence 的隔离。
5. 保持外部 `dpu_common`、PCIe、host-mem、`net_packet` 的生命周期由各自环境拥有，
   RDMA 层只保存非拥有引用和冻结值快照。

## 2. 范围与非目标

### 2.1 范围

- 新增 responder region registry，支持 config/MMIO/host-memory/network region claim、
  overlap/overflow 检查、DUT/model/hybrid 策略和 build 后 seal。
- 新增 `rdma_env_config`、`rdma_env` 以及 core-only/model-only/DUT/hybrid 装配测试。
- 新增 transport-aware E2E virtual sequence；复用现有 queue data fixture、真实
  host-memory adapter、`net_packet` adapter 和 CQ polling 逻辑。
- 新增四 VF 并发、相同数值 IOVA 的 domain 隔离、CMQ/CQE/packet/VF-FLR 故障矩阵和
  generation-safe recovery 验证。
- 为每个新增普通 SystemVerilog 文件提供中文文件头、设计说明和逐函数三段式注释。

### 2.2 非目标

- 不实现或引入 AXIS VIP；`AXIS_VIP_ROOT` 继续只作为脚本预留环境变量。
- 不修改外部 `dpu_common`、PCIe、host-mem、`net_packet` 或 VCS/UVM 源码。
- 不把外部源码、仿真日志、build 目录、SSH wrapper、密码或 token 提交到仓库。
- 不在 responder registry 中重写 PCIe BAR allocator 或 host-memory 分配算法。

## 3. 总体架构

```text
rdma_env_config
        |
        v
rdma_env
  ├── rdma_responder_registry
  ├── rdma_function_context[Function]
  │     ├── resource/control/data engines
  │     ├── queue runtime + CQ/CEQ/AEQ polling
  │     └── recovery/generation fence
  ├── optional rdma_pcie_api / rdma_host_mem_api / rdma_net_api
  └── four-view scoreboard event routing
```

`rdma_env` 只创建 RDMA 自有对象。PCIe、host-memory、network 或 DUT responder 由上层
环境创建后以抽象 API 注入；`rdma_env` 不向下 cast 外部实现类，也不创建 `pcie_env`
或 `axis_env` 子组件。

## 4. Responder registry（Task 28）

### 4.1 Region key 与 owner

每个 claim 使用以下不可变字段：

- `rdma_responder_domain_e`：CONFIG、MMIO、HOST_MEMORY、NETWORK；
- `root_id`、`host_topology_key`、segment 和地址 `[base, base+size-1]`；
- `rdma_responder_mode_e`：DUT、VIP、MODEL、MONITOR_ONLY；
- owner 名称和 Function identity（如适用）。

`MONITOR_ONLY` 只观察事务，不拥有响应权，因此不与 responder claim 冲突。除
monitor-only 外，若两个 claim 在同一 domain/root/host 上的区间重叠，registry 返回
`RDMA_SC_INVALID_STATE`；`base+size-1` 的 65-bit 溢出返回
`RDMA_SC_INVALID_ARGUMENT`。

### 4.2 生命周期

`claim()` 只允许在 registry 未 sealed 时调用；`seal()` 后再次 claim 一律返回
`RDMA_SC_INVALID_STATE`。`release()` 必须匹配 owner、domain、base、size 和唯一 lease
ID，成功后 region 可重新 claim；错误释放不能删除其他 owner 的 region。

### 4.3 模式约束

- core-only：无外部 responder，registry 可以为空并直接 seal。
- model-only：MODEL 可拥有声明的 config/MMIO/host-memory/network 区域。
- DUT：DUT 拥有 DUT 真实响应区域；VIP 只可声明 host-memory response 或 monitor。
- hybrid：每个 region 必须显式声明 owner；未声明的区域不能隐式回退到 MODEL。

## 5. `rdma_env` 组合层（Task 29）

### 5.1 配置

`rdma_env_config.sv` 保存 mode、硬件 profile/version、adapter enable/required 位、
超时、queue profile 和 responder region 配置。配置对象为 value snapshot；调用方
修改原始配置不会改变已经 build 的环境。

### 5.2 装配顺序

1. 读取 `uvm_config_db` 中的 `rdma_env_config` 和抽象 adapter 引用。
2. 校验 required adapter、Function identity、generation 和 responder region。
3. 创建 codec registry、resource manager、control/data engine、scoreboard 和
   Function context。
4. 向每个 Function context 注入同一代的 identity、DMA domain 和 reset epoch。
5. 完成 registry `seal()`，之后禁止新增可响应 region。

缺少 optional adapter 时，环境明确进入 model-only/passive/disabled capability；缺少
required adapter 时在 build 阶段报告 fatal。所有 MSI-X/queue/network analysis event
必须携带 target Function、vector 和 generation，不能只传本地 vector 编号。

## 6. RC/UD/URC E2E（Task 30）

端到端 sequence 只调用 `rdma_env` 的语义接口：Function 激活、资源创建、post receive、
post send/read/write/atomic、等待 completion 和销毁资源。sequence 不引用 DUT 层次路径。

覆盖矩阵：

| transport | 操作 |
| --- | --- |
| RC | SEND、WRITE、READ、ATOMIC |
| UD | SEND |
| URC | SEND、WRITE |

URC 在本项目中采用外部 `net_packet` 的 RoCEv2 UC wire profile。该 profile 没有
RDMA READ request opcode，因此 URC READ 是明确的负向能力测试：语义入口和网络
adapter 都必须返回 `RDMA_SC_UNSUPPORTED_OPCODE`，不得映射为 RC READ 或产生任何
queue/network side effect。

每个场景都必须检查：

- 发送和接收 host-memory payload 逐字节一致；
- `net_packet` 编码/解码后的 transport、QPN、PSN、opcode 和 payload 一致；
- SQ/RQ/CQ 的 PI、CI、wrap、credit 和 CQE status 正确；
- 不支持的 transport/opcode 在 post/encode 入口 fail-closed，游标、doorbell、
  network 统计和 host-memory 内容保持不变；
- scoreboard pending、outstanding ticket、mapping、context、QP/CQ/CEQ 资源均为零。

真实 host-memory 场景继续使用不同 Host ID、物理地址和 IOVA；model-only 场景可使用
确定性 mock responder，但必须保持同一 authority/generation 检查。

## 7. 多 VF 并发与恢复（Task 31）

四个 VF 使用不同完整 Function identity、BDF、PF/VF ID、notify window 和 DMA domain，
并发提交 CMQ 与 data-plane WR。至少两个 VF 使用相同数值 IOVA，以证明 domain 隔离而不
依赖 IOVA 数值唯一性。

故障矩阵固定覆盖：

- 错误 requester / Function route；
- IOVA 权限拒绝或越界；
- CMQ timeout 与 late completion；
- CQE error 或错误 owner polarity；
- network packet drop/corruption；
- 单 VF FLR/generation 变化。

每个故障 case 都声明唯一的预期 `rdma_status` 和恢复阶段。FLR 只隔离目标 VF 的旧
generation completion、mapping、doorbell 和 queue state；其他 VF 必须保持 ACTIVE、
数据和中断不变。恢复完成后每个 owned mapping/context 只 release 一次，borrowed
payload 的 release count 必须为零。

## 8. 测试与验收

每个 Task 单独提交并在 `10.11.10.53` 的登录 bash 环境验证：

1. Task 28：registry 正常 claim、完全/部分重叠、overflow、release、seal 和四种模式。
2. Task 29：四种 `rdma_env` 模式、required/optional capability gate、无外部 env 子组件。
3. Task 30：RC/UD/URC transport matrix、真实 host-memory、packet/CQE/scoreboard 和 leak。
4. Task 31：四 VF 并发、六类 fault、FLR generation fence、recovery exactly-once 和 coverage。

最终验收还需执行 core、host-mem、net-packet、PCIe/SR-IOV 回归、Python 静态检查和
`git diff --check`。AXIS suite 不纳入本阶段验收矩阵。
