# RDMA 独立集成入口

需要在 **virtio_work 的 project_env/project_env_cfg 上加入 RDMA** 时，使用
[组合环境示例 ../virtio](../virtio/README.md)；它直接继承原 virtio 类型并保留两类业务。
本目录继续提供独立 RDMA 入口、公共配置 sequence 和已有回归 fixture。

本目录提供冻结快照接入、Intel BAR/DMA 传输、单 bank 配置 sequence 和显式 Tcl 生命周期。软件/模型与 Intel wire fixture 的验证范围见 [验证记录](VALIDATION.md)，平台实际接线见 [接入参考](../../docs/rdma-intel-integration-reference.md)。**公共 DPU 的 RDMA QP/SD/CEQ/AEQ grant 契约仍缺失，当前不能宣称完整 Intel RDMA 初始化或真实 DUT 业务通过。**

## 编译边界

| 入口 | 内容 | 不包含 |
| --- | --- | --- |
| [rdma_project.f](../filelists/rdma_project.f) | AIP、Host memory、DPU、PCIe、Intel、RDMA 核心/适配器、DPU PCIe、transport/config/runtime 类型 | wrapper 实例、test/top、命令注册 |
| [rdma_project_runtime.f](../filelists/rdma_project_runtime.f) | 模型/Tcl 所需核心和 config/runtime 类型 | Intel、test/top、命令注册 |
| [tests/config.f](tests/config.f) | 独立公共表 sequence fixture | RDMA model/driver、AIP、Intel、VIO |
| [tests/project_intel.f](tests/project_intel.f) | 在完整类型入口之后加入 Intel wrapper 和既有双 Host wire fixture | 重复依赖、Tcl 注册、真实 DUT |
| [tests/commands.f](tests/commands.f)、[tests/namespace.f](tests/namespace.f) | 各自完整的模型/Tcl 最终编译单元 | Intel、VIO |

从仓库根展开 `@*_ROOT@` 为实际依赖绝对路径。完整入口和 runtime 入口二选一，不同时编译；commands/namespace 已各自包含依赖，也不要再叠加类型清单。`rdma_project_pkg` 只含配置 sequence；`rdma_project_runtime_pkg` 才含 `rdma_project_env_cfg`/`rdma_project_env`。旧 `sim/filelists` 保持独立。

独立最终 test package 声明 `project_context` 和 `project_rc_sqr`，显式 include `rdma_project_test.sv`、`rdma_project_commands.sv`，再加入平台或模型子类。可复用包不 include 这两个文件。已有 project 直接组合自己的 DPU/RDMA/PCIe 配置，复用 env/sequence 与候选 API，并沿用已有 test/命令 registry；不用继承参考 cfg，也不重复注册 `load_params`。

## 53 上的独立验证

由验证者在 `ubuntu@10.11.10.53` 登录 bash 中设置 `RDMA_ROOT`、`AIP_CORE_ROOT`、`HOST_MEM_ROOT`、`DPU_COMMON_ROOT`、`PCIE_WORK_ROOT`、`NET_PACKET_ROOT`；完整 Intel 入口另需 `PCIE_INTEL_ROOT`。所有根指向 [验证记录](VALIDATION.md) 对应的实际 staging，DPU/PCIe 包含记录的 WIP。

```bash
cd "$RDMA_ROOT"
# 完整类型入口 + 既有Intel wire fixture；编译/运行日志留在RDMA_INTEL_RUN。
bash integration/project/tests/run_intel.sh
# 单独的模型/Tcl矩阵；要求同一AIP checkout预建匹配的dist loader/.so。
bash integration/project/tests/run_commands.sh
```

`RDMA_INTEL_RUN` 默认 `output/validation/task7_intel`，`RDMA_RUN` 默认 `output/validation/task6`；两者应使用不同绝对目录。脚本不构建外部依赖。Intel fixture 使用真实 HARD_IP/APPLICATION wrapper 与引脚传输，没有用户 DUT；commands runner 验证真实 Tcl/DPI bridge 和同 binary 的跨进程 checkpoint，数据面为受控模型。最终通过状态以验证记录为准。

## 数据来源与平台生命周期

`rdma_project_env_cfg` 直接借用 `dpu`、`rdma`、`pcie`，`functions` 是完整 RDMA Function 目录。DPU 唯一负责 Host/PF/VF、BDF、BAR 和 global Function ID；RDMA 不重新 resolve 外部拓扑。`rdma_vf_id = global_function_id < 256`，不是 Intel VF index，也不是 Notify 排序后的行号。

平台只维护一个公共 `host_mem_pool`，按冻结 GPA 创建每 Host 的 manager，并通过 `dpu.host_mem_pool_ref` 发布。RDMA 用 `bind_snapshot(source, keys, pool)` 借用该 pool，PCIe 用 `pool.get_host(host_id)` 取得同一 manager；已有 Virtio pool 直接复用。缺 Host、未初始化、Host ID 或 GPA 覆盖不符时拒绝绑定，不建私有 fallback。各 Function 仅保留独立分配账本；完整 DMA 区间必须属于该 Function 的一次存活分配。不同 Host 的 GPA 可重叠，backing 各自独立。

VIO 可以按 Host 使用多个 env，因为 ring、IOMMU 和 worker 是 Host 私有状态；RDMA 保持一个 env，在其中登记所有选定 Function，再用 `flow_groups[$]` 描述业务边。这样多个 Host/PF/VF 共用同一 snapshot、pool、PCIe 路由、链路和 scoreboard；只有独立 DUT/snapshot 才需要新的 RDMA env。

