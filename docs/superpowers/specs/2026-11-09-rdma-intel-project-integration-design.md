# RDMA 共享配置与 Intel PCIe 集成设计

日期：2026-11-09。状态：按用户反馈收敛为 RDMA 独立集成、固定单 bank、Tcl 显式启动；尚未实现本文提出的接口。

配套案例见 [Intel 集成参考](../../rdma-intel-integration-reference.md)。本文讨论软件集成与代码简化；真实 DUT 的引脚、复位、链路就绪和业务验收由平台接入后验证。

## 1. 目标与依据

用户要求参考 **Virtio 当前正在修改的 integration/project**，复用 `dpu_common`、`pcie_work`、Intel PCIe 和 AIP，减少重复代码，保留清楚的职责和中文注释。最新范围是先完成 RDMA 独立集成，Notify 固定单 bank，参考 53 驱动；RDMA/VIO 共存留到后续，公共快照与资源归属现在就按可共用的边界设计。集成案例使用单独入口，不写进原有 filelist。

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

本设计的首个实现范围是外部快照接入、RDMA 公共资源需求/结果契约、共享内存/PCIe 绑定、AIP 入口和独立 RDMA project 案例。当前入口不依赖 VIO 包、不实现两类业务的统一 seq。表达式解析全面迁移、并发流量、无信号完成与旧 flow resolver 的全面迁移单列为后续优化，避免第一轮集成同时改变 WR 执行语义。

独立入口约定为 `integration/filelists/rdma_project.f`，由用户显式加入工程；本轮不得修改 `sim/filelists/rdma.f`、`pcie_work.f`、`tests.f` 或 `rxe.f` 来自动引入示例。当前案例说明位于 [integration/project](../../../integration/project/README.md)，对应新源码/filelist 尚未创建。

## 3. 唯一数据来源与生命周期

| 信息或资源 | 权威/所有者 | RDMA 使用方式 |
| --- | --- | --- |
| Host、PF/VF、BDF、BAR、global Function ID、服务资源 | `dpu_common` 的 authoring 与一次 resolver 结果 | 借用冻结的 device/resource snapshot，不重新声明拓扑或写回快照 |
| Host memory manager/pool | 用户环境；缺省创建也只在组装层进行一次 | `rdma_host_mem` 借用所属 Host manager，维护每个 Function 的分配账本 |
| RDMA CMQ/EQ/CQ/QP/MR、实际 backing IOVA | RDMA driver/resource 层 | 配置与网络路由导出实际结果，不用合成 handle/地址代替 |
| PCIe RC、tag、Completion、Intel VIF | `pcie_work`、`pcie_intel` 与平台 | RDMA 借用 sequencer/VIF，保持底层事务生命周期 |
| 网络 endpoint、真实 reset/readiness | 平台 | 显式绑定，缺失时拒绝进入业务 |

每个 Host 一份 manager、一个 RC slot、一个 Intel 端口；同 Host 的 PF/VF 共用端口。Host ID 不必等于 slot。`dpu_pcie_bar_map` 为配置 seq 和 RC driver 共享的同一对象，不在 PCIe 配置中重新分配 BAR。

### 编号与申请阶段

`global_function_id` 是 DPU 快照为 Function 统一生成的身份编号；`rdma_vf_id` 是 RDMA 硬件的 8 位 Function 字段。它们标识同一个 Function，当前纯 RDMA 方案采用显式约定 `rdma_vf_id = global_function_id`，不新增 RDMA ID 分配器或重复保存映射。参与 RDMA 的 global ID 必须小于 256，Notify、RNET、QPC/PD/EQ 必须统一使用该值；超范围在写表和 probe 前拒绝，不能截位。

例如一个 Function 的 global ID 为 37，则本方案的 RDMA ID 也是 37，Notify 表行号仍由地址排序决定，可以是 0。`rdma_vf_id` 中 VF 是历史叫法，也可对应 PF，不等于 PCIe VF index。53 上驱动使用独立 bitmap 说明硬件允许单独编号，不要求本项目照搬该分配方式。

VIO 的每 Function 32 对限制属于队列层：Function 内 pair index 为 0..31，再映射到设备级 `global_qpair_id`；两者都不是 `global_function_id`。未来加入 VIO 不自动要求拆开 Function 编号；只有 RDMA Function 的 global ID 超出 8 位、需要压紧 RDMA 编号或平台明确规定不同编号时，再由 DPU 扩展显式映射契约。

统一分配不等于把每次运行期创建都交给 DPU。正确阶段是：

```text
RDMA 提交资源需求；未来 VIO 提交自己的需求
  → DPU 统一校验、分配全局身份/共享额度
  → 发布同一组冻结 device/resource snapshot
  → 各业务消费自己的 binding
  → RDMA 在额度内创建对象，并从共享 Host manager 分配实际内存
```

