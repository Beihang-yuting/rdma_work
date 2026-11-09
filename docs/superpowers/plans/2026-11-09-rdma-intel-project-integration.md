# RDMA Intel Tcl Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 按仓库分工，由 Astra 实施和复审，5.6 执行验证；不额外并行修改同一源码。

**Goal:** 提供可由 Tcl 显式配置、初始化和启动的 RDMA Intel 集成入口，复用 DPU 冻结身份、Host memory、PCIe 和 AIP，保持旧 filelist 独立。

**Architecture:** 用户配置直接组合 DPU、RDMA 和 PCIe 配置，环境只创建、绑定与发布。RDMA 外部路径消费同源冻结快照，`dut_config`、`rdma_init`、`rdma_run` 分别控制写表、驱动和业务。沿用现有 driver、资源库和 AIP 宏，不创建新的通用分配器、命令注册表或驱动框架。

**Tech Stack:** SystemVerilog/UVM、AIP Tcl/DPI、dpu_common、host_mem、pcie_work、Intel HARD_IP adapter；VCS 验证主机为 `ubuntu@10.11.10.53`。

**Spec:** [RDMA 共享配置与 Intel PCIe 集成设计](../specs/2026-11-09-rdma-intel-project-integration-design.md)。本文接口均为拟实现接口，不能据本文宣称源码已经具备这些能力。

## Global Constraints

- 先做 RDMA，固定单 bank，当前不实现 RDMA/VIO 混合 seq，不引入 VIO 编译依赖。
- `rdma_vf_id = global_function_id`；参与 RDMA 的 global ID 必须小于 256，不截断、不另建 ID 池。
- `dpu_common` 是 Host/PF/VF/BDF/BAR/global Function ID 的唯一权威；快照只读，不能在 RDMA 重建拓扑。
- 外部 Intel、Host manager 和网络 endpoint 均为非拥有引用；活动资源禁止重绑。
- 配置 seq、driver probe 和业务均由 Tcl 显式启动；集成 test 的 `run_phase()` 只持有 objection、运行 bridge 和收尾。
- 不修改 `sim/filelists/rdma.f`、`pcie_work.f`、`tests.f`、`rxe.f` 以引入示例；新入口为 `integration/filelists/rdma_project.f`。
- 新增/修改的每个函数与 task 都有紧邻的中文“功能 / 输入输出及副作用 / 失败边界”；类内 extern，类外实现，类型与变量间用 Tab。
- 普通源码、package、测试统一 `.sv`；不做无关整库格式化。
- 外部仓库包含未提交工作，本计划不覆盖或直接修改这些仓库。
- 所有 VCS 编译/仿真在 53 登录 bash 执行；真实 DUT 接线与验收由用户完成。

## 实施前的公共契约限制

当前 `dpu_common` 的 RDMA service 和 global Function ID 可用，但完整纯 RDMA 资源链路还不能直接运行：

1. `src/dpu_resource_snapshot.sv` 冻结校验拒绝零 VIO qpair capacity。
2. `src/dpu_resource_manager.sv::configure_from_snapshots()` 无条件要求 `virtio.qpair` profile。
3. `src/dpu_resource_snapshot.sv` 没有 RDMA 的 CEQ/SD 等共享范围结果；driver 的默认 `first_sd=0`、`first_ceqn=0` 只适用于已有隔离模型，不能当作真实多 Function 的授权分配。

这些不是 Intel 接线问题，也不能用虚构 VIO service、伪造 capacity、私设冻结标志或本地重新分配 ID 绕过。本仓库实现明确的外部快照/资源输入边界和能力检查；缺失共享资源结果时，在第一笔 MMIO/CMQ 前拒绝真实启动。公共资源扩展作为单独依赖变更处理，未具备前不得把完整纯 RDMA DUT 集成标为通过。命令生命周期、快照身份、BAR 字节序和错误路径可以先用隔离模型及受控 fixture 验证。

## 文件与职责

