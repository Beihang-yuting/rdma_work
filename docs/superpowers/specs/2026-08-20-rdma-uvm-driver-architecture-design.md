# RDMA UVM 驱动与 PCIe Function 映射架构设计

日期：2026-08-20

状态：设计已确认，等待书面规格复核

## 1. 背景与依据

本设计面向真实 RDMA DUT，目标是在 UVM 中复现软件驱动的资源创建、队列组织、
上下文编码、doorbell 下发、DMA 内存交互和网络数据交互。环境需要能复用现有
host_mem、pcie_work、net_packet 和 axis_vip，但 RDMA 核心不以这些环境的具体
class 为编译期必选依赖。

本设计基于以下已检查版本：

- 53 主机上的 dpu_kernel_rdma-version_0.1.32，提交
  491faf2ba42627fffd4dd027607299c8bb591ec2。
- 53 主机上的 dpu_user_rdma-version_0.1.32，提交
  6543ee80057ea3387cc2265f5e8cf8311839ffb3。
- pcie_work main，提交 cf24ddc01680e4da15c2670f21bcf87dcd9905bc。
- host_mem master，提交 3b9e000d5df4d10efbb3029f43605e0362e0caca。
- virtio_work feat/dpu-fabric-virtio-hardening 中的通用 Function key、资源 lease
  和 BAR aperture 管理模式。

已上传的真实 RDMA 驱动不包含父网卡 PCI driver。父驱动中 configure_dmi、
configure_vft、PCIe Function 创建和 notify table 配置的具体实现不可见。因此，
设计不得假设 PCIe VF index、pfvf_id、rdma_vf_id 或 global_function_id 具有
固定算术关系。

## 2. 目标

### 2.1 功能目标

环境应支持：

1. 以软件驱动语义创建和销毁 PD、MR、CQ、QP、SRQ、CEQ、AEQ、CMQ 等资源。
2. 申请 host memory、注入 payload、生成 IOVA 和硬件可消费的队列映像。
3. 编码多种 QPC/CQC/MRT/EQC、CMQ SQE、数据面 SQE/RQE、CQE/AEQE。
4. 通过 CMQ 发送多种命令 SQE，并支持批量提交和多个 outstanding 命令。
5. 支持多类 doorbell、写入宽度、大小端、顺序、barrier 和 non-merge 约束。
6. 驱动真实 DUT 的配置、队列和 doorbell，并观察 DMA、completion 和中断。
7. 显式管理 PF/VF、BDF、BAR、notify、DMI、VFT 和 RDMA 逻辑 Function 映射。
8. 支持 64-bit host address 和 IOVA，不受 32 MiB PF BAR0 aperture 限制。
9. 可选接入 net_packet 或 axis_vip，用于观察、生成或辅助回应网络流量。
10. 在不实例化 pcie_env 或 axis_env 时，RDMA 核心仍可进行 codec、资源和
    sequence 级单元测试。

### 2.2 非目标

- 不在 RDMA 核心中重新实现完整 PCIe、AXIS 或 host memory VIP。
- 不把 pcie_env 和 axis_env 固化为 rdma_env 的子组件。
- 不假设 UVM 需要逐行模拟 Linux 内核 API；UVM 模拟的是驱动语义和硬件效果。
- 不在缺少父驱动源码时猜测生产系统的 VF 编号公式。
- 第一阶段不要求模拟操作系统、VFIO、IOMMU page-table walk 或完整 verbs ABI。

## 3. 核心架构

采用“协议核心 + 可选适配器”的组合方式：

~~~text
RDMA test / virtual sequence
             |
             v
        rdma_env
             |
     +-------+-----------------------------+
     |       |             |               |
     v       v             v               v
 resource  codec         engines       scoreboard
 manager   registry   CMQ/SQ/RQ/CQ/EQ
     |                       |
     +-----------+-----------+
                 |
            abstract APIs
        +--------+---------+----------------+
        |                  |                |
        v                  v                v
 host_mem_adapter   pcie_work_adapter   net_adapter
        |                  |             /      \
     host_mem         pcie_work    net_packet  axis_vip
                           |
                        real DUT
