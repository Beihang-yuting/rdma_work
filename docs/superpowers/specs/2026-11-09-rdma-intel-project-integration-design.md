# RDMA 共享配置与 Intel PCIe 集成设计

日期：2026-11-09。状态：待审阅，尚未实现本文提出的接口。

配套案例见 [Intel 集成参考](../../rdma-intel-integration-reference.md)。本文讨论软件集成与代码简化；真实 DUT 的引脚、复位、链路就绪和业务验收由平台接入后验证。

## 1. 目标与依据

用户要求参考 **Virtio 当前正在修改的 integration/project**，复用 `dpu_common`、`pcie_work`、Intel PCIe 和 AIP，减少重复代码，保留清楚的职责和中文注释。后续补充要求是参考 53 上的驱动生成 RDMA Notify 表，并支持 RDMA/VIO 共存时由一个配置 sequence 管理。成功标准是：用户自己的 env/cfg 可以直接组合这些组件，资源只分配一次，公共配置只执行一次，错误能传回调用者，模型回归仍可运行。

RDMA 已从本地 `main` 切换到跟踪远程的 `feature/rdma-param-v1`，同步基线为 `6ab999b3b7f9f188f3c3ba7f17b6e046f9c93973`。本次设计不修改外部仓库。

| 参考仓库 | 阅读基线 | 本次采用的信息 |
| --- | --- | --- |
| `virtio_work` | `review/virtio-sdd-optimized`，`eeef858`，含未提交修改 | 当前 project 的直接组合、公共配置迁移、平台 hooks、AIP 参数重载 |
| `dpu_common` | `5385c5a`，含未提交修改 | 公共配置、冻结快照、BAR map、表类型与配置 sequence |
| `pcie_work` | `d78b11a`，含未提交修改 | RC/EP 传输、共享内存、寄存器访问的严格顺序与状态读 |
| `pcie_intel` | `77d2c6a` | Intel adapter、HARD_IP wrapper 与实例 override |
| `aip_core_set_param_expr` | `feat/set-param-expressions`，`a036723`，跟踪 `origin/update` | 参数宏、task/sequence 注册、五参数 `aip_cmd_reg` |
| `host_mem` / `net_packet` | `35ec087` / `b212855` | 公共 manager/pool 与参数化报文能力 |

表中提交号不能单独复现带未提交修改的接口；实现和验证时需要记录参与编译的实际工作区版本。不要用旧 `aip_core` main 替代这里的 AIP checkout。

## 2. 方案选择与范围

采用 **直接组合配置 + 现有适配器收敛**：用户 env_cfg 持有 `dpu_env_cfg`、`rdma_env_cfg`、`pcie_tl_env_config`；用户 env 负责创建、连接和发布句柄；RDMA 继续使用现有 driver/resource/agent。

另外两条路径不采用：完整复制 Virtio project 会重新引入已删除的表配置包装层；一次重写 RDMA 全部驱动、流量和资源层会把集成与协议语义变更混在一起。参考工程不要求用户继承参考 cfg，也不增加一个包住三份 cfg 的公共配置类。

本设计的首个实现范围是外部快照接入、共享内存/PCIe 绑定、AIP 收敛和含 RDMA/VIO 统一配置入口的 project 案例。并发流量、无信号完成与旧 flow resolver 的全面迁移在第 7 节单列，避免第一轮集成同时改变 WR 执行语义。

## 3. 唯一数据来源与生命周期

| 信息或资源 | 权威/所有者 | RDMA 使用方式 |
| --- | --- | --- |
| Host、PF/VF、BDF、BAR、global Function ID、服务资源 | `dpu_common` 的 authoring 与一次 resolver 结果 | 借用冻结的 device/resource snapshot，不重新声明拓扑或写回快照 |
| Host memory manager/pool | 用户环境；缺省创建也只在组装层进行一次 | `rdma_host_mem` 借用所属 Host manager，维护每个 Function 的分配账本 |
| RDMA CMQ/EQ/CQ/QP/MR、实际 backing IOVA | RDMA driver/resource 层 | 配置与网络路由导出实际结果，不用合成 handle/地址代替 |
| PCIe RC、tag、Completion、Intel VIF | `pcie_work`、`pcie_intel` 与平台 | RDMA 借用 sequencer/VIF，保持底层事务生命周期 |
| 网络 endpoint、真实 reset/readiness | 平台 | 显式绑定，缺失时拒绝进入业务 |