| 文件 | 最小职责 |
| --- | --- |
| `src/adapters/host_mem/rdma_host_mem_pkg.sv` | 借用已存在的 Host manager；保留每 Function 分配账本；消除重复 include 的类型问题 |
| `src/adapters/dpu/rdma_dpu_adapter_pkg.sv` | 增加外部快照节点投影，保留 global ID；驱动绑定和模型对象分离 |
| `src/tb/rdma_env_cfg.sv`、`rdma_env.sv` | 外部配置模式、显式初始化入口与 ready 查询；集成模式不自动 probe |
| `src/tb/rdma_ctrl_agent.sv`、`rdma_link.sv`、`rdma_dut_link.sv` | 清理真实路径对模型 NIC/FLR 的依赖；必要边界返回错误 |
| `src/adapters/pcie_work/rdma_pcie_work_pkg.sv` | 为外部 BAR/RC 绑定实例依赖；保留模型 EP 故障注入用途 |
| `integration/project/rdma_project_cfg.sv` | 三类配置直接组合，借用平台句柄，不包裹另一份全局配置 |
| `integration/project/rdma_project_env.sv` | 创建/绑定组件，发布同一 map、Host manager 和命令上下文 |
| `integration/project/rdma_project_cfg_seq.sv` | 单 bank 的 RDMA 配置编排，无 driver probe 和业务 |
| `integration/project/rdma_project_commands.sv` | AIP 现成宏注册及短 task 入口，统一返回 Tcl status/result |
| `integration/project/rdma_project_test.sv` | 平台接口、Tcl bridge 和结束检查；无自动配置/初始化 |
| `integration/project/rdma_project_pkg.sv` | 唯一 include 入口，命令宏仅编译一次 |
| `integration/project/rdma_start.tcl` | 可复制的显式命令顺序与每步状态检查，不自动 source |
| `integration/filelists/rdma_project.f` | 独立编译入口，不反向接入核心 package/filelist |
| `integration/project/tests/` | 快照、传输、命令顺序及 Tcl bridge 测试与独立 test filelist |

## Task 1：统一 Host memory 类型与外部绑定

**Consumes:** `host_mem_pkg::host_mem_manager`、现有 `rdma_host_mem` 分配账本。

**Produces:** `rdma_host_mems::bind_manager(int unsigned host, host_mem_api manager)` 返回 `rdma_status`；仅接受非空、Host 匹配的 manager。已为该 Host 创建视图后不得替换 manager；重复绑定同一句柄幂等成功。

- [ ] 阅读完整 Host memory adapter 及新旧 host_mem package 包含方式；以实际测试依赖版本确定唯一类型来源。
- [ ] 在 `integration/project/tests/rdma_shared_memory_test.sv` 建立一个真实 Host manager，绑定两份 Function 视图，验证共享 backing 与账本隔离。

```systemverilog
status = mems.bind_manager(0, manager);
if (!status.ok()) `uvm_fatal("SHARED_MEM", status.convert2string())
left = mems.make(0, "left");
right = mems.make(0, "right");
if (left.mem != manager || right.mem != manager)
    `uvm_fatal("SHARED_MEM", "Function views did not reuse the Host manager")
status = left.alloc(4096, 4096, address);
if (!status.ok()) `uvm_fatal("SHARED_MEM", status.convert2string())
status = right.read(address, 4, bytes);
if (status.code != RDMA_SC_DMA_TRANSLATION)
    `uvm_fatal("SHARED_MEM", "cross-Function read was accepted")
```

- [ ] 去掉 adapter 内重复的 `host_mem_manager.sv` include，使用外部包的唯一类型；保留独立模型测试的 manager 工厂。
- [ ] 加入绑定前/后失败测试：null、Host 错配、已经生成视图后替换 manager；确认失败不覆盖旧句柄。
- [ ] 在 53 编译新测试并运行现有 `rdma_env_basic_test`，复审文件全部方法注释；提交独立 Host memory 改动。

## Task 2：消费外部快照并显式初始化

**Consumes:** `dpu_device_snapshot`、同源 `dpu_resource_snapshot`、Task 1 的 Host manager。

**Produces:** `rdma_dpu_system::bind_snapshot(dpu_device_snapshot source, dpu_function_key_t keys[$])` 返回 `rdma_status`；`rdma_env::initialize(output rdma_status status)` 与纯查询 `rdma_env::is_ready()`。外部配置模式通过 `rdma_env_cfg.external_configuration` 选择。

- [ ] 在 `rdma_external_snapshot_test.sv` 使用 DPU resolver 生成冻结设备快照，选取含 RDMA service 的 Function，验证节点的快照句柄、key、global ID、BDF 和 BAR 均未重新生成。
- [ ] `bind_snapshot` 先检查全部 key/service、重复 key、global ID 范围和冻结状态，成功后一次性发布节点；外部节点不创建 `rdma_dev`、本地 router 或 interrupt controller。
- [ ] 外部节点借用已绑定的 `rdma_drv_hw`；真实初始化要求显式 driver 配置和可验证的共享资源来源，不采用模型默认共享范围。缺失资源契约返回具体 `INVALID_STATE`，且没有 MMIO。
- [ ] 将现有 probe/登记步骤移到 `initialize()`；集成模式的 `run_phase()` 不调用它。原模型入口保持既有行为，避免修改无关测试语义。