~~~

rdma_env 只持有抽象接口句柄。外部组件由 testbench 或更高层 fabric env 创建并
通过 uvm_config_db 注入。未注入某个适配器时，相应功能显式进入 model-only、
passive 或 disabled 状态，不允许隐式创建另一套外部环境。

### 3.1 建议包边界

- rdma_types_pkg：枚举、错误码、地址类型、Function identity 和轻量 struct。
- rdma_model_pkg：语义请求、运行时资源、硬件字段模型和硬件映像。
- rdma_codec_pkg：codec 基类、registry 和各版本 codec。
- rdma_core_pkg：资源管理器、各执行 engine、doorbell 调度器和 scoreboard。
- rdma_adapter_pkg：只声明抽象 API，不 import 外部 VIP package。
- rdma_pcie_work_adapter_pkg：允许 import pcie_tl_pkg。
- rdma_host_mem_adapter_pkg：允许 import host_mem_pkg。
- rdma_net_adapter_pkg：分别提供 net_packet 和 axis_vip 实现。
- rdma_test_pkg：基础 sequence、场景 sequence 和测试。

外部 package 依赖只出现在相应 adapter package，避免污染 RDMA 核心的编译依赖。

## 4. 四层数据模型

复杂度通过四层模型隔离，禁止 sequence 直接拼接裸 bit vector。

### 4.1 语义请求层

语义请求表达测试意图，例如：

- rdma_create_cq_req
- rdma_create_qp_req
- rdma_modify_qp_req
- rdma_register_mr_req
- rdma_post_send_req
- rdma_post_recv_req
- rdma_destroy_resource_req

语义请求包含操作类型、Function handle、资源引用、SGE、payload、期望错误和超时
策略，不包含某一代硬件的位域位置。

### 4.2 运行时资源层

每个资源由 class 对象表示，保存：

- owner Function handle；
- local ID 和 hardware/global ID；
- generation；
- 生命周期状态；
- host backing allocation；
- IOVA mapping；
- HMC/FVM 地址；
- 队列 producer/consumer index；
- 依赖资源；
- 已提交和 outstanding 操作。

主要对象包括：

- rdma_function
- rdma_pd
- rdma_mr
- rdma_cq
- rdma_qp
- rdma_srq
- rdma_ceq
- rdma_aeq
- rdma_cmq

资源只能通过 rdma_resource_manager 创建、查询、冻结和释放。sequence 保存 handle，
不直接拥有 allocator 状态。

### 4.3 硬件字段模型层

硬件字段模型以语义字段命名，覆盖：

- QPC、CQC、MRT、SRQC、CEQC、AEQC；
- CMQ 各 opcode 的 request/response SQE；
- RC、UD、URC 等类型 SQE；
- RQE、CQE、CEQE、AEQE；
- CMQ、SQ、RQ、CQ、CEQ、AEQ、SRQ、状态转换和 flush doorbell。

字段模型包含合法性检查，但不负责内存分配、PCIe 发送或等待 completion。

### 4.4 硬件映像层

rdma_hw_image 是 codec 输出，至少包含：

- byte data；
- byte length；
- alignment；
- endian；
- image kind 和 hardware version；
- 所属 Function generation；
- 可选写入目标地址；
- 用于调试的字段摘要。

只有 hw image 可以写入 host memory、CMQ ring、HMC backing 或 doorbell payload。

## 5. 地址模型

以下地址必须使用不同 typedef 和字段，禁止用一个 addr 表示多种地址空间：

| 地址 | 含义 |
|---|---|
| backing_addr | host_mem 分配器中的实际存储地址 |
| iova | DUT 通过 PCIe 发起 DMA 时携带的地址 |
| hmc_fvm_addr | HMC/FVM 内部对象地址 |
| bar_base/bar_addr | RC 访问 EP MMIO 时使用的 PCIe BAR 地址 |
| cfg_offset | 单个 PCIe Function 的 4 KiB配置空间偏移 |
| notify_base | 8 KiB 对齐的 doorbell aperture 绝对地址 |