PF/VF 的逻辑身份可以在 DPU authoring 中显式声明；AUTO/PINNED 策略仍由 DPU 验证和解析。RDMA 不自行增加 PF/VF，不重新编号；冻结后的快照是申请结果，不是可变分配器。

真实集成的 `rdma_env` 位于 `dpu_device_env` 子树，使 DPU build 先完成一次解析，再向 RDMA 提供快照。当前 `rdma_env.build_system()` 总会创建并解析自己的系统，因此仅调整 UVM 层级还不能完成集成。

需要在现有系统入口增加明确的外部快照绑定路径；以下是**待实现契约**，不是现有 API：

- 外部路径接收 device/resource snapshot 和已绑定的 Host manager，检查 Function/service 身份、完整映射和资源容量后创建 RDMA 投影；不调用 resolver，不创建本地 DUT 模型。
- 节点的 BAR 依赖收敛到已有 `rdma_drv_bar` 抽象，继续调用 `rdma_drv_hw.bind_hw()`。模型专用 `dev` 只在模型节点存在；probe、报告、链路和 reset 调用必须按职责分开，不能依靠空 `dev` 被偶然跳过。
- 独立模型/PEER 入口保留显式 authoring 与模型创建。测试专用默认值留在测试支撑中，仍供 PEER 使用的能力不能直接删除。
- 一旦某个 Function 存在活动队列，不允许重绑 snapshot、manager 或 BAR。新拓扑需要重建环境；外部对象的销毁仍由其所有者决定。

### DPU 当前接口的限制

`dpu_env_cfg.load_params()` 的默认 authoring 仍面向 VIO：Function 默认允许 `DPU_SERVICE_VIO_NET`，默认 placement profile 为 `virtio.qpair`。首次加载也会拒绝已经填好的非空拓扑。

因此 RDMA 参考工程应接收平台已经完成 authoring 的 `dpu_env_cfg`，通过现有 DPU 配置类型在 resolve 前显式声明 RDMA 服务与资源需求；不对该对象再次调用默认拓扑生成入口。参数读取可使用 AIP 宏，资源解析仍只在 DPU 执行一次。缺失 RDMA service 是构建错误，不能把 VIO service 当作 RDMA 使用。

进一步核对后，公共资源接口还有三个明确缺口：

- `dpu_service_decl` 可以声明 `DPU_SERVICE_RDMA`，但 `dpu_resource_placement_cfg` 的具体请求只有 `vio_requests`；声明一个 RDMA service 不等于已经申请到 RDMA 资源额度。Function ID 可直接取现有 device snapshot，经 8 位范围检查后作为 RDMA ID。
- `dpu_resource_snapshot`/`dpu_resource_manager` 当前主要导出 VIO qpair 租约，没有 RDMA 资源额度 binding，也没有可直接调用的运行期 RDMA `allocate()` 接口。
- `dpu_resource_manager.configure_from_snapshots()` 当前无条件查找 `virtio.qpair` profile；纯 RDMA 工程不能靠假造 VIO 服务或占用 VIO 队列来绕过它。
- `dpu_resource_snapshot` 的冻结校验也拒绝零 VIO qpair capacity。因此只跳过 manager 的 VIO profile 查询不足以让纯 RDMA 的共同快照链路可用；不能直接改 protected 冻结标志或假造非零容量绕过解析器。

需要扩展的是 DPU 的 RDMA 需求和冻结结果，而不是 RDMA 本地再造资源管理器。最小结果应包含完整 Function/service key，以及当前使用的中断、CEQ/SD 等共享范围和容量约束；不为当前恒等映射另设 RDMA ID 池。RDMA 负责按自己的格式计算需求，例如 HMC 所需 SD 数；DPU 负责统一批准和分配；实际 CMQ/EQ/QP/CQ/MR 与 DMA 页由 RDMA driver 管理。

这个资源额度契约目前尚未落地，本轮只在本项目记录设计，不修改外部依赖仓库。未来实现须补齐实际共享资源的契约后再消费结果；不能通过平台手填共享范围或 RDMA 私有分配器冒充 DPU 分配。直接消费 DPU 的 global ID 满足身份唯一来源要求，本身不依赖新增 RDMA ID API。

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

独立入口为 `rdma_project_cfg_seq extends dpu_cfg_seq`，只编排 RDMA 必需步骤。复用 `declare_af`、`configure_bdf_table`、`configure_rdma_notify`、`configure_qsch_rnet` 以及实际需要的 MSI-X 等公共类别。不能调用基类的 VIO 默认 body。

