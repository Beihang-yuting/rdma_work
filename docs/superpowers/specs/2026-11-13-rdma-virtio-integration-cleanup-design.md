# VirtIO/RDMA 集成收敛与 dut_cfg_seq

日期：2026-11-13。状态：根据已讨论方向整理，待书面设计审阅；尚未修改生产实现。
实现基线：`fd5fef0`。本文描述拟整理后的接口，不表示当前代码已经完成迁移。

## 目标与范围

在原有 VirtIO 项目环境中接入 RDMA，保留一套组合集成参考。用户可以将配置、连接和独立配置 sequence 吸收进自己的项目，不需要继承本仓库的 test，也不需要同时接入独立 RDMA 项目示例。

- `project_env_cfg` 创建并持有已有 DPU、PCIe、VIO、RDMA 配置，统一加载参数。
- `project_env` 负责组件声明、创建、配置发布和连接；具体访问转换放在 adapter。
- 对外只保留一个复合配置入口 `dut_cfg_seq`，替代冗长的 `project_dut_config_seq` 名称和中间分派包装。
- RDMA、VIO 可按参数分别启用，也可一起启用；公共配置只有一个执行者。
- Tcl 使用已有 AIP 参数和命令能力，配置与流量由用户显式触发。

本轮不修改外部依赖仓库，不新增通用项目框架或另一套 PCIe transport。RDMA 核心模型和业务 sequence 仍保留各自测试能力；删除范围是多余的集成示例和转发层。

## 职责归属

| 内容 | 整理后的职责 |
| --- | --- |
| `project_env_cfg` | 创建子配置、加载参数，唯一准备并发布业务选择和 RDMA grant；不发送 MMIO |
| `project_env` | 创建/连接 RDMA，复用原 VirtIO 的 pool、DPU、RC 和 VIO；不实现 BAR 访问或启动业务 |
| `dut_cfg_seq` | 借用项目 cfg 和已有 RC，预检后串行执行公共、RDMA、VIO 配置，返回配置结果 |
| `src/adapters/pcie` | 实现 `rdma_drv_bar` 到已有 `pcie_tl_reg_seq` 的转换，使用已有 BAR map 和 RC |
| `src/adapters/dpu` | 保存 RDMA 对冻结 DPU 资源的映射、catalog/编码和 hardware plan 生成逻辑 |
| `src/adapters/aip` | RDMA 参数与命令适配；复用现有 AIP 宏和取消机制 |
| `src/tb` | 保留实际初始化能力和流量生成逻辑；不把业务实现复制进集成示例 |

BAR adapter 命名为 `rdma_pcie_bar`，迁出 `project_env.sv`。`pcie_tl_reg_seq` 已支持 8B 访问；adapter 仅做接口转换、现有 map 的范围校验和状态转换，不重做拆包、BAR 分配、Host 路由或 Intel 发送逻辑。

DPU 是 Host/Function/BDF/BAR/全局编号的唯一权威。env 安装必要的绑定逻辑，使 DPU 冻结快照之后、RDMA 子环境 finalize 之前完成投影和授权绑定；该时序不能整体推迟到 connect。

## 授权来源与装配顺序

合法配置不能因为示例装配遗漏，在配置或初始化时才报缺 grant。使用现有 cfg、grant 和 system 完成以下顺序：

1. cfg 加载业务选择和每 Function 的资源需求，声明 DPU service；共享 Host pool 由已有环境准备。
2. DPU 冻结 device/resource snapshot 后，由 cfg 唯一准备授权：已有显式 grant 先验证，否则按已采样需求生成。
3. env 在 RDMA finalize 前，按完整 Function key 匹配投影与 grant，并将同一结果绑定到 system/driver cfg。
4. connect 使用同源 BAR map、RC、Host memory 完成 hardware 和 catalog 连接，结束前检查完整装配；失败指出阶段、Function 和缺失字段。
5. 配置与初始化入口继续检查来源、覆盖和容量，不在缺项时临时生成另一份 grant。

显式 grant 允许乱序，不能要求它与 Function 数组按下标对应；缺项、重复或身份不符仍拒绝。
显式 grant 保持只读授权边界，自动 `rdma.resource` 容量声明不改写它；对同一 Function 明确声明的容量与显式授权冲突时拒绝。
自动与显式 grant 使用同一完整预检，覆盖 RDMA 内部 SD/CEQ/source/vector 冲突及 DPU 已占用的 VIO、AF、mailbox 全局向量和实际容量。
向量检查沿用当前 DPU 冻结资源及已有前缀适配契约，不另设分配权威；属于同份 RDMA 授权的消息按身份匹配。