默认无 IOMMU 模式可以采用 iova 等于 backing_addr，但必须由 DMA mapping 对象明确
记录，不能依赖数值碰巧相同。

host_mem_adapter 负责：

1. 按队列和硬件结构要求申请对齐内存；
2. 将 payload 和 hw image 写入 backing memory；
3. 建立和撤销 DMA mapping；
4. 返回 backing_addr 与 iova；
5. 在资源销毁时检测泄漏和 use-after-free。

host_mem 的接口和内部地址均为 64-bit。单次申请长度受其 int unsigned size 参数
限制，但不影响将队列或 payload 放置在 4 GiB 以上地址。

## 6. Codec 与可扩展硬件定义

### 6.1 Codec registry

所有 codec 通过 registry 查询，查询 key 至少包含：

~~~text
hardware_version
image_kind
object_type 或 opcode
queue/type variant
~~~

例如同一个 create_qp 语义请求可以根据 hardware version 选择不同 QPC 和 CMQ SQE
编码器。新增 QPC 类型、SQE 类型或 error-code 只需注册新 codec，不修改执行 engine。

codec 统一提供：

- encode(model, image)
- decode(image, model)
- validate_model(model, result)
- validate_image(image, result)
- describe_fields()

### 6.2 多种 QPC 和 SQE

QPC 采用公共头加类型扩展：

~~~text
rdma_qpc_model
  common fields
  transport_type
  transport extension
    RC
    UD
    URC
    reserved/custom
~~~

数据面 SQE 同样采用 opcode 基类与类型扩展，不用一个包含大量无效字段的单体 class。

### 6.3 CMQ 多 opcode

CMQ request 包含 command ID、opcode、Function、input model、output expectation 和
timeout。cmq_codec_registry 根据 opcode 生成对应 SQE，并解析 completion。

CMQ engine 支持：

- 单命令同步提交；
- batch 提交；
- 多 outstanding；
- command ID 分配和回收；
- completion 乱序匹配；
- ring wrap；
- per-command timeout；
- batch 中局部失败；
- reset 时取消 outstanding。

## 7. 执行引擎

### 7.1 CMQ engine

负责 command ring、SQE 编码、memory barrier、CMQ doorbell 和 completion 匹配。
资源管理器不直接写 CMQ。

### 7.2 SQ/RQ engine

负责：

- 将语义 WR 转为一种或多种 SQE/RQE；
- 组织 inline、SGE 和外部 payload；
- 更新 producer index；
- 在 payload/SQE 对 DUT 可见后下发 doorbell；
- 跟踪 WR ID、PSN 和 completion。

### 7.3 CQ/CEQ/AEQ engine

负责轮询或事件驱动消费 CQE/CEQE/AEQE，执行 owner/wrap 检查，更新 consumer index，
并发送 CQ/CEQ/AEQ doorbell。CQE 中的硬件 error-code 由 error codec 转换为统一
rdma_status。

### 7.4 Doorbell scheduler

doorbell 描述对象必须包含：

- doorbell kind；
- Function binding handle；
- BAR 和 offset；
- width；
- byte order；
- payload image；
- barrier policy；
- write-combining policy；
- 是否允许 merge；
- 前置写入依赖；
- timeout 和可选 readback。

默认顺序为：

~~~text
payload/backing write
→ queue/context image write
→ DMA visibility barrier
→ MMIO ordering barrier
→ doorbell write
~~~

不同 doorbell 类型可以覆盖 barrier 和宽度，但不能绕过 binding 与生命周期检查。

## 8. PCIe、VF、BAR 与 RDMA Function 映射

### 8.1 真实驱动责任边界

真实 RDMA 模块注册为 auxiliary driver：

~~~text
dpu_snd1.roce
~~~

它不调用 pci_enable_sriov、pci_disable_sriov、pci_iomap 或 pci_iov_vf_id。
父网卡驱动通过 xtrdma_pf 传入：

~~~text
pdev
hw_addr
host_id
rdma_vf_id
vsi_id
MSI-X entries
cfg_ops
grm_ops
hardware spec
~~~

RDMA probe 的主要顺序是：

