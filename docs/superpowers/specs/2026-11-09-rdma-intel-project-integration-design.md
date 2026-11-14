# RDMA 共享配置与 Intel PCIe 集成设计

日期：2026-11-09。状态：Tasks1–7及最终I1修复已完成，批准范围内的53验证门禁与最终技术复审通过；I1修复提交f3e03b1。当前可执行入口已收敛到 `integration/virtio`，`integration/project` 仅保留可复用类型。此文记录设计约束，通过范围以 [Virtio 验证记录](../../../integration/virtio/VALIDATION.md) 为准，不再把已删除的独立 fixture 名称当成当前 API。

[接入参考](../../rdma-intel-integration-reference.md) 给出实际编译/调用方式，[Virtio README](../../../integration/virtio/README.md) 区分结构 fixture 与真实平台。真实DUT接线、复位、网络和业务验收由平台负责；DPU RDMA grant缺口仍独立存在。

## 目标、版本与方案

目标是参考Virtio当前project的直接组合方式，复用DPU、Host memory、PCIe、Intel和AIP，先完成RDMA独立集成，Notify固定单bank，配置、初始化和业务都由Tcl显式启动。RDMA/VIO共存只保留架构边界，本轮无VIO编译依赖或混合sequence。

RDMA同步基线为 `6ab999b3b7f9f188f3c3ba7f17b6e046f9c93973`，开发基于 `feature/rdma-param-v1`。外部依赖包含当前DPU/PCIe WIP，实际依赖摘要记录于 [Virtio dependencies.tsv](../../../integration/virtio/dependencies.tsv)；旧设计阅读时的短hash不作为复现输入。本轮不修改外部仓库。

采用直接组合已有配置和收敛现有适配器。当前 `integration/virtio/project_env_cfg` 持有 `dpu`、`rdma`、`pcie` 及完整 `functions` 目录，用户自己的cfg可直接持有相同类型，不要求继承。RDMA 维持一个 env，内部以动态 Function 节点和 `flow_groups[$]` 管理跨 Host/PF/VF 的业务边；项目只创建/绑定/发布组件及统一提交参数候选，继续复用driver/resource/verb agent。没有复制Virtio表包装层、重写driver或引入通用registry/allocator。

VIO 按 Host 拆分 env 是因为每个 Host 的 ring、IOMMU、worker 和 Host 级配置彼此独立；RDMA 的 CMQ、QP、link、scoreboard 和资源状态需要在 Function 之间统一观察，因此不按 Function 或 Host 复制 env。只有两个 DUT 使用完全独立的 snapshot、PCIe 路由或 reset 生命周期时，才创建两个 RDMA env；同一快照下的多 Host/PF/VF 都留在一个 env 内。

## 唯一权威与生命周期

| 数据/资源 | 权威与所有者 | RDMA实际行为 |
| --- | --- | --- |
| Host/PF/VF/BDF/BAR/global Function ID | DPU authoring及一次resolver的冻结结果 | `bind_snapshot`检查完整选取目录，创建只读节点投影，不再次resolve |
| 资源授权 | 同源DPU resource snapshot | `bind_resources`只验证来源；缺RDMA grant拒绝初始化，不把VIO租约换名使用 |
| Host pool与每Host manager | 平台持有公共`host_mem_pool`；独立模型也复用该类型 | `bind_snapshot(source,keys,pool)`借用同一pool；Function视图各自记账，发布后不换pool/manager |
| 实际CMQ/EQ/QP/CQ/MR及backing | RDMA现有driver/resource层 | 在合法授权内管理；真实范围契约缺失时不使用模型默认值 |
| PCIe RC、tag、Completion、Intel VIF | PCIe/Intel与平台 | 非拥有引用，遵守原事务生命周期 |
| 网络endpoint、reset/readiness | 平台 | 显式绑定；不调用本地NIC/FLR冒充真实硬件 |

`global_function_id` 与 `rdma_vf_id` 均必须小于256；简单平台可以让两者相等，但 Notify、RNET、QPC/PD/EQ 使用 grant 发布的 RDMA VF ID，HID_MAP/RPE 仍保留 global Function ID 的权威映射。Notify行号由地址排序产生；Intel VF index、VIO Function内pair index/global qpair ID 都不是这两个 ID。两者不允许由 RDMA 侧自行推导或截位。

外部 `rdma_env_cfg.external_configuration` 绑定平台 `external_system`；系统先一次绑定device snapshot和公共pool，再绑定同源resources及显式hw/driver cfg。2026-11-10起移除私有Host工厂与PCIe重复manager表，平台按冻结GPA创建pool成员，RDMA只校验并借用；DPU通过`host_mem_pool_ref`发布同一pool。外部节点不创建rdma_dev/router/interrupt模型。初始化一旦尝试就锁定绑定，失败也不能替换快照/BAR/pool/manager；新拓扑需要新的环境生命周期。独立模型/PEER的authoring与模型能力保留。