每个 Host 一份 manager、一个 RC slot、一个 Intel 端口；同 Host 的 PF/VF 共用端口。Host ID 不必等于 slot。`dpu_pcie_bar_map` 为配置 seq 和 RC driver 共享的同一对象，不在 PCIe 配置中重新分配 BAR。

真实集成的 `rdma_env` 位于 `dpu_device_env` 子树，使 DPU build 先完成一次解析，再向 RDMA 提供快照。当前 `rdma_env.build_system()` 总会创建并解析自己的系统，因此仅调整 UVM 层级还不能完成集成。

需要在现有系统入口增加明确的外部快照绑定路径；以下是**待实现契约**，不是现有 API：

- 外部路径接收 device/resource snapshot 和已绑定的 Host manager，检查 Function/service 身份、完整映射和资源容量后创建 RDMA 投影；不调用 resolver，不创建本地 DUT 模型。
- 节点的 BAR 依赖收敛到已有 `rdma_drv_bar` 抽象，继续调用 `rdma_drv_hw.bind_hw()`。模型专用 `dev` 只在模型节点存在；probe、报告、链路和 reset 调用必须按职责分开，不能依靠空 `dev` 被偶然跳过。
- 独立模型/PEER 入口保留显式 authoring 与模型创建。测试专用默认值留在测试支撑中，仍供 PEER 使用的能力不能直接删除。
- 一旦某个 Function 存在活动队列，不允许重绑 snapshot、manager 或 BAR。新拓扑需要重建环境；外部对象的销毁仍由其所有者决定。

### DPU 当前接口的限制

`dpu_env_cfg.load_params()` 的默认 authoring 仍面向 VIO：Function 默认允许 `DPU_SERVICE_VIO_NET`，默认 placement profile 为 `virtio.qpair`。首次加载也会拒绝已经填好的非空拓扑。

因此 RDMA 参考工程应接收平台已经完成 authoring 的 `dpu_env_cfg`，通过现有 DPU 配置类型在 resolve 前显式声明 RDMA 服务与资源需求；不对该对象再次调用默认拓扑生成入口。参数读取可使用 AIP 宏，资源解析仍只在 DPU 执行一次。缺失 RDMA service 是构建错误，不能把 VIO service 当作 RDMA 使用。

## 4. Intel PCIe 与公共配置

复用 `intel_pcie_configure_env()`，在创建 `pcie_tl_env` 前设置实例 adapter override。实际 DUT 提供 EP application logic：启用 RC、禁用模型 EP 与 `ep_auto_response`，wrapper 使用 `SIDE="HARD_IP"`。历史配置键 `pcie_svt_bridge_required` 在此仅用于引脚 bridge，不代表需要 SVT provider。

当前公共 Intel map 支持每 Host 一个 segment 0；Intel PF 编号最多 7、VF 编号最多 2047，PF 的 `vf_index=-1`。逻辑 BDF、Requester ID、Intel PF/VF sideband 是不同字段，必须来自平台显式映射。不存在的 Host/Function 不回退到 RC0，也不按 global ID 截位推导。

现有 `rdma_pcie_rc_driver` 和 `rdma_pcie_bar` 可继续收敛，避免新增同职责包装类：

- 去掉对 `rdma_pcie_system::current` 的隐式访问，注入本实例所需的 map、Host/slot、sequencer 和模型测试上下文。
- MMIO 按完整字节范围查 BAR；Completion 按 Host/Requester 路由。继承 PCIe RC 的发送、tag 和 Completion 处理，不重新实现 responder。
- DUT DMA 先由接收端口确定 Host，再用 Requester 找 Function，并验证当前 epoch 和该 Function 的完整分配范围。PCIe 的共享 Host backing 本身不能替代 RDMA 的 Function 隔离。
- 既有受保护内存访问若不够接入 PCIe，应在本项目提供最小显式适配；不更改外部组件、不复制 Virtio 特有 IOMMU 代理，也不启动第二条应答线程。

`map.freeze()` 当前检查 Host/segment，并不替项目验证所有 Function 都已有 Intel policy。项目必须遍历快照 Function，确认 policy 和非空 sequencer 齐全后才 publish。

### 配置 sequence