Notify 固定单 bank：不增加 bank 参数、不维护翻转状态、不使用旧驱动的 bank-select 位。根据实际 RDMA Function binding 和 Notify 地址排序生成有效项，完整预检后批量发送；空批次不能证明已配置好一个声明了需求的 RDMA 服务。

RDMA Notify 所需的 Function 身份、RDMA ID 与真实 BAR 窗口在 connect/publish 前已经确定；它不依赖后续 QP/CQ 分配。先完成 Notify、QSCH/RNET 等驱动访问的路由前提，再执行可能发送 CMQ 的 RDMA probe，随后准备实际 QP/CQ/MR。任一步失败停止开放业务，保留资源到平台确认 DMA 静止后清理；已发送配置不宣称可原子回滚。

`DPU_TABLE_RDMA_NOTIFY` 的记录目前来自显式 `frozen_controls`；8B entry 的 Host、RDMA Function ID 和地址字段须有真实来源。53 上 EMP 的 `dpu_af_insert_rdma_notify_tbl_entry()` 按 `{host_id, notify_addr[60:13]}` 排序，`dpu_af_alloc_rdma_vf_id()` 从独立的 256 项 bitmap 分配 RDMA ID。本项目复用其字段编码和排序，ID 则按上述约定取 DPU global ID，不取 Intel VF index 或 Notify 行号。

当前 RDMA `probe()` 已直接把 `global_id` 写到 `drv_cfg.vf_id`，这项赋值可以保留。独立集成需要补齐写表与 probe 的一致性预检：全部 RDMA Function 来自同一冻结快照，ID 唯一且小于 256，Notify、RNET、驱动 QPC/PD/EQ 使用同一值。缺少 Function/service 或资源结果时在 probe 前失败，不截断 global ID，也不按 RDMA 子集的遍历顺序重新编号。

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

project 在 elaboration 完成后提供 `dut_config`、`rdma_init`、`rdma_run`、`rdma_load_params` 和 `reg_acc`。`dut_config` 通过 `aip_cmd_user_seq` 注册本项目配置 seq；初始化、业务与参数入口使用 `aip_cmd_task`；寄存器入口复用五参数 `aip_cmd_reg`。不编写命令注册表或一组用户命令类。未来组合 VIO 时再由项目统一协调同名命令，本轮不引入跨业务命令协调层。

环境构建只完成参数读取、DPU 解析、组件创建、句柄绑定和命令注册；不得自动运行配置 seq、driver probe、创建业务资源或发流量。参考 base_test 只持有 objection 并运行 AIP Tcl bridge。平台 prepare 由显式 `dut_config` 触发，平台收尾由 Tcl 退出后的 test 执行；配置 seq 的调用、驱动启动和业务提交不能藏入 build/connect/run_phase。

`rdma_init` 只在 `dut_config` 完整成功且平台已就绪后允许执行；`rdma_run` 只在初始化成功后允许执行。反序命令立即报错，不等待另一个 Tcl 命令来解除阻塞。重复初始化、活动期间重配/重载和并发业务启动均拒绝；初始化失败后保持业务关闭，清理由平台确认 DMA 静止后处理。sequence、宏注册与可复制 Tcl 脚本一起发布到 `integration/project`。

重载采用局部候选值：先检查业务空闲/资源释放，再读取和完整验证，全部成功才写回同一配置对象。失败保持原配置；不隐含 reset、释放、写表或重新分配 BAR。task 明确填写 AIP `status/result_out`；`aip_cmd_user_seq` 本身不会检查任意自定义 `success` 字段。

命令入口可借用项目已有 virtual sequencer；参考包中的单一命令上下文仅服务 AIP 入口，不能成为 driver/router 的全局环境定位方式。首轮不增加后台并发配置框架，重入直接拒绝。

## 6. 启动、失败与平台边界

```text
build/connect：authoring → DPU 一次 resolve → 创建组件 → 绑定/发布句柄
elaboration：注册 AIP 命令；run_phase 进入 Tcl，保持未启动
Tcl dut_config：平台复位/接口就绪 → 公共配置 → 单 bank Notify → QSCH/RNET
Tcl rdma_init：driver probe → 实际资源准备 → 初始化成功
Tcl rdma_run：显式提交 RDMA 业务 → 返回提交/完成结果
Tcl end_test：排空、数据与协议检查、停止 DMA、释放资源
```

RDMA Notify/RNET 必须先于依赖这些路由的 CMQ 请求；实际 QP/CQ 创建后的网络投影再使用真实资源，不能拿合成 IOVA 提前填充。第一次实现须用调用顺序测试固定这两类依赖。

