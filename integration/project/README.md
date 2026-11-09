# RDMA 独立集成案例入口

当前阶段为接口分析和设计案例，尚未创建可编译的 `.sv`/`.f`。详细调用片段见 [Intel 集成参考](../../docs/rdma-intel-integration-reference.md)，改造依据见 [设计文档](../../docs/superpowers/specs/2026-11-09-rdma-intel-project-integration-design.md)。

本轮固定单 bank，先实现 RDMA；配置 seq、driver 初始化和业务都通过 Tcl 显式启动。未来 VIO 共存沿用同一 DPU 快照和资源申请流程；本案例不引入 VIO 包，也不加入原有 `sim/filelists/*.f`。

## 具体场景

一个 Host，经一个 Intel HARD_IP wrapper 连接实际 DUT；管理 PF0 提供公共配置 BAR，一个由 DPU 声明和解析的 VF 承载 RDMA。PCIe 与 RDMA 共享该 Host 的唯一 memory manager。

选择 VF 是因为当前公共 RDMA Notify 校验只接受 VF owner，并不意味着驱动或硬件不支持 PF RDMA。PF 接入需要补齐对应公共契约，不能伪装 Function 类型。

用户 env_cfg 直接组合 `dpu_env_cfg`、`rdma_env_cfg` 和 `pcie_tl_env_config`。用户 env 负责组件创建和句柄连接，RDMA 使用已有 driver、资源库和业务 agent。

## 身份与资源

| 项目 | 产生方 | 消费方 |
| --- | --- | --- |
| Host/PF/VF、global Function ID、BDF、BAR | DPU authoring/resolver | RDMA、PCIe、以后接入的 VIO |
| 8 位 `rdma_vf_id` | 直接取冻结的 global Function ID，使用前检查小于 256 | Notify、RNET、RDMA driver 的 Function 字段 |
| RDMA 资源额度及必要共享范围 | RDMA 提交需求，DPU 统一批准和分配 | RDMA driver |
| 实际 QP/CQ/MR、CMQ/EQ/HMC backing | RDMA 在获批额度内创建；内存来自共享 manager | RDMA 业务、配置与检查器 |
| Notify 表行号 | 根据冻结 Host 身份和真实 Notify 地址排序 | 单 bank 写表 sequence |

当前约定 `rdma_vf_id = global_function_id`：例如 global ID 为 37，则 RDMA ID 同样为 37；表行号还可能是 0。数字不是平台默认值。`rdma_vf_id` 不等于 PCIe 的 VF index，名字中的 VF 可指 PF 或 VF 对应的 RDMA Function。VIO 的 32 对限制对应 Function 内 pair index 与全局 qpair 的映射，不要求本项目额外分配 Function ID。

申请全局身份/额度必须发生在冻结前，不能向冻结快照追加分配。DPU 当前支持 RDMA 服务声明和 global Function ID 查询，但尚未导出 RDMA 资源额度 binding；现有资源 manager 也不是运行期 RDMA 分配器。共享资源缺口需由公共契约补齐，不影响当前 ID 的直接复用，不能通过复用 VIO qpair 隐藏。

## RDMA 环境需要补齐的入口

1. 从 DPU 子树读取同源 device/resource snapshot，取得 RDMA binding，创建只读 Function 投影，不再 resolve 自己的拓扑。
2. 绑定外部 PCIe BAR 端口、共享 Function 内存视图和网络 endpoint；真实路径不创建模型 EP 或调用 `node.dev.nic`。
3. 提供配置完成后的显式 driver probe/资源准备入口。集成路径的 `run_phase()` 只等待命令，即使 Notify/RNET 已配好，也必须由 `rdma_init` 显式触发 probe。
4. Notify、RNET、QPC/PD/EQ 统一使用 DPU global Function ID；ID 超出 8 位、缺失资源 binding、不同快照或旧 epoch 在业务开始前拒绝。
5. `rdma_project_cfg_seq` 只组织公共配置，经 `aip_cmd_user_seq` 注册为 `dut_config`；初始化、业务和参数重载经 `aip_cmd_task` 注册，寄存器访问使用五参数 `aip_cmd_reg`。

不新增第二套资源库、driver 抽象、命令 registry 或通用服务管理器。`rdma_drv_bar`/`rdma_drv_hw`、现有资源对象和 verb agent 的通用能力继续复用。

## 独立编译与平台接入

拟新增源码只通过 `integration/filelists/rdma_project.f` 显式编译，包含本目录 cfg/env/config-seq/base-test/package；原有 filelist 和核心 package 不反向包含这些文件。当前没有放置引用不存在源码的占位 filelist。

预期运行顺序为：

```text
build/connect → 一次分配与冻结 → 共享 BAR map/Host manager → 注册 AIP 命令
run_phase → AIP Tcl bridge（不自动配置、不 probe、不发流量）
dut_config → 平台 reset/readiness → 公共配置 → 单 bank Notify → QSCH/RNET
rdma_init → driver probe 与实际资源准备
rdma_run → 显式业务与结果检查
end_test → 平台确认 DMA 静止 → 释放本代资源
```

平台实现 `bind_platform_handles()`、`prepare_platform()`、`finish_platform()`，分别处理真实接口、由配置命令触发的复位就绪、结果检查和停机；不提供空 task 冒充 DUT 已就绪。反序命令直接报错，不能等待下一条 Tcl 命令而卡住 bridge。软件编译/模型验证在 53 上执行，真实 DUT 接入验证由用户完成。