项目只提供一个 `project_dut_cfg_seq extends dpu_cfg_seq` 和一个 AIP `dut_config` 入口，按冻结快照中实际存在的服务组织流程。复用现有 `declare_af`、`configure_bdf_table`、`configure_qsch_rnet` 等类别入口；独立 RDMA 场景也可使用 `configure_rdma_notify`。不能直接运行基类的 VIO 默认 body，也不能顺序启动两个完整配置 seq。

公共 AF/BDF/BAR/MSI-X 按两类服务的需求并集配置一次。VIO 准备/确认/释放复用 `vio_dpu_cfg_seq` 的独立方法；可以创建该 helper，绑定同一 `cfg` 和 sequencer 后直接调用这些方法，**不调用其 `start()` 或 `body()`**。RDMA 准备复用自己的 env/driver。所有表写只由主 seq 发出，因而 AF 每 100 次写的计数、错误结果和使能顺序共用一个状态。

两类 Notify 分别生成并排序记录，然后合并进一次 `write_records(batch, ok, why)`。VIO 表和 RDMA 表仍是不同类别、不同地址、不同表项格式；合并的是发送批次。当前公共实现会在整批成功后按管理 BAR 去重，使能一次。连续调用两个 `configure_*_notify()` 会分别使能，不能达到这个批次语义。

RDMA Notify 所需的 Function 身份、RDMA ID 与真实 BAR 窗口在 connect/publish 前已经确定；它不依赖后续 QP/CQ 分配。先完成 Notify、QSCH/RNET 等驱动访问的路由前提，再执行可能发送 CMQ 的 RDMA probe，随后准备实际 QP/CQ/MR。VIO 的 QSCH/VTX/VRX 使用其准备阶段导出的 ring。全部必需步骤成功才确认两类业务可运行。

任一步失败保留已准备资源，待平台停止 DMA 后分别释放，不宣称已发送配置可以原子回滚。无某类服务时跳过对应准备和表生成，不用空 scope 表示“没有服务”，因为 DPU 的空选择代表全部成员。

`DPU_TABLE_RDMA_NOTIFY` 的记录目前来自显式 `frozen_controls`；8B entry 的 Host、RDMA Function ID 和地址字段须有真实来源。53 上 EMP 的 `dpu_af_insert_rdma_notify_tbl_entry()` 按 `{host_id, notify_addr[60:13]}` 排序，`dpu_af_alloc_rdma_vf_id()` 从独立的 256 项 bitmap 分配 RDMA ID。该 ID 不是 Intel VF index、Notify 行号或 global Function ID。

当前 RDMA `probe()` 直接把 `global_id` 写到 `drv_cfg.vf_id`；混合场景必须改为消费平台发布的明确 RDMA ID 映射，并让 Notify、RNET、驱动 QPC/PD/EQ 使用同一结果。当前 DPU 虽支持 RDMA service 声明，却没有专用的 `rdma_vf_id` 导出；第一轮接入使用本项目校验的显式平台映射，不增加第二个全局 Function 分配器，不按遍历顺序猜值。映射需覆盖全部 RDMA Function、ID 唯一且小于 256，并在配置前冻结。

当前 DPU 表校验要求 VF owner、index < 256、reserved=0、Host 匹配；但 EMP 源码明确说名字中的 “vf” 实际指 PCI Function。**VF-only 是当前适配限制，不是驱动的硬件结论。** 首个用例选择平台支持的 VF；PF RDMA 需要本项目显式适配或后续公共契约扩展，不能伪造 VF key 绕过检查。

另一个现有限制是 `dpu_cfg_scope.validate()` 的显式 service 列表只枚举 VIO。RDMA 首轮用非空 Function 列表和明确表类别选择，并独立对 RDMA service 做快照校验；不把 RDMA service 塞入 VIO-only 校验，也不声称支持同 Function 内任意部分 RDMA service 重配。

公共 seq 已负责 AF 握手及配置写节奏、Notify 成功后每个不同管理 BAR 的 `+0x80044=1`。这与 Virtio 当前设计记录中的硬件约定一致；旧驱动的 RDMA `+0x48`、双 bank 翻转和全表写回不能随字段算法一起移入。保持当前行为；空批次不使能，任何配置失败停止后续业务。主 seq 保留 `success/error_msg`，并继承当前失败时 fatal 的 `post_start()`，避免 AIP 将空结果当成成功。具体来源与差异见配套参考第 9 节。