公共资源的当前限制：placement只有VIO具体请求，snapshot/manager仍有VIO qpair capacity及virtio.qpair profile前提，没有RDMA QP/SD/CEQ/AEQ grant。不能伪造VIO服务/capacity、改冻结标志或手填共享范围绕过。`rdma_drv_bitmap.init(max,start)`的start只是轮转起点，first_qp不是受保护租约起点。外部初始化检查在第一笔MMIO/CMQ前返回INVALID_STATE；表配置和平台接线都不消除该缺口。

## Intel传输与共享内存

每Host一个端口/RC slot，同Host PF/VF共享端口；Host ID不等于slot。DPU同源BAR map同时服务MMIO sideband和DMA Requester路由。当前支持segment0、PF0..7、VF0..2047，PF vf_index=-1；不从global ID截位推导policy。完整Function policy/sequencer必须在绑定前齐全。

`rdma_project_rc_driver`继承PCIe RC responder，永久安装无分配权的guarded host_mem_api适配器；借用Function视图，不创建第二份backing或第二条应答线程。每次DMA先用ingress Host+Requester建立上下文、验证完整单次分配范围，再由原responder分片；每片读写和Completion发送重查authority/reset epoch。`rdma_project_pcie_bar`复用已有8字节大端sequence，公共表仍按DWORD原顺序，不交换字节序。

真实配置为RC启用、模型EP关闭、ep_auto_response=0，HARD_IP wrapper。初始复位/readiness后一次性bind_transport/bind_project，实际driver要求无限credit、无shaper/link delay，避免授权检查到enqueue之间产生等待。FLR/teardown前显式revoke；reset epoch改变使旧绑定永久失效，无rearm。已发出的字节不承诺回滚，平台确认DMA静止后才释放分配。

原 `rdma_pcie_system` 的模型RC/EP、故障注入仍用于回归；当前实例引用替代static current。模型timeout退休按Root+Requester/tag、精确请求/scoreboard克隆指纹和tag代次检查，保留隔离tag及迟到Completion防护；不把TLM对象身份用于Intel wire。

## 单bank公共配置

`rdma_project_cfg_seq extends dpu_cfg_seq`，所在 `rdma_project_pkg` 仅依赖DPU/PCIe配置类型。先验证完整RDMA目录、PF/VF owner、ID8位、同源map、表布局/对齐/跨类别物理跨度无重叠，再执行AF、公共类别、Notify和QSCH/RNET；不调用VIO默认body，不probe。

Notify地址来自冻结BAR+真实窗口偏移，按 `{host_id, notify_address[60:13]}` 排序，8B内容为 `{5'b0, global_id[7:0], host_id[2:0], notify_address[60:13]}`。重复key/ID、容量>256和不可编码地址在首写前拒绝。成功后每个不同管理BAR `+0x80044=1`；无旧 `+0x48`、bank翻转或全表重写。

非空MSI-X先写有效行，再复用继承的 `process_msix_tail(0, ...)` 初始化全部未用行，之后调用enable_msix；可选读回包含 `process_msix_tail(1, ...)`，成功后才进入Notify/RNET。完整bank的容量/溢出/BAR/直接访问/对齐和逐尾行8B的4KB边界，以及尾部与其他表/握手的物理冲突均在AF前预检；有效行不与自身bank误报重叠。无消息不访问MSI-X。最终46-case配置fixture与I1专项复审通过，table-only使能无MMIO的观察边界保持明确。

非空CONTROL/FUNCTION catalog需要未实现公共hooks，当前显式拒绝；table-only策略按现有契约。保留success/error_msg及父类fatal post_start，配置失败关闭业务，posted写无原子回滚承诺。合法VIO消息fixture只证明公共表机制；RDMA grant与driver ready仍独立。RDMA catalog 接受 dpu_common 已声明 RDMA service 的 PF/VF，Function kind 不由 RDMA 侧重新解释。

驱动来源、字段编码与硬件版本差异保留在 [接入参考](../../rdma-intel-integration-reference.md)；不因采用旧EMP排序算法而恢复其双bank/ready地址。

## 单场景参数与原子重载

`rdma_env_cfg.scenario`唯一拥有qp/mem/pkt/traffic；`rdma_env_cfg.flow_groups` 保存 global Function ID 对和 `qp_count`，`rdma_traffic_vseq` 在一个 env 内按边创建共享 PD/buffer/MR 与独立 CQ/QP。旧六模板、rdma.biz路径及env中重复QP参数已删除，无转发别名。实际参数、默认值与限制见 [单场景参数](../../rdma-biz-param-design.md)。

RC支持send/send_imm/write/write_imm/read/cas/faa，UD仅send/send_imm，URC为RC+urc仅send/write/write_imm；RECV自动配套。默认SGE从旧随机范围变成1；显式表达式不改写，非法WR抽样报路径/范围、不裁剪或重抽。原子len8/SGE1不抽表达式，远端SGE1不抽SGE，其他分支保留原求值次数。候选校验不提前抽WR。SQ/RQ/CQ共用depth请求，驱动取合法最小值和2幂；URC内部CQ fragment不代表重复场景资源。