cfg 拥有准备结果，system、driver、catalog 和 plan 只读借用其授权；发布后调用方不得修改或替换 grant。
在现有绑定、配置和初始化边界检查 cfg/system 的 Function 覆盖、授权对应关系及 snapshot/resource/map 同源。
不增加 grant 管理器、版本状态机或私有冻结记录，也不为调用方直接篡改公开字段建立新防护框架。

## dut_cfg_seq 输入与接入

`dut_cfg_seq` 是复合配置 sequence，复用 `vio_dpu_cfg_seq` 及其公共配置流程。它提供一个 `project_env_cfg` 类型的 `project_cfg` 输入句柄，不重新创建、复制或加载项目配置。

接入规则：

1. 调用方可以直接设置 `seq.project_cfg = cfg`，然后在已有管理 RC 上 `start`。
2. 未直接设置时，可以从启动 RC 的 `project_cfg` config_db 键取得同一类型的对象。
3. 显式输入和 RC 发布对象同时存在时必须一致；`project_cfg.dpu_cfg` 必须与 RC 的 `dpu_cfg` 相同。
4. VIO 队列准备继续通过原有 RC 发布的 `vio_env_hN` 句柄完成。cfg 提供参数，实际 env 负责 ring 生命周期。
5. sequence 不依赖示例 env/test 类、AIP registry 或全局 Tcl target；结果沿用 `success/error_msg`。

为允许用户使用自己的同名配置类，`dut_cfg_seq.sv` 可以在用户 package 的 `project_env_cfg` 定义之后包含。所需底层包在此前导入；示例 package 只是一种接法。不同 package 的同名 cfg 并非同一类型，config_db 的 set/get 必须使用同一个具体类型，不能混用示例版本和用户版本。

## 参数与业务选择

沿用现有 `rdma.enabled`、`vio.enabled`、`vio.pairs` 和各业务参数，不再增加一套 mode 字符串、重复开关或参数解析器。

未提供更细粒度覆盖或手工 RDMA Function/grant 时，常规组合如下：

| 启动参数 | 实际配置分支 |
| --- | --- |
| `+rdma.enabled=1 +vio.enabled=0` | 公共配置与 RDMA |
| `+rdma.enabled=0 +vio.enabled=1 +vio.pairs=1` | 公共配置与 VIO |
| `+rdma.enabled=1 +vio.enabled=1 +vio.pairs=1` | 公共配置、RDMA 与 VIO |
| `+rdma.enabled=0 +vio.enabled=0` | 仅按 DPU 开关执行公共配置 |

VIO 沿用原有全局、Host、Function/service 参数覆盖规则；enabled、pairs 和 TX/RX 条件共同形成有效服务。sequence 查询冻结 `resource_snapshot` 的 VIO bindings，不再次读取 CLI，不另存一份 VIO 总开关。RDMA 使用已经加载并校验的 `project_cfg.rdma_enabled` 及其 Function/grant；现有显式 Function/grant 自动启用规则不在此次整理中改变。

这些业务和资源声明在 build 时形成并冻结。运行期 `load_params` 继续只重载允许变化的参数，不能借此改变 Host/Function、业务拓扑、VIO 队列数量或 grant。切换上述环境组合需要重新构建环境；流量参数仍按原重载窗口处理。

固定参数变更必须明确拒绝，不能返回成功却继续使用旧 grant。利用已有 AIP 参数来源/存在性与首次加载记录识别变更；不能为了检查而重新随机采样固定参数。允许重载的候选仍在完整预检后原子提交。

VIO 开启示例还需沿用平台已有队列格式、Notify 和完成模式参数，表中仅展示选择业务的参数。

### Function、flow group 与资源参数

拟新增以下两个 AIP 集合入口，目前尚未实现；复用 `aip_struct_queue_apply`，不另写集合解析器：

| 集合 | 元素与读取方式 |
| --- | --- |
| `rdma.functions` | `dpu_function_key_t`；复用已经注册的 schema |
| `rdma.flow_groups` | `rdma_flow_group_t`；补充 `f0_global_id`、`f1_global_id`、`qp_count` 三字段 schema |

集合沿用 AIP 的“SV 初值 → 参数覆盖 → 最终一份 cfg”：未提供参数时保留 SV 配置，提供时按已有集合语义应用。
参数仅由 cfg 解析一次，不增加 CLI/SV 双重声明拒绝或专用来源仲裁机制。
RDMA 启用而 `rdma.functions` 显式为空时拒绝；没有 Function 选择时，沿用显式 grants 的 keys，否则选择已有 DPU Functions。
flow group 的端点使用 global Function ID，必须属于实际选中的 RDMA Functions，且两端不同、`qp_count > 0`。
`rdma.flow_groups.size=0` 表示没有默认流量组，此时 run 必须明确指定端点；不影响单独执行配置。