```systemverilog
// fixture 的 BAR 计数器只记录实际 write64；等待并不触发命令。
#1us;
if (env.is_ready() || bar.writes != 0)
    `uvm_fatal("MANUAL_START", "external environment started without a command")
```

- [ ] 覆盖 global ID 255、256、非 RDMA Function、不同源资源快照、重复初始化和部分 probe 失败；失败后 ready 保持 0，不能继续业务。
- [ ] 复审 ctrl/link/report 中所有 `node.dev` 使用：模型行为只用于模型节点；真实 FLR 由平台完成，未提供时明确拒绝，不调用模型复位代替。
- [ ] 53 运行外部快照测试和现有 env/netpkt 测试，复审涉及目录完整上下文后提交。

## Task 3：Intel BAR 与 DMA 使用同一映射

**Consumes:** 同源 `dpu_pcie_bar_map`、每 Host 的 RC sequencer、共享 Host manager 和 Function 内存视图。

**Produces:** 已有 `rdma_pcie_bar` 的实例绑定入口；外部 RC 接收路径借用 map/视图，不通过 `rdma_pcie_system::current` 定位真实环境。

- [ ] 在 `rdma_project_transport_test.sv` 对两个 Host 使用相同 requester/BDF，独立捕获 Intel 请求和 Completion，验证按 Host+requester 选中唯一 Function。
- [ ] BAR 写继续走现有 PCIe sequence；对 `64'h0123456789abcdef` 独立断言线上字节为 `01 23 45 67 89 ab cd ef`，不使用被测编码函数计算期望。
- [ ] 检查 8B 跨 BAR、地址溢出、缺失 sequencer/policy、旧 epoch 和跨 Function DMA：无效请求在访问共享 backing 前失败，不能默认路由 RC0。
- [ ] 集成 PCIe 配置固定 RC enabled、EP disabled、`ep_auto_response=0`，使用 `intel_pcie_configure_env()` 与 HARD_IP wrapper；模型 EP/故障注入路径仍供旧测试使用。
- [ ] 运行新传输测试及 `rdma_env_pcie_test`/`rdma_env_pcie_fault_test`；只在出现新失败时扩大回归。

## Task 4：独立 RDMA 配置 sequence

**Consumes:** `dpu_env_cfg` 已发布的快照/map；Function 对应实际 Notify 窗口地址；平台就绪接口。

**Produces:** `rdma_project_cfg_seq extends dpu_cfg_seq`，保存父类的 `success/error_msg`；只执行配置，不调用 `initialize()`。

- [ ] 新建 `rdma_project_cfg_seq.sv`，先验证选中 Function 的 RDMA service、8 位 global ID、Notify 地址可编码、全部表类别和资源来源。缺记录不能当作空批次成功。
- [ ] 按 `{host_id, notify_address[60:13]}` 排序，生成 8B Notify：`{5'b0, global_id[7:0], host_id[2:0], notify_address[60:13]}`；行号按排序位置生成。
- [ ] 使用现有 `declare_af`、公共表配置方法、`configure_rdma_notify` 和 `configure_qsch_rnet`；不调用 VIO 默认 `super.body()`。

```systemverilog
declare_af(ok, error_msg);
if (!completed_step("declare_af", ok)) return;
configure_bdf_table(public_scope, ok, error_msg);
if (!completed_step("configure_bdf_table", ok)) return;
configure_rdma_notify(rdma_scope, ok, error_msg);
if (!completed_step("configure_rdma_notify", ok)) return;
configure_qsch_rnet(rdma_scope, ok, error_msg);
if (!completed_step("configure_qsch_rnet", ok)) return;
```

- [ ] `rdma_project_config_test.sv` 独立检查排序、字段和 DWORD 写序；成功后管理 BAR `+0x80044=1`，不写旧 `+0x48`，无 bank 翻转；配置失败不触发 probe。
- [ ] 保留公共 sequence 的致命配置失败行为；所有正常返回的失败分支均向 `dut_config` 的 AIP handle 写非零 status/result，不让宏把空结果补成 OK。反序调用在发送任何事务前拒绝。
- [ ] 用传输 fixture 测试写入失败和缺表，确认后续类别与初始化计数不增加；提交配置 seq 与测试。

## Task 5：按 Virtio 样式注册 Tcl 命令

**Consumes:** Task 2 的显式初始化与 ready 查询、Task 4 的配置 seq、已有 `rdma_aip_cfg_loader` 和业务 sequence。