~~~text
copy parent binding
→ configure_dmi(rdma_vf_id)
→ initialize control resources
→ initialize runtime resources
→ configure_vft(rdma_vf_id)
→ register RDMA device
~~~

kernel doorbell 使用 hw_addr 加固定 offset。userspace doorbell mmap 使用：

~~~text
pci_resource_start(pdev, BAR0) + 0x2000
~~~

映射长度为 0x2000。由此可知，BDF、BAR 和逻辑 ID 的正确绑定必须在 RDMA
auxiliary probe 前由父层建立。

### 8.2 三层身份

#### PCIe Function identity

描述传输和地址路由：

~~~text
root_id
host topology key
PF/VF kind
parent PF
vf_index
BDF
requester_id
BARs
MSE/BME
MSI-X
~~~

#### Notify binding

描述 RC doorbell MMIO 如何得到硬件逻辑身份：

~~~text
BAR ID
notify offset
notify absolute base
notify table sel/index
host_id
pfvf_id
~~~

#### RDMA logical Function

描述 RDMA/HMC 资源归属：

~~~text
rdma_vf_id
global_function_id
vsi_id
hmc_func_id
resource quota/profile
~~~

三层由 rdma_function_binding 显式组合。

### 8.3 硬件映射闭环

已检查的硬件定义表明：

~~~text
(BDF, BAR, notify_base)
  → notify table: host_id + pfvf_id
  → VFT[pfvf_id]: rdma_vf_id
  → DMI[rdma_vf_id]: host_id + global_function_id
~~~

QPC、HMC 和其他运行时上下文继续使用 host_id、rdma_vf_id 和 vsi_id。

强制约束：

1. vf_index、BDF Function Number、pfvf_id、rdma_vf_id 不得互相推导。
2. RDMA_HID_MAP_TABLE 以 rdma_vf_id 为索引，所以活动 binding 的 rdma_vf_id
   在一个 DUT 实例中必须唯一。
3. VFT 定义只暴露 pfvf_id 索引。除非某个 RTL profile 明确声明 VFT 按 host
   分 bank，否则 pfvf_id 也按 DUT 实例全局唯一处理。
4. notify_base 必须 8 KiB 对齐。
5. notify window 必须完整落在所属 BAR aperture 内。
6. binding 的 host_id 必须与 notify 和 DMI 两处一致。
7. binding 只有在 PCIe、notify、DMI、VFT 和 DMA domain 全部验证后才能 ACTIVE。

### 8.4 默认部署模式

默认采用真实 SR-IOV 模式：

- 每个 VF 有独立 BDF/requester ID；
- VF BAR aperture 互不重叠；
- 每个 VF 绑定一个 RDMA logical Function；
- DMA domain 以 BDF 和可选 PASID 隔离。

允许定义 PF 共享物理 Function 的扩展模式，但默认关闭。该模式要求每个逻辑
Function 具有不同 notify_base，并且通过 PASID 或非重叠 IOVA domain 隔离 DMA。
若多个逻辑 Function 使用相同 BDF、相同 notify address 且 doorbell 中没有额外
Function 字段，则硬件无法区分，配置必须被拒绝。

### 8.5 pcie_work 可复用能力

pcie_work 已具备：

- 4 KiB Function config space；
- PF/VF context 和 BDF LUT；
- FirstVFOffset/VFStride；
- SR-IOV capability；
- 64-bit BAR pair；
- VF aggregate BAR aperture；
- address-to-BDF/BAR/VF decode；
- config read/write sequence；
- RC 和 EP memory TLP；
- host_mem auto-response。

DPU profile 当前定义：

| Function | BAR0/1 | BAR2/3 | BAR4/5 |
|---|---:|---:|---:|
| PF | 32 MiB | 64 KiB | 64 KiB |
| VF | 16 KiB | 16 KiB | 32 KiB |

真实驱动的 VF doorbell window 位于 VF BAR0 加 0x2000，长度 0x2000，刚好完整
落在 16 KiB VF BAR0 中。

VF BAR 绝对地址采用：

~~~text
vf_bar_base =
  sriov_vf_bar_aggregate_base + vf_index * per_vf_bar_size