资源参数沿用 `rdma.resource` → `rdma.hN.resource` → 精确 Function 的覆盖顺序。
PF 路径为 `rdma.hN.pfP.resource`，VF 路径为 `rdma.hN.pfP.vfV.resource`；PF 覆盖不自动继承给 VF。
资源参数由 cfg 首次加载时采样一次，授权生成消费该结果，不在多个 sequence 中重复读取。

## 配置执行顺序

1. 验证输入句柄、冻结快照、资源、目标以及已有 VIO generation。RDMA 开启时，在首笔 MMIO 前完成 RDMA 预检。
2. 通过父类现有流程执行一次 AF/公共表/BDF/MSI-X 配置及所选读回，遵循 `dpu_cfg` 的开关。
3. 在父类队列准备扩展点执行启用的 RDMA hardware plan、Notify/RNET 配置，然后调用原 VIO 队列准备。
4. 父类完成 VIO 表、队列使能和确认。冻结 VIO bindings 为空时沿用空 selection 路径。
5. 全部步骤成功才返回成功；失败停止后续步骤，保留原诊断，不宣称已发写入可回滚。

不再通过另一条 RDMA sequence 对象执行预检，不再由三条项目 sequence 反复转交 Function/grant。纯配置生成放到 adapter，执行检查及写表编排留在唯一配置 sequence，底层访问复用现有方法。

统一后，RDMA-only 也遵循父类公共配置开关；这是对旧独立 RDMA 路径只执行 AF/BDF/MSI-X 的收敛，不能宣称两条旧路径的事务逐笔不变。业务必需条件仍由预检约束：RDMA 开启但 `configure_bdf=0` 时继续拒绝，不能跳过必需表后宣称成功。

本轮 `dut_cfg_seq` 的成功仍表示配置成功，不自动改成 RDMA 驱动初始化或流量完成。RDMA probe/管理资源初始化继续由显式运行入口调用已有初始化能力；无需保留只为转调一个 task 而存在的独立 sequence。业务发流量继续使用既有 traffic sequence。若后续要求把驱动初始化并入配置入口，应单独明确其输入和完成语义。

Tcl 命令层管理一次配置执行的上下文及结果；参数成功重载后清除旧配置完成状态，重载失败保留原状态。配置 sequence 本身不维护另一套 AIP busy/configured 状态。调用层依据实际环境检查 RDMA 初始化是否已开始、是否有活动配置命令；直接 SV 调用者也承担相同责任。平台负责 reset/readiness、活动业务停机和最终收尾。

## 启动与发包参数

整理后的两种启动方式共用实际能力：

- Tcl：`dut_config` → `rdma_init` → `rdma_run`。
- 直接 SV：`dut_cfg_seq` → 现有 `rdma_env.initialize()` task → `rdma_traffic_vseq`。

调用层管理顺序和门禁：配置 sequence 成功表示表配置完成，`ready` 表示初始化成功，run 完成还须确认业务结果和 scoreboard 排空。
删除纯转发类时保留实际初始化、业务执行、取消登记和结果检查，不新增总启动 sequence；取消不等于撤销 DMA 或释放资源。
`set_param` 只修改参数来源，须显式 `load_params` 才应用；该重载只允许初始化从未开始的窗口，本轮不新增初始化后重载。

复用已有参数入口，不另造发包配置层：

| 常用路径 | 控制内容 |
| --- | --- |
| `rdma.qp.type/depth/mtu/max_sge` | QP 类型、队列深度、MTU、SGE 上限 |
| `rdma.mem.buf_bytes/slot_bytes/slots/mr_offset` | 缓冲、槽和 MR；权限继续使用 `rdma.mem.mr_remote_*` |
| `rdma.traffic.op/count/dir/signaled_pct` | 操作、每个 group 的消息数、方向及完成信号比例 |
| `rdma.traffic.len/sge/data_mode` | 逐 WR 的长度、SGE 数及数据模式；混合操作沿用 `rdma.traffic.w_*` |

`count` 不是每 QP 数量，也不包含为完成回收补发的消息；原子操作长度固定 8B，原子/远端路径沿用单 SGE 约束。
`data_mode` 可选 RANDOM/FIXED/INCREMENT/PATTERN，但 FIXED 的具体值和 PATTERN 内容目前仍随机生成。
MAC、UDP 目的端口、具体 payload、IMM 值及原子操作数尚无对应参数入口，不承诺任意报文字段均可设置。
`rdma.pkt.*` 的非默认值在默认 external driver 路径会被拒绝；模型 netpkt 可使用这些属性，但不能替代真实 DUT 写表。
外部路径须按真实 driver/平台能力预检，修改 `link_type` 不能视为已接通网络或已配置硬件报文属性。