RDMA `rdma_drv_bar.write64()` 使用 iowrite64be：8 字节按大端发送。公共表使用 DWORD 写及其既定顺序。两者不能为了复用 `reg_acc` 而交换字节序或改写事务宽度。

## 5. AIP 参数、任务与恢复

继续使用现有 `rdma.env.*`、`rdma.biz.<业务>.{qp,mem,pkt,trf}.*` 路径；DPU 和 PCIe 各读自己拥有的参数。宏会使用局部变量名构造参数键，内部改名时须保留外部路径。

| 参数类别 | 唯一采样时机 | 重载边界 |
| --- | --- | --- |
| Host/Function、BDF/BAR、服务资源额度 | DPU resolve 前 | 当前快照内不可重载 |
| QP/CQ/MR 大小、协议属性 | 创建这一代 RDMA 资源前 | 无活动队列、平台已停止 DMA 并释放当前代后 |
| WR 长度、SGE、操作选择、数据模式 | 生成下一条逻辑 WR 时 | 业务空闲时更新表达式，下一条 WR 生效 |

参数读取使用 `aip_int/aip_enum/aip_string` 及集合宏；表达式由 AIP 一个实现解释。删除 RDMA 的重复解析前，必须核对已有定值、区间、候选列表、权重和递增语法的行为及随机采样次数，补齐调用者迁移；不能用一次启动采样替代逐 WR 采样。

队列满时保留同一条已采样的 pending WR；重试不重新随机、不再次计数、不覆盖在途 buffer。非法长度/SGE 应给出参数路径与合法范围，不能继续默默裁剪分布值。

project 只注册一个 `rdma_load_params` task 和所需 sequence/reg 命令；混合工程使用一个协调两类候选的 `load_params` task，以及一个 `dut_config` sequence 命令。复用 AIP 宏，不编写命令注册表或一组用户命令类。组合 Virtio 与 RDMA 时，由项目统一协调同名 `reg_acc` 和通用 `load_params`，避免重复注册。

重载采用局部候选值：先检查业务空闲/资源释放，再读取和完整验证，全部成功才写回同一配置对象。失败保持原配置；不隐含 reset、释放、写表或重新分配 BAR。task 明确填写 AIP `status/result_out`；`aip_cmd_user_seq` 本身不会检查任意自定义 `success` 字段。

命令入口可借用项目已有 virtual sequencer；参考包中的单一命令上下文仅服务 AIP 入口，不能成为 driver/router 的全局环境定位方式。首轮不增加后台并发配置框架，重入直接拒绝。

## 6. 启动、失败与平台边界

```text
平台 authoring 与参数加载
  → DPU 一次 resolve；创建 RDMA/PCIe 组件
  → 绑定相同 manager、冻结 BAR/Intel map、发布句柄
  → 平台复位/接口就绪
  → 公共控制配置；VIO 准备/导出 ring
  → 两类 Notify 合批；QSCH/RNET 等驱动访问前提
  → RDMA probe 与实际 QP/CQ/MR 准备；完成其他适用配置与检查
  → 开放业务/AIP
  → 排空、数据与协议检查、停止 DMA、释放资源
```

RDMA Notify/RNET 必须先于依赖这些路由的 CMQ 请求；实际 QP/CQ 创建后的网络投影再使用真实资源，不能拿合成 IOVA 提前填充。第一次实现须用调用顺序测试固定这两类依赖。

base_test 保留三个强制平台入口：`bind_platform_handles()` 绑定现有 VIF/内存/endpoint，`prepare_platform()` 执行真实 reset/readiness，`finish_platform()` 完成排空、数据/DMA/PCIe 检查与停机。后两者必须有完成判定和超时，不能用空 task 返回成功。

配置失败不进入业务，已发送的 posted write 不宣称可回滚；已分配内存保持到平台确认 DMA 静止后再释放。真实 reset 后使旧资源、事务和 route epoch 失效，不能调用本地设备模型的 `flr()` 代替硬件复位。已有 route/authority/epoch 检查属于必要边界，不能作为“精简”删除。

## 7. 代码简化清单与后续流量优化