vf_notify_base = vf_bar0_base + 0x2000
~~~

真实 DUT 模式下，FirstVFOffset、VFStride、BAR base 和 NumVFs 应从真实 config
space 枚举结果读取；DPU profile 公式只用于纯模型或明确选择该 profile 的测试。

### 8.6 pcie_work 接入缺口

adapter 必须处理或推动 pcie_work 修正以下问题：

1. pcie_tl_env_config 没有直接暴露 DPU config profile。
2. env 没有自动连接 config_proxy.func_mgr 和 multi_function_mode。
3. 非 bypass SR-IOV config write 不完整更新 BAR、MSE/BME、VFE 和 BDF LUT。
4. pcie_tl_bar_decoder 尚未接入标准 env 数据路径。
5. EP initiate_dma 没有设置发起 VF 的 requester_id。
6. 通用 memory sequence 没有 Function identity 参数，requester_id 可能被随机化。
7. DMA 发起前没有统一检查 VF BME、binding state 和 DMA domain。
8. pcie_tl_env 将 RC host memory 初始化为 0 到 0xFFFF_FFFF，限制了已有
   host_mem 的 64-bit 能力。

RDMA 核心不得通过复制这些 class 绕过问题。rdma_pcie_work_adapter 应集中封装
Function-aware config、MMIO 和 DMA API，并在底层能力不足时返回明确错误。

### 8.7 PCIe 事务身份规则

RC 写 EP doorbell：

~~~text
requester_id = RC BDF
target Function = 由 MMIO address 对 VF BAR aperture 解码
address = vf_bar0_base + 0x2000 + doorbell offset
~~~

EP/VF 向 host memory 发起 DMA：

~~~text
requester_id = VF BDF
address = 该 VF DMA domain 中的 IOVA
~~~

config request：

~~~text
completer_id = 目标 PF/VF BDF
offset = 0..4095
~~~

不能用 RC 到 EP Memory Write 的 requester_id 选择目标 VF；Memory TLP 的目标
Function 由 BAR 地址路由。

## 9. PCIe 配置与 Function 生命周期

### 9.1 配置顺序

真实 DUT 的推荐顺序：

1. RC 枚举 PF 并读取 SR-IOV capability。
2. 读取 FirstVFOffset、VFStride、TotalVFs 和 BAR descriptor。
3. 执行 PF/VF BAR sizing 和地址分配。
4. 写入 NumVFs、VF aggregate BAR、ARI、VF MSE 和 VFE。
5. 枚举每个有效 VF BDF，并验证独立 config space。
6. 计算并验证每个 VF BAR aperture。
7. 创建 PREPARED 状态的 rdma_function_binding。
8. 配置 notify table。
9. 配置 DMI。
10. 初始化 CMQ、HMC、EQ 和运行时资源。
11. 配置 VFT。
12. 将 binding 原子切换为 ACTIVE。
13. ACTIVE 后才允许 doorbell 和 DMA。

第 8 至 12 步应由事务式 lifecycle manager 执行。任何一步失败都按相反顺序回滚。

### 9.2 状态机

~~~text
DISCOVERED
  → PCIE_CONFIGURED
  → BOUND
  → PREPARED
  → ACTIVE
  → QUIESCING
  → RESETTING
  → RELEASED

任一准备或活动状态
  → ERROR
~~~

每次 reset、FLR、disable 或重新绑定都递增 generation。旧 generation 的资源
handle、doorbell 请求和 DMA completion 不得作用于新实例。

### 9.3 VF disable/FLR 顺序

推荐顺序与真实驱动 remove 的意图一致：

1. binding 进入 QUIESCING，拒绝新 WR 和 doorbell。
2. 清除 VFT valid，阻止新 ingress 映射。
3. 等待或取消 outstanding CMQ/DMA。
4. 执行 TQ/QP/OCC flush。
5. 释放 CQ/QP/MR/HMC 和中断资源。
6. 清除 DMI。
7. 撤销 notify 和 DMA mapping。
8. 禁用 VF 并从 BDF LUT 删除。
9. 递增 generation，进入 RELEASED。