当前组合参考没有连接真实 ETH 对端/环回或网络观察口；配置 fixture 通过不是收发闭环验证。
平台提供网络连接、DUT DMA/Completion 和必要观察，env 保持创建/连接职责；ETH 对端及观察组件的生命周期由平台管理。

## 多 QP 运行与生命周期

运行入口显式选择 group 或端点时优先使用该选择，两者互斥；仅在没有显式选择时使用 cfg 的 flow groups。
不为组合流程保留只做同名转发的 sequence；实际流量创建与执行继续使用既有 traffic sequence。

每次 run 在创建任何业务资源前，按本次选中的 groups 汇总各 Function 的需求：

- QP、CQ 需求各为该 Function 参与的 groups 的 `qp_count` 之和。
- PD、MR 需求各为该 Function 参与的 group 数。
- PBL 和 Host memory 需求复用既有 driver 的布局/页数计算，按实际 buffer、MR 和队列参数求得。

将需求与实际剩余资源比较，包含此前 run 的占用；不能只比较 grant 总额度。
已知不足时不创建本次业务资源，诊断指出 Function、资源、需求与剩余量。
实际 DMA 分配仍可能失败，保留真实错误与已分配状态，不承诺回滚或用默认容量掩盖不足。
默认 `rdma.resource.qp_count=64` 包含保留 QP0/1，最多只有 62 个用户 QP；DPU 支持的拓扑规模也不等于当前 MSI-X 容量能够承载的业务规模。

初始化一旦开始，当前 external 环境不可再次初始化或重载参数；失败也不解除该限制。
当前真实 external reset/recover 没有平台契约，继续明确拒绝，不能复用模型 FLR 来宣称支持真实 DUT 恢复。
拓扑与固定资源改配须重新构建环境；本轮不扩展复位恢复机制。

## 集成目录与去重

仅保留 `integration/virtio` 这一套 RDMA+VirtIO 接入参考及对应 filelist、Tcl 示例和测试入口。用户已有 VirtIO env/cfg 吸收 RDMA 增量，不能要求用户整体替换环境或引入本仓库专用 test。

- 合并三条项目配置 sequence，正式入口统一为 `dut_cfg_seq`，不留下旧名转发别名。
- 移走 BAR adapter、catalog/编码、hardware plan 等可复用实现；env 保留必要的创建/绑定调用。
- 独立 `integration/project` 的 env/cfg/test/commands 和脚本在有效实现及测试迁移后删除，移除对应 filelist 和现行文档引用。
- 配置、共享内存、失败路径等有价值测试迁往相应测试目录，不随旧示例直接删除。
- 不再维护 RDMA-only 的第二套项目组装和公共表流程。

原 VirtIO 的共享 pool、Intel 接线、VIO endpoint 等实现是用户环境已有能力，接入参考应明确展示 RDMA 增量，避免继续复制这些算法。原 `env.load_params` 和部分 cfg runtime 方法不是 virtual，原基础 test 还会自动配置；本轮通过用户已有 test/loader 的显式接入处理，不额外增加继承包装，也不承诺简单 `super` 调用即可完成扩展。

## 验收

| 场景 | 必须确认的结果 |
| --- | --- |
| 自动/显式授权与装配顺序 | 正常配置无缺 grant；显式 grants 乱序按 key 匹配；缺项在装配检查定位；RDMA finalize 前完成投影与授权绑定 |
| 多 Host/PF/VF 与集合入口 | SV 初值与 CLI 覆盖得到唯一 cfg，启用时空选择拒绝；逐 Function 资源覆盖及显式授权冲突检查正确；共享 pool、BAR/RC 和授权同源，显式授权侵占公共向量或容量不足均拒绝 |
| 多 QP、跨 group、重复 run | 显式 `rdma_run` group/端点选择不被 cfg 全部 groups 覆盖；按实际选择汇总剩余额度，覆盖恰好满足和不足；已知不足无本次业务资源创建，保留实际分配失败结果 |
| 固定参数与生命周期 | 固定字段改配拒绝且不重新随机采样；合法重载原子提交、失败不提交；初始化后 reload 与 external recover 明确拒绝 |
| RDMA-only/VIO-only/混合 | Tcl 和直接 SV 接入均可，后者不依赖示例 test/AIP registry；公共流程一次，关闭业务无业务配置事务；另验两者关闭仅执行公共配置 |

保留 Notify 排序与 DWORD 写序、表范围/覆盖、MSI-X 尾项及异源拒绝检查。
PCIe adapter 验证原 `pcie_tl_reg_seq` 的 8B 写、越界/过期目标和失败状态转换。
执行静态检查；所有 VCS 编译/仿真在 `ubuntu@10.11.10.53` 登录 bash 中运行。
配置 fixture 通过不能替代真实 DUT 初始化、DMA 或网络收发验证。
