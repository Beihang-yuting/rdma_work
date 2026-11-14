# RDMA Intel 项目接入参考

本文对应实际实现；入口与验证命令见 [Virtio 集成 README](../integration/virtio/README.md)，版本/结果见 [验证记录](../integration/virtio/VALIDATION.md)，设计约束见 [设计](superpowers/specs/2026-11-09-rdma-intel-project-integration-design.md)。当前为软件集成和受控 fixture，尚无完整真实 DUT 验收。使用 `integration/virtio/project_env_cfg` 时，QP/SD/CEQ/AEQ 与路由 grant 已按 DPU 快照和 `rdma.resource.*` 自动生成；独立底层适配器仍接收显式 grant。参见 [自动 grant 参数](../integration/virtio/README.md#自动-grant-与启动参数)。

## 配置与类型组合

`integration/virtio/project_env_cfg` 直接保存 `dpu_env_cfg dpu`、`rdma_env_cfg rdma` 和 `functions[$]`。PCIe 环境及 RC sequencer 由平台 project env 持有，RDMA 只借用通过 BAR map 发布的管理 RC；参考 project 不复制一份 PCIe 配置。用户也可在自己的 cfg 直接组合相同类型，不要求继承参考类或增加公共包装对象。

| 文件 | 实际职责 |
| --- | --- |
| `integration/project/rdma_project_cfg_seq.sv` | `rdma_project_cfg_seq extends dpu_cfg_seq`，单 bank 公共表编排 |
| `integration/project/rdma_project_pkg.sv` | 仅配置 sequence 的包入口 |
| `integration/project/rdma_runtime_seq.sv` | 独立可复用的 RDMA 初始化/运行 sequence |
| `integration/project/rdma_aip_pkg.sv` | 项目命令参数解析与 runtime sequence 编排类型 |
| `integration/filelists/rdma_virtio.f` | Virtio/RDMA 组合类型入口；环境、Tcl 和 test 由 `integration/virtio` 持有 |

完整项目类型编译顺序为 AIP → Host memory → DPU resource → PCIe TL/interface → Intel interface/adapter → RDMA 核心/适配器/env/AIP → DPU PCIe → project config/runtime。普通 `.sv` 被 package include 后不能单独再编译。RDMA 基础包不编译 PCIe transport；项目 integration filelist 只引入 `pcie_tl_vip` 原生类型，不编译 `pcie_dpu_integration_pkg` 或 RDMA 自有 PCIe system/driver。AIP 使用 expression-capable checkout，不同时编译旧 aip_core 包；net_packet 沿用 RDMA adapter 的 include 方式。

真实 Intel fixture 不属于基础 RDMA 包；后续项目应在自己的 project env 中复用 virtio_work 的 Intel RC bridge、wrapper 和 `dpu_common` BAR map。模型/Tcl 使用独立 runtime 边界；config-only 测试不因此引入 RDMA/AIP/Intel。

## 权威身份、共享内存与真实传输

平台在 DPU authoring 中声明 Host/PF/VF、服务和资源请求，经一次 resolver 发布同源 device/resource snapshot、BAR map。RDMA 外部路径选择 `external_configuration`，绑定已有 `external_system`，由其 `bind_resources()` 借用同源资源快照；`bind_snapshot` 创建只读节点投影，不再次 resolve，不创建设备模型。一个 `rdma_env` 统一管理所有选定 Function，grant 分别携带 `global_function_id` 和 `rdma_vf_id`，两者都必须满足硬件位宽；Notify 行号、Intel VF index、VIO local/global qpair ID 都不是 RDMA VF ID。

平台统一持有 `host_mem_pkg::host_mem_pool`，通过 `dpu.host_mem_pool_ref` 发布真实 pool 句柄。`rdma_dpu_system::bind_snapshot(source, keys, pool)` 借用同一个 pool，先检查全部选中 Function 的 Host manager 已初始化、Host ID 正确且覆盖冻结 GPA，再一次发布节点；缺项直接拒绝，不创建私有 backing。RDMA Function 视图只在公共 manager 上保留自己的分配账本，PCIe 继续直接使用同一 pool。

平台按冻结快照的 `list_hosts()`/`lookup_host()` 建立 pool；对尚不存在的 Host 调用 `create_host(host_id, gpa_base, gpa_limit - 1, MODE_BUDDY, 16)`，其中 DPU 的 `gpa_limit` 为开区间终点，pool 的末地址为闭区间。已由 Virtio/project 建立的 pool 直接复用，不重复初始化 manager。以下片段放在平台装配阶段，`keys`、`host_id`、`rc_slot` 均来自现有映射：

```systemverilog
host_mem_pool pool;
rdma_status status;
string why;

if (!$cast(pool, dpu.host_mem_pool_ref) || pool == null)
  `uvm_fatal("RDMA_PROJECT", "platform host_mem_pool is required")
status = system.bind_snapshot(dpu.device_snapshot, keys, pool);
if (!status.ok())
  `uvm_fatal("RDMA_PROJECT", status.convert2string())
if (!pcie_cfg.bind_host_memory(rc_slot, host_id, pool.get_host(host_id), why))
  `uvm_fatal("RDMA_PROJECT", why)
```

同 Host 的 RDMA/PCIe 消费同一 manager，不同 Host 可以使用数值相同的 GPA，backing 仍然隔离。`rdma_host_mem` 仅保留各 Function 的分配账本和 DMA 范围检查；完整区间必须属于本 Function 的一次存活分配。独立模型的 `build()` 同样使用公共 pool，范围来自模型 authoring 冻结后的 GPA。pool 和 manager 必须覆盖所有借用者及未释放分配；发布后不能替换，`load_params` 与 AIP restore 保持其身份。

每 Host 一个 Intel 端口/RC slot，同 Host PF/VF 共用；Host ID 不必等于 slot。平台创建 `pcie_tl_env` 前调用 virtio_work 项目环境已有的 Intel 配置流程；真实 DUT 路径开启 RC，关闭模型 EP/ep_auto_response，wrapper 使用 HARD_IP。RDMA 只把公共 BAR/Function 选择交给该 bridge，公共表仍按现有 DWORD 顺序写。

DPU map 必须包含所有 Function 的显式 Intel policy 和实际 sequencer。支持每 Host segment0、PF0..7、VF0..2047，PF 的 vf_index=-1；BDF、Requester ID 和 Intel PF/VF sideband 分别消费真实映射。不存在的 Host/Function、缺 policy、跨 BAR/溢出、未知 Requester 或旧 epoch 都拒绝，不回退 RC0。Function 数量由 dpu_common 能力、Host/Function 表和 Notify bank 容量约束，RDMA 代码不固定为两端。

平台负责在 `prepare_platform` 完成初始 reset/readiness 后绑定 RC bridge 和 BAR map；RDMA 不保存第二份 route、epoch 或 Host responder。FLR/link teardown 的撤销和复位代次由项目环境及 `dpu_common` contract 管理，平台须确认 DMA 静止后释放业务分配。

## 公共表、驱动与 grant 的边界

`rdma_project_cfg_seq` 验证完整 RDMA Function 目录、同源 snapshot/map、PF/VF Function owner、8位 ID、表布局/对齐/全物理跨度不重叠及实际 Notify 窗口。Notify 按 `{host_id, address[60:13]}` 排序，行号与 global ID 分离，固定单 bank；成功后每个管理 BAR `+0x80044=1`，不写旧 `+0x48`。先 AF/公共表，再 Notify/QSCH/RNET；不调用基类 VIO 默认 body，不 probe。

非空 MSI-X 路径在有效表配置后、`enable_msix()` 前调用继承的 `process_msix_tail(0, ...)`，将单 bank 全部未用行设为非 reserved 字段全1、reserved 字段全0；`verify_readback` 时以 `process_msix_tail(1, ...)` 验证尾部，失败立即停止 Notify/RNET。首笔 AF/MMIO 前校验完整 bank 的容量、地址溢出、BAR范围、直接访问/DWORD对齐及每个尾行8B访问的4KB边界，并检查尾部与有效表/AF/Notify enable 的物理跨度冲突；有效行不与自身所属 bank 误判重叠。无消息路径不访问 MSI-X。显式 table-only 策略下 MSI-X Function enable 没有MMIO副作用，fixture验证的是尾部操作先于实际 Notify使能及后续类别。

非空 CONTROL/FUNCTION catalog 会涉及当前未实现的公共 hooks，因此预检在 AF/MMIO 前拒绝；table-only 策略按既有显式契约设置。公共 sequence 保留 success/error_msg 和继承的 fatal post_start；已经发出的 posted write 不承诺回滚。公共 scope 用非空 Function 列表与明确类别选择，另行核对 RDMA service，不能把 RDMA service 塞入只支持 VIO 的 service 校验。

表配置成功只说明路由前提成立。外部 RDMA 初始化还要验证同源 resource snapshot、公共 Host pool、每个 Function 的显式 grant，以及 grant 投影出的驱动配置；缺任一项都会在 MMIO/CMQ 前拒绝。模型测试合法发布的 VIO 资源/消息只能验证同源及公共表，不能冒充 RDMA grant；测试不编译 VIO 包，也不实现混合运行。`first_qp` 目前只是 bitmap 轮转起点，手填范围不能形成全局租约隔离。

## 独立启动与已有 project 接入

组合环境的最终 test package 位于 [`integration/virtio/tests/rdma_virtio_test_pkg.sv`](../integration/virtio/tests/rdma_virtio_test_pkg.sv)，导入 runtime/config/AIP 类型并由平台环境持有非拥有的 PCIe/Host 句柄。公共 sequence 只保留类型与业务逻辑，不注册独立 test 或 Tcl 命令。当前注册为：

```systemverilog
`aip_cmd_user_seq(dut_config, dut_cfg_seq, virtual_sqr::pcie_rc_sqr)
`rdma_aip_registry::bind_and_register(env.rdma, why)
`rdma_aip_registry::mark_configured(env.rdma, 0)
`aip_cmd_reg(reg_acc, dpu_bar_reg_seq, project_rc_sqr, seq.error_msg, seq.check_read_data)
```

组合入口对外只保留 `dut_cfg_seq`；真实平台在 `dut_config` 前完成平台就绪和 RC 绑定，再由 sequence 从 `project_env_cfg` 获取完整 Function/grant 快照。test 的 `run_phase()` 只运行 bridge 与 finish；默认 prepare 明确失败，真实平台提供完成/超时判定、一次绑定和安全收尾。driver/router 不读取全局命令上下文。

已有 project 只导入无副作用的类型包，沿用自己的 test/registry。在其唯一 load_params 中先检查所有组件生命周期，再各自构造候选，完整验证后统一无时间推进提交；DPU 只读一次，RDMA 不读取 DPU/VIO 参数。可复用 `rdma_aip_cfg_loader::make_runtime_candidate`、`rdma_env::validate_runtime_candidate/apply_runtime_candidate`；不要顺序调用多个已自行提交的子 loader。配置使用 `rdma_project_cfg_seq`，初始化调用 `rdma_env::initialize`，业务复用 `rdma_traffic_vseq`。

模型 fixture 的 VF global IDs 为1/2；生产平台应从已发布目录选择实际 peer，也可以通过 `cfg.rdma.flow_groups` 声明多条业务边。平台已进入 bridge 并 source 匹配 loader 后：

```tcl
set_param path=rdma.traffic.op value=write
if {[aip_check_status] != 0} { error [aip_read_result] }
set_param path=rdma.traffic.count value=100
if {[aip_check_status] != 0} { error [aip_read_result] }
foreach command {load_params dut_config rdma_init {rdma_run f0=1 f1=2}} {
    aip_send_cmd $command
    if {[aip_check_status] != 0} { error [aip_read_result] }
}
end_test drain=100ns
if {[aip_check_status] != 0} { error [aip_read_result] }
run
```

反序、重复初始化、缺失/相同端点和活动重入立即返回错误，不等待下一条 Tcl 命令。首次初始化尝试后，无论成功/失败/空闲均关闭 reload；取消不会自动清 busy 来假装可重入。没有释放后重新初始化或热改 traffic API。

## 参数和 checkpoint

当前唯一 `cfg.scenario` 拥有 qp/mem/pkt/traffic；`cfg.flow_groups` 保存 global Function ID 对和每条边的 `qp_count`，由同一个 `rdma_traffic_vseq` 顺序运行。细节见 [单场景参数](rdma-biz-param-design.md)。RC 支持七种操作，UD只支持send/send_imm，URC映射RC+urc且只支持send/write/write_imm。默认SGE1；每条WR按原分支采样，非法值报完整路径和范围，不裁剪/重抽。pkt覆盖目前仅netpkt软件codec可用，DUT非默认值在资源分配前拒绝。

项目 reload 的 DPU 消费范围仅 print_bar_map/verify_readback，PCIe保持构建值。全部候选合法后原地保留对象身份并清 configured，不提前MMIO或WR采样。完整override > leaf override > 完整CLI > leaf CLI > 默认值；可变字段的缺键使用新默认，固定mode/link/vseq/checker/cov缺键保留活动值、显式改变拒绝。AIP非法语法仍是hard fatal。

同一 binary 在初始化前保存；续跑脚本在顶层恢复，下一行重建AIP Tcl入口，再定义用户proc或source后续脚本。以下是平台通用顺序，base及AIP_CORE须先设置：

```tcl
aip_restore base
source [file join $::env(AIP_CORE) dist aip_init_so.tcl]
# 快照override仍优先；需要新CLI接管此键时显式清除。
clear_param path=rdma.traffic.count
if {[aip_check_status] != 0} { error [aip_read_result] }
load_params
if {[aip_check_status] != 0} { error [aip_read_result] }
# 随后显式dut_config、rdma_init、带实际f0/f1或group索引的rdma_run。
```

[`integration/virtio/tests/restore.tcl`](../integration/virtio/tests/restore.tcl) 和 [`integration/virtio/tests/run.sh`](../integration/virtio/tests/run.sh) 负责组合环境的恢复与参数验证。不能把同进程 `set_param` 测试当跨进程恢复证据。完整结果和外部能力限制见验证记录。

## 驱动字段来源与保留的硬件约定

2026-11-09 实际登录 `ubuntu@10.11.10.53` 进行只读核对，未运行仿真，也未修改远端文件：

| 来源 | 位置与结论 |
| --- | --- |
| RDMA 内核驱动 | `/home/ubuntu/rdma_driver_analysis/kernel/dpu_kernel_rdma-version_0.1.34` |
| 对应原始归档 | `/home/ubuntu/Downloads/dpu_kernel_rdma-version_0.1.34.tar(1).gz`；SHA-256 为 `c9d9286dde389f681f9bd1c29fff14f52c4c1ce11fa5f73a5f1f57da9f827522`，与本仓库 `hw/rdma/archive_lock.env` 一致 |
| 真正的 AF Notify 写表代码 | `/home/ubuntu/Downloads/emp.zip` 内的 `emp/app/dpu/af_mng.c`；不是 RDMA verbs 的 `post_send()` |
| EMP 文件身份 | `af_mng.c` 的 SHA-256 为 `b28aec75f7a05c9f44ae3f7be18334418bb5f2717403645ee84be18385e32c6b` |

可直接作为算法依据的函数是：

- `af_mng.c:1171`，`dpu_get_rdma_notify_tbl_entry_key()`：取表项低 51 位。
- `af_mng.c:1180`，`dpu_af_insert_rdma_notify_tbl_entry()`：输入地址已经右移 13 位，按 `{host_id[2:0], address[60:13]}` 升序插入；填入 8 位 `rdma_vf_id`，通过 `wr32_for_high_order()` 写 8B 表项。
- `af_mng.c:1338`，`dpu_af_alloc_rdma_vf_id()`：从 256 项 RDMA bitmap 分配 ID，不取 global Function ID。
- `af_mng.c:1358` 的注释及 `:1363` 的 `dpu_af_configure_rdma_vf()`：名称中的 VF 实际指 PCI Function；依次配置 Notify、RDMA QSCH/RNET 以及相关 MSI-X。

独立 bitmap 是该驱动的分配策略，不要求本项目另建 ID 池。`global_function_id` 由 dpu_common 冻结快照提供，`rdma_vf_id` 由平台针对 RDMA Function 发布的 grant 提供。HID_MAP/RPE 使用 global ID；Notify、RNET、QPC、PD、EQ 等 RDMA 资源使用 grant 中的 RDMA VF ID。简单平台可以让两者数值相等，但 RDMA 不强制二者相等。

生成当前表项时，先验证实际 Notify 窗口的 8KiB 对齐、地址可编码范围、Host 和 RDMA ID 位宽，再组装：

```text
entry[63:59] = 0
entry[58:51] = rdma_function_id
entry[50:48] = host_id
entry[47:0]  = actual_notify_address[60:13]
sort_key    = entry[50:0]
```

表项行号是排序结果，不是 RDMA ID。重复查找 key、重复 RDMA ID、容量超过 256 必须在第一笔写前拒绝。实际 Notify 地址由冻结 BAR 租约加业务 Notify 窗口偏移得到，不直接把 BAR 基址当成 doorbell 地址。RDMA 内核头文件的窗口起点为 `0x2000`，仍需与本项目实际 driver 绑定一致。

驱动版本差异必须保留记录：

| 项目 | RDMA 0.1.34 附带头文件 | 53 上 EMP | 当前 Virtio/DPU 配置约定 |
| --- | --- | --- | --- |
| RDMA Notify 表相对 PCOMPLETER 偏移 | `0x10000` | `0xc000` | `0xc000`，参考管理 BAR 内绝对偏移 `0x8c000` |
| RDMA Notify ready/select | `PCOMPLETER+0x48` | `PCOMPLETER+0x48` | 两类 Notify 使用 `管理 BAR+0x80044=1` |
| bank/写入批次 | 头文件带 `sel` | 整表写、读回重试、双 bank 翻转 | 单 bank、有效项批次、失败停止 |
| owner 类型 | 字段名为 `pfvf_id` | RDMA ID 对应 PCI Function，可含 PF/VF | 当前 catalog 接受已声明 RDMA service 的 PF/VF |

当前使能行为与参考仓库 `virtio_work/docs/superpowers/specs/2026-11-09-dpu-config-consolidation-design.md` 的设计记录一致。采用驱动的字段来源、排序与资源身份规则，保留当前硬件布局和使能约定；不能因为找到旧源码就恢复旧 bank 或 `+0x48`。PF/VF 的身份由 dpu_common 发布，RDMA 不根据字段名推导额外编号。

## 边界与后续范围

RDMA/VIO 共用同一 DPU 权威快照、Host pool 和 PCIe 路由；VIO 可以按 Host 拆分 env，RDMA 保持一个 env 并以 flow group 绑定任意 Function 对，实际 ring/QP/CQ/MR 仍由各业务管理。当前已支持每条边的多个对称 QP；不同 QP 的独立 SQ/RQ/CQ 深度和 CQ 共享、吞吐优化、完整表达式引擎迁移仍另行处理。真实 DUT 接线、网络端点和 grant 内容的最终验收由平台负责。
