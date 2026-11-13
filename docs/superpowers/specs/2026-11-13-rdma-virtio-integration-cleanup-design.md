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
| `project_env_cfg` | 创建子配置、加载参数、保存同一份业务选择；不发送 MMIO |
| `project_env` | 创建/连接 RDMA，复用原 VirtIO 的 pool、DPU、RC 和 VIO；不实现 BAR 访问或启动业务 |
| `dut_cfg_seq` | 借用项目 cfg 和已有 RC，预检后串行执行公共、RDMA、VIO 配置，返回配置结果 |
| `src/adapters/pcie` | 实现 `rdma_drv_bar` 到已有 `pcie_tl_reg_seq` 的转换，使用已有 BAR map 和 RC |
| `src/adapters/dpu` | 保存 RDMA 对冻结 DPU 资源的映射、catalog/编码和 hardware plan 生成逻辑 |
| `src/adapters/aip` | RDMA 参数与命令适配；复用现有 AIP 宏和取消机制 |
| `src/tb` | 保留实际初始化能力和流量生成逻辑；不把业务实现复制进集成示例 |

BAR adapter 命名为 `rdma_pcie_bar`，迁出 `project_env.sv`。`pcie_tl_reg_seq` 已支持 8B 访问；adapter 仅做接口转换、现有 map 的范围校验和状态转换，不重做拆包、BAR 分配、Host 路由或 Intel 发送逻辑。

DPU 是 Host/Function/BDF/BAR/全局编号的唯一权威。env 安装必要的绑定逻辑，使 DPU 冻结快照之后、RDMA 子环境 finalize 之前完成投影和授权绑定；该时序不能整体推迟到 connect。

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

VIO 开启示例还需沿用平台已有队列格式、Notify 和完成模式参数，表中仅展示选择业务的参数。

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

## 集成目录与去重

仅保留 `integration/virtio` 这一套 RDMA+VirtIO 接入参考及对应 filelist、Tcl 示例和测试入口。用户已有 VirtIO env/cfg 吸收 RDMA 增量，不能要求用户整体替换环境或引入本仓库专用 test。

- 合并三条项目配置 sequence，正式入口统一为 `dut_cfg_seq`，不留下旧名转发别名。
- 移走 BAR adapter、catalog/编码、hardware plan 等可复用实现；env 保留必要的创建/绑定调用。
- 独立 `integration/project` 的 env/cfg/test/commands 和脚本在有效实现及测试迁移后删除，移除对应 filelist 和现行文档引用。
- 配置、共享内存、失败路径等有价值测试迁往相应测试目录，不随旧示例直接删除。
- 不再维护 RDMA-only 的第二套项目组装和公共表流程。

原 VirtIO 的共享 pool、Intel 接线、VIO endpoint 等实现是用户环境已有能力，接入参考应明确展示 RDMA 增量，避免继续复制这些算法。原 `env.load_params` 和部分 cfg runtime 方法不是 virtual，原基础 test 还会自动配置；本轮通过用户已有 test/loader 的显式接入处理，不额外增加继承包装，也不承诺简单 `super` 调用即可完成扩展。

## 验收

- 复合 sequence 可在没有示例 test 和 AIP registry 的测试中接收项目 cfg 并启动。
- RDMA-only、VIO-only、混合、两者关闭四种组合按已冻结业务选择执行，公共配置一次，关闭业务无业务配置事务。
- 原对象身份、每 Host 共享内存、冻结 BAR/Function 路由及 pre-build 绑定时序保持正确。
- 保留 Notify 排序和 DWORD 写顺序、表范围/覆盖、MSI-X 尾项、异源拒绝、重载失败不提交等有效检查。
- PCIe adapter 通过原 `pcie_tl_reg_seq` 发 8B 写，校验越界/过期目标和失败状态转换。
- Tcl 参数入口、直接 SV 启动、初始化前重载及禁止改动固定拓扑的契约均有对应验证。
- 执行静态检查；所有 VCS 编译/仿真在 `ubuntu@10.11.10.53` 登录 bash 中运行。配置 fixture 通过不能替代真实 DUT 初始化、DMA 或网络收发验证。