| 现有位置 | 发现 | 处理方式 |
| --- | --- | --- |
| [rdma_env.sv](../../../src/tb/rdma_env.sv)、[DPU adapter](../../../src/adapters/dpu/rdma_dpu_adapter_pkg.sv) | 环境内再次 author/resolve，并为每个 Function 创建设备模型 | 增加消费外部快照的明确路径，模型构建留在模型入口；移除集成路径上的重复全局配置 |
| [Host memory adapter](../../../src/adapters/host_mem/rdma_host_mem_pkg.sv) | 固定地址 manager 工厂；显式 include 外部 manager | 绑定共享 manager；核对新 `host_mem_pkg` 后删除重复 include，保持同一类型身份 |
| [PCIe adapter](../../../src/adapters/pcie_work/rdma_pcie_work_pkg.sv) | 全局 `current`、模型 RC/EP 组装和 transport 混合 | 用实例依赖；保留模型故障注入用途；真实路径借用外部 PCIe env |
| [业务配置](../../../src/tb/rdma_biz_cfg.sv)、[AIP adapter](../../../src/adapters/aip/rdma_aip_cfg_pkg.sv) | 两套表达式语法，部分非法抽样被裁剪 | 收敛到 AIP 采样，保留核心 typed 参数与显式错误 |
| [flow resolver](../../../src/model/rdma_flow_resolver.sv) | 生成合成 QP/CQ handle、QPC/SQ/RQ/HMC 地址 | 后续改为实际资源投影；所有消费者迁移前不能整文件删除 |
| [verb agent](../../../src/tb/rdma_verb_agent.sv)、[业务序列](../../../src/tb/rdma_biz_vseqs.sv) | 默认 signaled 路径逐条等完成；资源满缺少等待；无信号尾部另加操作 | 后续以有界在途 WR 与完成驱动回收改进，不混入首轮接入 |

后续吞吐优化借鉴 Virtio 的采样/背压方式，不迁移 CSUM/TSO/GSO 等协议专属功能。无信号尾部优先让每个 QP 的最后一条**实际请求**带 signaled，不附加影响 count 或数据的 Atomic/Write；零请求不能生成清尾业务。窗口同时受 SQ 深度、buffer slot 和可观测完成约束。

RDMA doorbell 还包含 `HW_DROP_DB_CNT` 的影子状态握手；本轮不增加 Virtio 式 `notify_batch` 抑制。保持既有协议行为，待独立测试覆盖后再讨论合并通知。

## 8. 验收与代码风格

实现按可审查的职责分批提交；每批同步调用者、package、filelist、案例和测试，删除确已替代的生产实现。只转抄字段或同名转发的层不保留。

所有触及的源码从文件入口复审。类内 `extern`、类外实现；每个函数/task 紧邻具体中文“功能 / 输入输出及副作用 / 失败边界”；类型与变量间使用 Tab，复杂条件分行。测试辅助函数同样执行，避免借整文件格式化扩大无关 diff。

无需真实 RTL 即可验证的契约包括：

1. 两个 Host 使用相同 BDF 时仍按 Host 路由；缺 policy/slot、非零 segment、跨 BAR、未知 requester 被拒绝。
2. PCIe 与 RDMA 引用同一个 manager；跨 Function、释放后和旧 epoch DMA 被拒绝；双环境互不串线。
3. 公共表写与 8B 大端 doorbell 的地址/顺序/字节内容正确；Notify 空批次、表写失败和使能失败均有结果。
4. AIP task/sequence 只注册一次，错误不会成为 OK；重载失败无部分更新，活动资源不能重载，参数路径与每 WR 采样次数保持契约。
5. 原有单元、模型/PEER、PCIe 故障测试继续通过；真实路径无需构造模型 EP 或本地 DUT NIC。
6. RDMA-only、VIO-only、混合三种配置均覆盖；混合公共表只写一次，两类 Notify 合批后每管理 BAR 只使能一次，任一类失败时不进入业务。Notify 排序行号、RDMA ID、global Function ID 刻意取不同值，检出身份混用。

全部编译与 VCS 仿真在 `ubuntu@10.11.10.53` 的登录 bash/已加载 `.bashrc` 环境执行，并记录依赖工作区版本。平台接线后的 reset、Intel 链路、CMQ/DMA/网络数据与错误恢复由用户接入验证，模型通过不能替代这些结果。

本文与配套案例目前仅完成源码接口核对和文档静态检查，未进行本轮 VCS 或 DUT 验证。