**Produces:** `rdma_project_commands.sv`、`rdma_project_test.sv` 和 `rdma_start.tcl`。命令上下文只借用 env/sequencer；driver/router 不反向使用此全局命令引用。

- [ ] 使用当前 `aip_core_set_param_expr` 的宏，注册一次以下入口：

```systemverilog
`aip_cmd_user_seq(dut_config, rdma_project_cfg_seq, project_rc_sqr)
`aip_cmd_task(rdma_init, project_rdma_init)
`aip_cmd_task(rdma_run, project_rdma_run)
`aip_cmd_task(rdma_load_params, project_rdma_load_params)
`aip_cmd_reg(reg_acc, dpu_bar_reg_seq, project_rc_sqr, seq.error_msg, seq.check_read_data)
```

- [ ] `project_rdma_init` 检查配置完整成功后才调用 `initialize()`；`project_rdma_run` 先检查 ready、已选业务和有效两端，再启动现有业务 sequence。单 Function 不自动绑定不存在的 `f1=1`；未提供对端时返回具体错误。
- [ ] 所有 task 从同名 AIP handle 获取参数并写 `status/result_out`；不另写参数解析器。参数重载先在候选配置中读取和校验，资源活动或候选非法时保持原对象不变。
- [ ] test 保留 `bind_platform_handles()`、`prepare_platform()`、`finish_platform()`，prepare 只由配置命令调用。`run_phase()` 仅 raise objection、`aip_tcl_bridge::run_loop()`、平台收尾、drop objection。
- [ ] 编写用户显式 source 的 Tcl 脚本，包含每步状态检查；脚本文件存在不等于仿真自动执行它。

```tcl
dut_config
if {[aip_check_status] != 0} { error [aip_read_result] }
rdma_init
if {[aip_check_status] != 0} { error [aip_read_result] }
rdma_run
if {[aip_check_status] != 0} { error [aip_read_result] }
end_test drain=100ns
run
```

- [ ] `rdma_project_commands.tcl` 先故意调用未配置的 `rdma_init` 和未初始化的 `rdma_run`，断言非零状态且 bridge 没有挂起；仅运行 `dut_config` 后检查 probe/业务计数仍为零，再显式初始化和提交业务。
- [ ] 实际 Tcl/DPI bridge 在 53 执行，不以直接调用 SV task 代替命令验证；覆盖重复注册、重复初始化、活动期间重载和错误传播。

## Task 6：发布独立案例并完成复审

**Consumes:** 前述项目类型和经验证的命令；当前依赖工作区的实际版本。

**Produces:** 可单独编译的 `integration/filelists/rdma_project.f`、项目 README、验证证据与准确能力边界。

- [ ] 新 filelist 依次编译 AIP/Host memory/DPU/PCIe/Intel、RDMA 核心与适配器、DPU PCIe 集成、project package；同一 package 不重复编译，不自动包含用户 top。
- [ ] 用独立 test filelist 加入受控顶层及测试包，不改旧生产 filelist；记录七个外部依赖的 commit 与实际未提交差异摘要。
- [ ] 确认静态检查只包含预期文件，链接/代码围栏有效；旧 filelist 对远程基线没有 diff。

```bash
git diff --check
git diff origin/feature/rdma-param-v1 -- sim/filelists
```

- [ ] 复审所有涉及目录的源码，逐项核对中文注释、extern/实现、所有权、错误、复位、启动顺序与格式；去掉被替代的真实路径转发层，保留仍使用的模型能力。
- [ ] 由 5.6 汇总 53 测试结果，Astra 处理失败并最终审查；必要修改之后只重跑受影响检查。
- [ ] README 区分已通过的软件/模型/Tcl 测试、公共 DPU 资源缺口和用户负责的真实 DUT 接入。公共资源缺口未解决时不宣称完整 Intel RDMA 初始化/业务通过。

## 计划复审结论

- 用户明确的 Tcl 启动要求覆盖 Task 2、4、5，配置 seq 不再隐式 probe。
- 统一 Function ID、单 bank、共享内存、Intel 传输、AIP 复用与独立 filelist 分别有对应实现和验证步骤。
- 吞吐优化、表达式解析全面替换和 RDMA/VIO 共存沿用设计中的后续范围，本计划不混入。
- 公共 DPU 资源契约缺口保留为真实前置条件；本计划没有把平台接线或测试 fixture 当作该契约已经存在。
- 当前仅完成计划与设计更新，以上实施复选框未勾选，尚无本轮功能实现。