真实驱动当前部分 probe 失败路径没有对已经成功的 DMI/VFT 做完全对称清理。UVM
lifecycle manager 不复制这一缺陷，并通过每个失败注入点验证 rollback。

## 10. DMA 与 host memory

rdma_dma_mapping 至少记录：

~~~text
binding handle + generation
requester BDF
optional PASID
backing_addr
iova
size
direction
permissions
state
owner resource
~~~

DMA 前检查：

- binding 为 ACTIVE；
- generation 匹配；
- PCIe Function BME 开启；
- requester_id 与 binding BDF 一致；
- IOVA 范围被映射；
- 方向和权限匹配；
- 请求不越界、不溢出 64-bit 地址；
- resource 未被释放或冻结。

pcie_work 辅助回应模式下，RC memory responder 使用注入的 host_mem handle。
rdma_env 不重新 init 已由上层初始化的 host_mem，也不把地址范围强制缩小到 4 GiB。

## 11. 网络适配

网络侧采用 rdma_net_api：

- send_packet；
- receive_packet；
- register_observer；
- configure_response_policy；
- inject_drop/corruption/delay。

net_packet adapter 用于包级生成与检查。axis_vip adapter 用于真实 DUT AXIS 端口的
beat 级驱动、采样和 backpressure。两者可以同时存在：net_packet 生成语义 packet，
axis_vip 负责物理 AXIS 传输。

没有网络 adapter 时，RDMA 核心仍可验证资源创建、memory image、CMQ、doorbell
和本地 completion codec。

## 12. 真实 DUT 与辅助 VIP 模式

支持三种明确模式：

### DUT 模式

- config、BAR MMIO、DMA requester 和网络接口均连接真实 DUT。
- PCIe/AXIS VIP 只负责发送、监控和 host-side 合法回应。
- DUT 是配置和运行时状态的唯一权威。

### Model-only 模式

- pcie_work config proxy、BAR decoder 和 memory responder 模拟设备或链路。
- 用于 codec、资源和 sequence 的快速回归。

### Hybrid assist 模式

- 只有配置中明确声明的地址或事务类型由 VIP 回应。
- DUT 和 VIP 不得同时回应同一个 config、MMIO 或 non-posted memory request。
- 每个 responder region 必须在 build phase 完成唯一性检查。

## 13. 错误模型

统一 rdma_status 包含：

- status category；
- software-visible code；
- hardware error-code；
- source engine；
- Function handle 和 generation；
- resource ID；
- command/WR ID；
- severity；
- retryable；
- 原始 image 摘要。

错误类别包括：

- configuration；
- resource exhaustion；
- invalid state；
- codec/format；
- timeout；
- PCIe completion；
- DMA translation/permission；
- queue overflow/underflow；
- CQE/AEQE hardware error；
- network protocol；
- reset/cancel。

UVM fatal 只用于无法继续构建环境的结构性错误，例如 codec registry 冲突或重复
的活动硬件 ID。预期硬件错误、负向测试和运行时失败通过 rdma_status、analysis
port 和 scoreboard 报告。

hardware error-code 由版本化 error codec 解释。未知 code 保留原始值并归类为
UNKNOWN_HW_ERROR，不得静默当成成功。

## 14. Scoreboard 与可观察性

scoreboard 分成四个关联视图：

1. Intent view：语义请求和期望状态变化。
2. Image view：写入 host memory/HMC/queue 的实际硬件映像。
3. Transport view：PCIe config/MMIO/DMA 和 AXIS/network 事务。
4. Completion view：CMQ completion、CQE、CEQE、AEQE、中断和超时。

关联 key 使用 Function handle/generation 加 command ID、WR ID、QP/CQ ID，不能只
使用可能复用的局部 ID。

PCIe monitor 需要发布：

- config target BDF 和 offset；
- BAR decode target BDF、BAR ID 和 offset；
- requester_id；
- DMA address、size、direction；
- completion status；
- MSI-X vector。

## 15. 验证策略

### 15.1 单元测试