base_test 保留三个强制平台入口：`bind_platform_handles()` 绑定现有 VIF/内存/endpoint，`prepare_platform()` 由配置命令调用以执行真实 reset/readiness，`finish_platform()` 在 Tcl 退出后完成排空、数据/DMA/PCIe 检查与停机。后两者必须有完成判定和超时，不能用空 task 返回成功；从未启动的环境不应被当作已配置 DUT 收尾。

配置失败不进入业务，已发送的 posted write 不宣称可回滚；已分配内存保持到平台确认 DMA 静止后再释放。真实 reset 后使旧资源、事务和 route epoch 失效，不能调用本地设备模型的 `flr()` 代替硬件复位。已有 route/authority/epoch 检查属于必要边界，不能作为“精简”删除。

## 7. 代码简化清单与后续流量优化

RDMA 环境本轮需要补齐的能力应放回现有职责边界：

| 能力 | 落点与最小变化 |
| --- | --- |
| 消费外部快照与 RDMA binding | `rdma_env_cfg`/DPU adapter 接收同源快照；项目层提交需求，env 不再次 resolve |
| Tcl 显式启动 | 外部集成的 `run_phase()` 不执行 probe；配置、初始化和业务分别由 AIP 命令触发，既有独立模型测试保留原启动方式 |
| 真实硬件端口 | 复用 `rdma_drv_bar`/`rdma_drv_hw`，绑定 PCIe 与共享 Function 内存视图，不新造 driver 抽象 |
| 移除真实路径的模型依赖 | `node.dev.nic` 接包/错误报告留给模型路径，真实网络来自外部 endpoint；FLR 不能调用模型复位冒充硬件 |
| 配置、就绪和失败收尾 | 一条 RDMA 配置 seq；base_test 保留平台绑定、就绪、完成检查三个接口 |
| 独立示例 | `integration/project` + 新的 `integration/filelists/rdma_project.f`，不接入原有 filelist |

现有 QP/CQ/MR、资源库、scoreboard 和大部分 verb agent 应继续复用。还需注意 `rdma_drv_bitmap.init(max, start)` 的 `start` 只是轮转查找起点，因此 `first_qp` 当前不是受保护的全局租约起点；不能仅填入 DPU 返回的范围 base 就宣称实现了范围隔离。

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

实现按可审查的职责分批提交；每批同步调用者、package、独立集成入口、案例和测试，删除确已替代的生产实现。原有 filelist 不纳入集成案例；只转抄字段或同名转发的层不保留。

所有触及的源码从文件入口复审。类内 `extern`、类外实现；每个函数/task 紧邻具体中文“功能 / 输入输出及副作用 / 失败边界”；类型与变量间使用 Tab，复杂条件分行。测试辅助函数同样执行，避免借整文件格式化扩大无关 diff。

无需真实 RTL 即可验证的契约包括：

1. 两个 Host 使用相同 BDF 时仍按 Host 路由；缺 policy/slot、非零 segment、跨 BAR、未知 requester 被拒绝。
2. PCIe 与 RDMA 引用同一个 manager；跨 Function、释放后和旧 epoch DMA 被拒绝；双环境互不串线。
3. 公共表写与 8B 大端 doorbell 的地址/顺序/字节内容正确；Notify 空批次、表写失败和使能失败均有结果。
4. AIP task/sequence 只注册一次，错误不会成为 OK；重载失败无部分更新，活动资源不能重载，参数路径与每 WR 采样次数保持契约。
5. 原有单元、模型/PEER、PCIe 故障测试继续通过；真实路径无需构造模型 EP 或本地 DUT NIC。
6. 纯 RDMA 不要求 VIO 服务或伪造 qpair 资源；验证 RDMA ID 等于冻结 global Function ID，Notify 排序行号刻意取不同值；覆盖 global ID 255 可编码、256 被拒绝且不截断。单 bank 不产生翻转/选择写，新的集成 filelist 仅由显式入口编译。
7. 实际 Tcl 脚本验证空闲启动期间无 MMIO/CMQ/业务；反序命令立即失败；只调用 `dut_config` 时没有 driver probe；随后显式 `rdma_init`/`rdma_run` 才依次推进，失败状态经 AIP 返回。

为后续共存保留三项边界即可：一个 DPU allocator 和同源快照、按 service 标记的资源需求/结果、各业务独立管理实际内存与队列生命周期。混合 seq、共享 RC 的跨业务接收分派和同 Function 混合服务验证不属于当前验收。

全部编译与 VCS 仿真在 `ubuntu@10.11.10.53` 的登录 bash/已加载 `.bashrc` 环境执行，并记录依赖工作区版本。平台接线后的 reset、Intel 链路、CMQ/DMA/网络数据与错误恢复由用户接入验证，模型通过不能替代这些结果。

本文与配套案例目前仅完成源码接口核对和文档静态检查，未进行本轮 VCS 或 DUT 验证。
