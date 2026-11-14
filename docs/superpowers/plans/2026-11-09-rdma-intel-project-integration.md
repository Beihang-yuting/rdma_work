# RDMA Intel Tcl 集成实施记录与发布计划

日期：2026-11-09。本记录包含已完成的实现、53验证与最终技术复审；工作区转交由控制方另行确认。原批准范围仍为RDMA优先、单bank、Tcl显式启动、统一场景、独立filelist。实现/复杂诊断/复审由Astra负责，VCS与日志验收由指定5.6验证者在53登录bash执行；同一源码只有一个活动实现者。

**设计：** [共享配置与Intel集成](../specs/2026-11-09-rdma-intel-project-integration-design.md)。**使用：** [Virtio 集成 README](../../../integration/virtio/README.md)、[接入参考](../../rdma-intel-integration-reference.md)。**证据：** [Virtio 验证记录](../../../integration/virtio/VALIDATION.md)。复选框只表示该项实际状态，不把源码存在等同验证通过。

## 全局约束

- DPU唯一生成Host/PF/VF/BDF/BAR/global Function ID，RDMA消费冻结同源结果，ID<256且直接复用，不另建ID池。
- 外部PCIe/Intel/Host memory/网络由平台拥有；RDMA借用并检查完整route、authority、reset epoch。
- 单bank、无VIO编译/混合sequence；grant缺口不以VIO fixture、手填范围或平台接线掩盖。
- load_params唯一注册于最终test/top，DPU/RDMA各读候选、全体校验后统一提交；可复用package无注册副作用。
- 第一次初始化尝试后拒绝reload/重试，没有释放回未初始化接口；pkt非默认仅netpkt软件路径支持。
- 不修改外部依赖及旧sim/filelists；不加通用wrapper/registry/runner框架或无关格式化。
- 每个函数/task紧邻具体中文功能/输入输出副作用/失败边界，类内extern，类外实现，类型与变量间Tab；静态工具精确标签使用斜线。

## Task1：共享Host memory（已完成）

历史实现记录如下。2026-11-10的pool对齐已用公共`host_mem_pool`替代私有`rdma_host_mems`工厂和`bind_manager`，当前接口及生命周期以[接入参考](../../rdma-intel-integration-reference.md)为准；下列旧测试结果保留为当时的验证记录。

- [x] 使用host_mem_pkg唯一manager类型，移除重复include。
- [x] `rdma_host_mems::bind_manager(host,manager)`拒绝null/Host错配，创建视图后禁止换manager，同句柄幂等。
- [x] Function各自分配账本覆盖完整区间检查；保留独立模型fallback工厂。
- [x] 独立rdma_shared_memory_test验证共享backing与跨Function读写/释放隔离。

产物：`src/adapters/host_mem/rdma_host_mem_pkg.sv` 与已迁移到 Virtio fixture 的共享内存测试。历史详细执行记录保留于任务ledger/reports，最终Task7修正精确注释标签。

## Task2：外部快照与显式初始化（已完成）

- [x] `rdma_dpu_system::bind_snapshot(source,keys)`一次发布同源节点，不resolve、不创建模型dev/router；2026-11-10起第三参数显式传入平台公共`pool`。
- [x] `bind_resources(value)`及`bind_external_hw(i,hw,cfg_arg)`验证来源/视图/生命周期，不伪造RDMA grant。
- [x] `rdma_env::initialize(status)`与`is_ready()`分离；external_configuration路径不隐式probe。
- [x] ID255/256、非RDMA/重复/未冻结/异源拒绝、无MMIO、模型成功/部分失败和重复初始化覆盖；Task5再次验证external snapshot。

当前真实初始化必因公共DPU缺RDMA QP/SD/CEQ/AEQ grant在MMIO前拒绝。这是验收边界，不是任务未实现的静默fallback。模型构建、PEER及真实网络endpoint各保留原职责。

## Task3：Intel BAR/DMA（功能完成，历史静态错误由Task7关闭）

- [x] 实例依赖替代static current，保留仍使用的模型RC/EP故障能力。
- [x] `rdma_project_transport_pkg`复用PCIe RC responder、共享map/Host manager与Function视图，完整预检后才接触backing。
- [x] 双Host同BDF/Requester、literal大端8字节、分片Completion、部分BE、越界/跨Function/旧epoch/reset覆盖；真实HARD_IP/APPLICATION wrapper fixture通过。
- [x] normal/fault PCIe回归通过；模型故障兼容修复保留精确请求/clone/tag代次检查，无外部依赖修改。
- [x] Task7当时分支diff-scoped检查 `--base 08d2f71` 返回0，无硬错误，仅202条软行宽提示；历史135硬注释/header错误已关闭，不可变审计保留。

产物：transport package/tests及现有Host/PCIe adapter。当前transport要求无限credit、无shaper/link delay，一次性绑定，无rearm。

## Task4：单bank配置sequence（已完成）

- [x] `rdma_project_cfg_seq extends dpu_cfg_seq`，config-only package保持不依赖RDMA/AIP/Intel。
- [x] 完整Function目录/service/ID/Notify窗口/表布局与全物理跨度预检，失败首MMIO前拒绝。
- [x] Notify按Host/地址排序、global ID字段不等于行号；成功管理BAR+0x80044使能，无旧+0x48或bank翻转。
- [x] 配置不probe；保留success/error_msg及公共fatal行为，CONTROL/FUNCTION未支持hook明确拒绝。
- [x]53上33-case PROJECT_CONFIG_PASS，W/E/F=0/0/0；当时任务静态退出0，旧filelist不变。
- [x] 最终I1修复f3e03b1补齐继承MSI-X尾项初始化/读回及完整跨度预检；53 fresh配置46-case PASS、W/E/F=0/0/0，专项复审通过。最终分支静态退出0、209条软行宽、0硬错误；早期33-case和202条软提示记录保留为历史快照。