- 每个 codec 的 encode/decode round-trip 和 golden vector。
- 非法字段、保留位、大小端和长度检查。
- allocator 对齐、泄漏、generation 和 use-after-free。
- CMQ command ID、batch、乱序 completion、ring wrap 和 timeout。
- 每种 doorbell 的 width、payload、barrier 和 offset。

### 15.2 PCIe/VF 映射测试

- 多 PF、多 VF BDF 唯一性。
- FirstVFOffset/VFStride 的 config-space 枚举结果。
- PF/VF 64-bit BAR pair sizing、对齐和无重叠。
- VF aggregate BAR 到 per-VF aperture 的切片。
- BAR 地址解码结果与期望 BDF 一致。
- 8 KiB notify 对齐和 aperture 边界。
- notify、VFT、DMI 三表闭环。
- 重复 pfvf_id、rdma_vf_id、错误 host_id 和错误 BDF 必须失败。
- VF disable 后 config/BAR/DMA 访问必须被拒绝。

### 15.3 DMA 测试

- VF requester ID 正确。
- 错误 requester ID、越权 IOVA、方向错误和跨界访问失败。
- 4 GiB 以上地址的 Memory Read/Write。
- 多 VF 相同 IOVA 数值但不同 DMA domain 的隔离。
- FLR 后旧 completion 和 stale mapping 被拒绝。

### 15.4 数据面测试

- RC/UD/URC send、recv、write、read、atomic。
- inline、多 SGE、零长度、最大长度和跨页。
- 多 QP、多 CQ 和多 Function 并发。
- CQ overrun、RQ empty、retry、RNR、超时和 error-code。
- 网络 drop、重排、重复和错误 packet。

### 15.5 仿真要求

涉及真实接口或完整集成仿真的验证必须在 10.11.10.53 上使用 bash login shell
运行 VCS。单元级静态检查不能替代该主机上的编译和仿真结果。

## 16. 分阶段交付

### 阶段一：基础模型

- package、地址类型、状态和错误模型；
- host_mem 抽象接口；
- resource handle/generation；
- hw image 和 codec registry；
- 最小 CMQ/doorbell 单元测试。

### 阶段二：控制面

- QPC/CQC/MRT/EQC 与 CMQ codec；
- CMQ multi-opcode、多 outstanding；
- PD/MR/CQ/QP 创建、修改和销毁；
- rollback 和 error injection。

### 阶段三：数据面

- SQE/RQE/CQE/AEQE codec；
- SQ/RQ/CQ/EQ engine；
- payload/SGE/inline；
- memory barrier 和 doorbell 调度。

### 阶段四：PCIe Function 集成

- rdma_function_binding；
- pcie_work adapter；
- 真实 config enumeration、BAR 和 SR-IOV；
- notify/DMI/VFT；
- Function-aware DMA；
- FLR 和多 VF 隔离。

### 阶段五：网络与完整场景

- net_packet 和 axis_vip adapter；
- 端到端 RC/UD/URC；
- 性能、并发、错误恢复和覆盖率收敛。

各阶段保持 RDMA 核心可独立编译。外部 adapter 的回归作为独立 filelist 和测试层，
避免外部 VIP 缺失时阻塞 codec 与资源单元测试。

## 17. 验收标准

设计实现完成的最低标准：

1. RDMA 核心在无 pcie_env、axis_env 时可编译并运行单元测试。
2. 所有资源均通过 typed handle 和 generation 管理。
3. host memory、IOVA、HMC、BAR 和 config 地址无混用。
4. CMQ 支持多 opcode、batch 和多 outstanding。
5. QPC、doorbell、SQE 和 error-code 可通过 registry 扩展。
6. 真实 SR-IOV VF 的 BDF、BAR、notify、VFT、DMI 显式绑定并双向校验。
7. VF DMA TLP 携带正确 requester ID，且 64-bit IOVA 可达 4 GiB 以上 host memory。
8. VF FLR/disable 不影响其他 VF，旧 generation 事务不能污染新实例。
9. 真实 DUT 模式中不存在 DUT/VIP 双重 responder。
10. 所有完整集成测试在 53 主机通过 VCS 验证。