Intel RC 与 BAR 共用同源 `dpu_pcie_bar_map`，以 ingress Host + Requester 路由，禁止缺项落到 RC0。初始复位/readiness 完成后一次绑定 generation/reset epoch；撤销、FLR 或链路复位后旧绑定永久失效，无 rearm。

真实平台须实现 `bind_platform_handles()`、`prepare_platform()`、`finish_platform()`；默认 prepare 明确失败。平台创建接口、PCIe 环境、Host pool 与网络 endpoint，生命周期覆盖所有借用者；结束前确认 DMA 静止再撤销和释放。单 Host/PF0 管理 BAR + VF RDMA 是平台接入参考；验证 fixture 的两个 Host 或两个 VF 不代表替用户生成拓扑。公共 Notify 目录接受 dpu_common 已声明 RDMA service 的 PF 或 VF，不能伪造 Function key 接入未发布的 Function。

```text
平台authoring/一次resolve → 冻结device/resource快照 → 发布共享map/host_mem_pool
build/connect → 唯一注册命令 → run_phase仅运行AIP bridge
load_params → dut_config(prepare + 公共表/Notify/QSCH/RNET)
rdma_init → rdma_run f0=<实际global ID> f1=<实际global ID>
end_test → 平台finish确认静止/撤销/清理
```

非空 MSI-X 配置复用父类尾项任务：有效行写入后、使能前初始化全部未用行；启用读回时验证完整尾部。完整 bank 的容量、溢出、BAR、对齐、4KB边界及尾部与表/握手的冲突在 AF/MMIO 前预检；无消息路径不访问 MSI-X。配置成功仍不代表 RDMA grant 或 driver ready。

## 参数与显式命令

`cfg.scenario` 是唯一场景来源；`rdma_traffic_vseq` 每端创建一组 PD/CQ/QP/buffer/MR，单操作与兼容混合操作共用。公开路径为 `rdma.qp.*`、`rdma.mem.*`、`rdma.pkt.*`、`rdma.traffic.*`；旧六模板及 `rdma.biz.*` 已移除。默认 RC/send、SGE=1，操作/默认值/抽样约束见 [单场景参数](../../docs/rdma-biz-param-design.md)。

| 命令 | 实际职责 |
| --- | --- |
| `load_params` | 唯一项目事务：DPU/RDMA 各读一次候选，全部验证后原地提交；不写表、不初始化、不抽 WR |
| `dut_config` | 调用平台 prepare，再显式运行配置 sequence；不 probe，不分配业务资源 |
| `rdma_init` | 完整配置成功后首次初始化 driver 与设备级资源；失败尝试也关闭重载窗口 |
| `rdma_run f0=1 f1=2` | 显式选择两个真实 global ID，运行场景；1/2仅为模型 fixture 的VF ID |
| `reg_acc` | 复用 `dpu_bar_reg_seq` 和当前管理 RC，保持公共 DWORD 契约 |

完整 override > leaf override > 完整 plusarg > leaf plusarg > 默认值。`set_param` 只改 AIP 表；显式 `load_params` 才应用。当前 DPU 可重载范围仅 `print_bar_map`、`verify_readback`；PCIe 和冻结身份保持构建值。RDMA 固定 mode/link/vseq/checker/cov 的缺省沿用已建值，显式改变拒绝；可重载场景/时间字段使用新默认值，不拿 checkpoint 旧 CLI 值当默认。

重载只允许初始化前且无活动 driver/资源；第一次初始化尝试之后，包括失败或空闲时，都拒绝。没有“释放到未初始化”API或 traffic-only 热改。失败候选不部分提交，成功保留 cfg/scenario/map/pool/manager 身份，并清除 configured，要求再次显式配置。非法 AIP 语法/类型转换仍继承 hard fatal；普通语义失败返回非零状态。取消不会自动恢复安全重入状态。

独立启动可在匹配 AIP loader 后 source [rdma_start.tcl](rdma_start.tcl)，按平台改实际 f0/f1。命令行值只提供配置，不会自动启动：

```text
simv +rdma.qp.type=RC +rdma.traffic.op=write +rdma.traffic.count=100
```

恢复需使用同一 binary，在未配置/未初始化时保存；`aip_restore` 顶层下一行立即重新 source AIP，再显式 load。快照 override 仍优先于新进程 CLI。已发布的 [rdma_restore.tcl](rdma_restore.tcl) 是带 `project_observe` 断言的**模型验收脚本**，不是用户平台通用脚本；通用调用顺序见接入参考。

## 尚未具备的外部能力

DPU 当前可声明 RDMA service/统一身份，但 resource snapshot/manager 仍有 VIO qpair capacity/profile 前提，且没有 RDMA QP/SD/CEQ/AEQ grant。合法 VIO 资源 fixture 只证明公共表路由机制；不表示 grant 已解决，也没有编译 VIO 包或实现混合业务。

场景 VLAN/IP/UDP 参数目前只在 netpkt 软件 codec 生效；DUT 或其他链路的非默认 pkt 在资源分配/发送前拒绝。一个 `rdma_env` 可承载多个 Host/PF/VF Function；`rdma_run f0=<id> f1=<id> qps=<n>` 运行任意一条业务边，`rdma_run group=<index>` 运行 `cfg.rdma.flow_groups` 中的边，多个 group 可顺序复用同一 env、snapshot、host_mem_pool 和 PCIe 路由。完整 DUT 还需要真实硬件、网络端点、reset/readiness、驱动资源授权和平台收尾验证；不同 QP 的独立深度/CQ 共享仍未提供。