合法VIO消息/资源只用于公共表mechanics，不能视为RDMA设备grant或VIO混合业务。

## Task5：单场景参数（已完成，commit9ff5bb8）

- [x] `rdma_scenario_types.sv`、`rdma_scenario_cfg.sv`、`rdma_traffic_vseq.sv`替代三份旧biz文件；cfg.scenario唯一来源。
- [x] qp/mem/pkt/traffic公开路径、RC/UD/URC映射、op/mix权重及消费者/测试/示例迁移，无旧转发别名。
- [x] 构建/candidate共用AIP读取；原文表达式与type关键字采用已批准的现有API例外，无自建parser。
- [x] 候选语义/溢出校验不抽WR；非法抽样一次失败不裁剪/重抽；每端资源只创建一次。
- [x] defaultSGE1、netpkt-only pkt覆盖及初始化尝试后的reload关闭写入参数文档。
- [x]13参数行、focused cfg/draw、affected env、10预期负例、external snapshot全部通过；RXE只编译，无live流量结论。

参数参考保留历史文件名 [rdma-biz-param-design.md](../../rdma-biz-param-design.md)，内容已为现行单场景API。

## Task6：项目事务和Tcl（已完成，commit3e08149）

- [x] `integration/virtio/project_env_cfg.sv` 直接借用 dpu/rdma/pcie/functions，`project_env.sv` 创建手动启动子环境。
- [x] load_params检查生命周期，DPU/RDMA各候选一次，全验证后原地apply；DPU只允许print_bar_map/verify_readback，PCIe固定。
- [x] 独立最终test声明context/sequencer后include test/commands；runtime package无注册副作用。
- [x] dut_config task先prepare再configure；rdma_init只允许完整配置后首次调用；rdma_run要求显式不同实际global IDs f0/f1。
- [x] 模型fixture通过已有protected build_system的virtual分派使用同源快照；默认实现体不变，无生产grant绕过。
- [x] Virtio commands/namespace manifests 与 `integration/virtio/tests/run.sh` 覆盖真实 Tcl/DPI、同 binary 的 restore；匹配 AIP dist 由验证者预建。
- [x] 当前已确认commands/prepare failure/partial probe failure为0/0/0；save成功后的restore验证10→override17→CLI20并真实20 WRITE完成。
- [x] absent32、namespace、duplicate/config-fatal预期负例及完整矩阵通过；fresh basic/external snapshot均0/0/0。第一次save超时不计通过，第二次成功save产生同binary恢复所用快照。

运行由验证者按README设置实际roots后执行：

```bash
bash integration/virtio/tests/run.sh
```

`integration/virtio/tests/restore.tcl` 带测试专有观测断言，是模型验收脚本；通用平台只复用恢复/source/load顺序，不直接依赖测试命令。

## Task7：发布完整入口（实现、验证与最终技术复审完成）

- [x] 发布 `integration/filelists/rdma_project.f`：AIP/Host/DPU/PCIe/Intel、RDMA、DPU PCIe、project类型依序编译，无重复package/top/注册。
- [x] `tests/project_intel.f`追加现有wrapper/control/test/top；`run_intel.sh`独立展开并显式top，不改旧runner/生产清单。
- [x] 保留无Intel runtime与config-only边界，README分列独立test及已有project接入。
- [x] 更新现行reference/spec/plan和单场景链接，记录七依赖完整commit/status/content hash与准确WIP摘要。
- [x] 对早期9个任务文件规范注释标签/header，保留既有业务逻辑，不放宽checker。
- [x] 完整Intel新composition在53编译/运行返回0，实际PROJECT_TRANSPORT_PASS及PROJECT_INTEL_TYPES_PASS，W/E/F=0/0/0；日志与状态更新前20文件快照manifest记录于VALIDATION。
- [x] 最终diff-scoped静态及whitespace返回0；7个Markdown围栏与41个相对链接通过；相对3e08149旧filelist及既有边界清单字节不变。
- [x] Task7范围独立复审SPEC PASS / QUALITY Approved，独立执行门禁通过；Task6/7实际证据已填写。
- [x] 全分支上下文及最终技术复审完成；唯一I1已修复并经专项复审Approved/ADDRESSED，0新增发现。实现/验证/技术复审门禁关闭；实际工作区转交由控制方交付记录确认。

```bash
bash integration/virtio/tests/run.sh
python3 tools/check_changed_sv_style.py --base 08d2f71
git diff --check 08d2f71
git diff origin/feature/rdma-param-v1 -- sim/filelists
```

实现者不运行上述检查/仿真或操作staging；验证者使用最终稳定源码。主工作区同步由控制方处理，保留四份已批准文档变更及无关output/、sshpass_placeholder/内容。

## 保留限制与后续

真实DUT、平台网络endpoint、reset/readiness及安全收尾需用户平台实现，公共RDMA grant独立缺失。当前一个 `rdma_env` 已按冻结 snapshot 支持任意数量 Function、多个 `flow_groups` 和每条边的多 QP；独立队列深度/CQ共享、吞吐专项优化、表达式引擎全面替换和 flow resolver 全面迁移仍留后续。RDMA/VIO 共存的资源权威已经按共享 snapshot/host_mem_pool 设计，但混合业务仍由后续项目分别装配。软件fixture通过不代表真实DUT能力已完成。