pkt的VLAN/IP/UDP目前只在netpkt软件codec生效；DUT或其他link非默认pkt在分配/发送前拒绝，不把route snapshot编码能力当场景硬件配置。

构建与运行期候选复用AIP读取逻辑。普通标量用宏；type关键字用现有get_single_value命名入口，len/sge/data_mode用现有原文override/CLI查询保留分布和空值，未自建parser。完整override > leaf override > 完整CLI > leaf CLI > 默认值。AIP非法语法/类型转换仍hard fatal，语义错误返回status。

最终project唯一load_params：先检查生命周期，再DPU/RDMA各读取一次候选，全部验证后无等待地原地apply；任一失败都不部分提交。身份、cfg/scenario/map/pool/manager句柄不变，无MMIO/分配/WR采样，成功清configured。DPU仅print_bar_map/verify_readback有当前消费者；PCIe固定。固定RDMA mode/link/vseq/checker/cov缺键沿用活动值，显式改变拒绝；可变场景/时间字段使用新构造默认值，不复用checkpoint旧CLI。

重载窗口在第一次初始化尝试结束前就关闭，失败/空闲同样拒绝。没有释放回未初始化API或traffic-only热改。已有project沿用自己的唯一registry，接入候选步骤；可复用package不注册公共命令，不增加scope/dispatcher/自动扫描。

## 显式启动、恢复与失败

```text
平台authoring/一次resolve → 冻结snapshot → build/connect发布共享句柄
最终test注册唯一AIP入口 → run_phase只运行bridge
restore（可选）→ 下一行重新source匹配AIP loader
load_params → dut_config（prepare + 表配置）→ rdma_init
rdma_run f0=<真实global ID> f1=<真实global ID> → end_test → 平台安全收尾
```

`rdma_project_runtime_pkg`包含env_cfg/env；最终test compilation unit自行声明project_context/project_rc_sqr并include test和commands。dut_config用task先prepare再configure，不能直接注册sequence而跳过平台准备。默认prepare失败；实际平台提供reset/readiness完成/超时判定及一次binding。finish由平台确认DMA静止并撤销/清理，空默认hook不是DUT验收。

反序命令不等待后续Tcl，返回具体status/result_out；重复初始化、活动重入和无效peer拒绝。initialize先锁定尝试标志；部分失败保持业务关闭。取消不自动清busy恢复重入，硬件已提交事务不回滚。

checkpoint在未配置/未初始化时保存，同一binary跨独立进程restore，顶层aip_restore后紧邻source，之后再定义proc/显式load。快照override仍高于新CLI，clear后使用新值；缺键回退规则要独立覆盖。当前rdma_restore.tcl是带测试观测的模型验收脚本，通用平台按接入参考采用同一顺序。

## 编译、验收与后续范围

`integration/filelists/rdma_project.f`按实际依赖包含完整Intel类型，无wrapper/test/top/注册。独立project_intel.f仅追加既有wire fixture；runtime.f保留无Intel边界，config.f保持config-only。commands/namespace是完整各自最终入口，不与类型清单叠加。旧sim/filelists不自动纳入示例。

53上的验证必须分清：共享内存/外部快照、Intel真实引脚fixture、公共表模型、场景回归、真实Tcl桥/跨进程恢复；完整Intel类型发布另有实际compile/run门禁。Task6检查真实WRITE成功post/SQ completion12或20，不能以混合scoreboard.checked替代WR计数。最终依赖/源码manifest和通过状态见验证记录；历史Task3注释硬错误更正保留，不以软提示掩盖。

源码复审涵盖文件头、中文设计依据、逐函数/task具体三段契约、extern/实现、所有权、错误/复位与格式；精确标签为功能：、输入/输出及副作用：、失败/边界：。任务范围清理不放宽checker、不做无关全仓格式整理。

一个 RDMA env 当前已经支持任意数量的 dpu_common Function（受冻结 snapshot、硬件能力、单 bank 容量和 8 位 global Function ID 限制），并通过 `flow_groups[$]` 顺序承载多条业务边；每条边支持多个对称 QP。独立 SQ/RQ/CQ 深度、CQ 共享、吞吐专项优化、完整表达式引擎替换和 flow resolver 全面迁移仍留后续，现有通用模型能力仍有消费者不能整文件删除。后续驱动回收窗口受 SQ/buffer slot/可观测完成共同约束，不移植 Virtio 协议专属功能或跳过 RDMA doorbell 影子握手。RDMA/VIO 共存继续向 DPU 统一申请授权，各业务负责实际 ring/QP 等生命周期；若两类业务同时运行，仍应各自消费同一冻结 snapshot 和 host_mem_pool。
