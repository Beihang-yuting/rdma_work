# 在 virtio project_env 上加入 RDMA

本目录用本仓库的 `project_env_cfg` 和 `project_env` 组成 `project_env_pkg`，复用 `virtio_work` 的配置 sequence、`project_base_test` 和连接契约。外部 checkout 不改动，原 VirtIO filelist 也不受影响；独立 RDMA 示例仍在 [../project](../project/README.md)。

```text
project_env_cfg                         ← integration overlay，直接持有全部配置
  dpu_cfg / pcie_cfg / vio_cfg / VIF / pool
  rdma_cfg / rdma_enabled / rdma_functions

project_env                               ← 本地直接组合环境，不再派生 rdma_virtio_env
  pcie_env                                 ← 原 virtio，每 Host 一个 Intel RC
  shared_pool                              ← 全项目唯一 host_mem_pool
  dpu_env                                  ← 原 dpu_device_env，只解析一次身份/资源
    vio_h0, vio_h1, ...                    ← 原 virtio，每 Host 一个 VIO env
    rdma : rdma_env                        ← 基础 RDMA env，不再派生 RDMA 子类
```

两个业务均在 DPU 子树构建，消费同一 `device_snapshot/resource_snapshot`。RDMA 默认关闭；只有 `rdma_enabled=1`，或显式提供 `rdma_functions`/RDMA grant 时才创建 RDMA 子环境和 service。RDMA 开启但未给出 Function 时才选择全部 DPU Function，VIO-only 场景不会因为 DPU 有 Function 就触发 RDMA 配置。RDMA Function 的 `host_mem_manager` 与同 Host 的 VIO、PCIe 完全相同；不同 Host 使用独立 manager。global Function ID/BDF/BAR 仍由 DPU 唯一分配，RDMA 不重新 resolve。

| 文件 | 复用关系与职责 |
| --- | --- |
| [project_env_cfg.sv](project_env_cfg.sv) | integration-only `project_env_cfg` overlay；直接创建 `rdma_cfg` 并门控 RDMA 参数 |
| [rdma_project_env_pkg.sv](rdma_project_env_pkg.sv) | 使用本地 overlay，包含本地 `project_env` 和外部 `project_base_test`，不修改 virtio_work |
| [project_env.sv](project_env.sv) | 直接创建 DPU、PCIe、VIO、共享 pool 和可选 RDMA 子环境；只负责 build/connect/load_params |
| [rdma_virtio_cfg_seq.sv](rdma_virtio_cfg_seq.sv) | 继承 `vio_dpu_cfg_seq`；复用 RDMA 预检和 Notify/RNET 写表 |
| [rdma_virtio_test.sv](rdma_virtio_test.sv) | 继承 `project_base_test` 的三个平台钩子；run 阶段只运行 AIP bridge |
| [../filelists/rdma_virtio.f](../filelists/rdma_virtio.f) | 独立组合 filelist，不加入旧 `sim/filelists` |

## 平台怎么接

从 RDMA 仓库根使用 `rdma_virtio.f`，将 `@AIP_CORE_ROOT@`、`@DPU_COMMON_ROOT@`、`@HOST_MEM_ROOT@`、`@NET_PACKET_ROOT@`、`@PCIE_WORK_ROOT@`、`@PCIE_INTEL_ROOT@`、`@VIRTIO_WORK_ROOT@` 展开为实际路径，再追加自己的 test package 和 top。该清单已编译全部依赖，不叠加原独立 `rdma_project.f` 或重复编译 `project_env_pkg`。

平台 test 继承 `rdma_virtio_test`，继续实现 virtio 已有的接口：

1. `bind_platform_handles()`：在 cfg 加载后、env build 前注入 Intel VIF、可选已有 pool/IOMMU。仅使用模型向 DUT 注包时才需要网络 endpoint。`cfg` 本身就是 integration 的 `project_env_cfg`，直接使用 `cfg.rdma_cfg` 及原有 `cfg.intel_rc_vifs` 等字段。
2. `prepare_platform()`：仅由 Tcl `dut_config` 调用。等待真实 reset/readiness；grant 已在 build 阶段生成，Intel BAR/hw 已在 connect 阶段绑定，不在这里重复创建。失败按原 virtio 钩子契约报 fatal。
3. `finish_platform()`：Tcl 结束后检查数据、完成和资源，确认 DUT 不再 DMA，再撤销平台借出的句柄。

需要在加载参数前自定义默认值/Function 选择时，直接创建 `project_env_cfg`，通过 `uvm_config_db#(project_env_cfg)` 的 `project_cfg` 键提供给 test，并设置 `rdma_enabled=1`。也可以使用 `+rdma.enabled=1`；显式 Function/grant 会自动打开 RDMA。父类 `cfg` 与组合 env 的 `project_cfg` 指向同一对象，没有兼容字段同步或配置复制。

普通业务参数继续使用 `+rdma.qp.*`、`+rdma.mem.*`、`+rdma.pkt.*`、`+rdma.traffic.*`；VIO/DPU 参数完全沿用 virtio 项目。VIO 默认 pairs=0，需要业务时按 virtio 的契约提供 Packed/Custom 队列几何、Notify 和完成模式。真实表布局、Function 策略与 MSI-X 消息由平台提供；本示例不会猜测硬件偏移或 requester 编码。

### 自动 grant 与启动参数

普通用例不必在 tc_base 填 `rdma_functions` 或 `grants`。启动参数例如：

```bash
+rdma.enabled=1 +vio.pairs=0 +dpu.hosts=1 +dpu.pfs_per_host=1
```

RDMA 开启后默认选择全部 DPU Function；多 Host/PF/VF 仍由 `dpu.*` 声明，Intel requester/PFVF/VIF 接线沿用平台实际配置。`rdma_run` 的双端场景需要两个不同的有效 Function ID，单 Function 配置只能先做配置/初始化。

下列参数在 **build 阶段**采样；通用路径为 `rdma.resource.*`，可由 `rdma.hH.resource.*`、`rdma.hH.pfP[.vfV].resource.*` 逐层覆盖：

| 字段 | 默认值 | 含义 |
| --- | --- | --- |
| `qp_count` | 64 | QP 容量，包含保留的 QPN 0/1 |
| `cq_count` / `mr_count` | 64 | 每 Function 的 CQ/MR 容量 |
| `pbl_count` | 1024 | PBL 容量 |
| `pd_count` / `srq_count` | 16 | 每 Function 的 PD/SRQ 容量 |
| `ceq_count` | 1 | 每 Function 的 CEQ 数量 |
| `eth_port` | 0 | 真实 QSCH Ethernet 出口，默认 ETH0 |

例如 `+rdma.resource.qp_count=128 +rdma.h0.pf1.resource.ceq_count=2`。SD 数量按驱动 HMC 布局自动计算，SD/CEQ/vector 不重叠；实际 SD 页表及 IOVA 在显式 `rdma_init` 时通过共享 host_mem 分配，不再填写 `sd_iova`。

这些容量和编号随环境构建固定；restore 后的 `load_params` 继续重载已有的 QP 行为、报文、流量参数，不重新分配 grant。MSI-X 地址/data 使用已有 `dpu.*.msix` 模板；未提供模板时不生成中断消息，基础场景使用轮询。已生成消息在重载时保留向量编号并更新模板值。

真实 Intel PCIe 驱动模式使用 `external_configuration=1`，不要求 `dut_endpoint`。显式选择 `rdma_dut_link` 才要求该接口。ETH 环回暂未接入；DUT TX ready 仍必须由 MAC 侧驱动。没有 TX→RX 回包路径可以观察首批 TX，RC 的 ACK、接收及完成检查不能因此认为通过。

RDMA Notify/RNET catalog 使用父环境的实际 BAR map 生成，再调用 DPU 的同源 `publish()` 补齐配置值。这里不会改写冻结拓扑或重新分配资源；因为父 `publish_dpu_configuration()` 不是虚函数，适配留在本仓库。平台不要再手工添加第二份 RDMA catalog。

## Tcl 显式执行

`rdma_virtio_test.run_phase` 只启动 bridge，不自动 prepare、配置、初始化或发包。常见顺序：

```tcl
# source 与 simv 匹配的 AIP loader 后，显式执行：
set_param path=rdma.traffic.count value=100
load_params
dut_config
# 使用 VIO 时，沿用 virtio 的 vio.target 和业务命令。
vio_start
# RDMA grant 已由 project_env_cfg 自动补齐；真实硬件须已 ready。
rdma_init
rdma_run f0=0 f1=1 qps=2
# 0/1 只是例子，必须替换为该快照中的实际 global Function ID。
```

可直接使用 [rdma_start.tcl](rdma_start.tcl)：先设置 `::rdma_f0/::rdma_f1`，再 source。该脚本逐项检查 AIP 返回状态，不会在配置或初始化失败后继续发包。

`dut_config` 在 RDMA 开启且存在 VIO Function 时运行一条 `rdma_virtio_cfg_seq`：先 RDMA 完整目录预检，随后由原 virtio 父序列执行 AF/BDF/MSI-X 等公共表；在准备 VIO ring 前加入 RDMA Notify/RNET，然后继续原 VIO Notify/QSCH/队列配置与确认。RDMA 开启但没有 VIO Function 时，命令直接运行独立的 `rdma_project_cfg_seq`；RDMA 关闭时直接运行原 `vio_dpu_cfg_seq`，因此不会生成 RDMA catalog、hardware plan、Notify/RNET 或 RDMA 写表。公共表只配置一次。配置成功不表示 RDMA driver 已初始化。

组合命令仍只由 Tcl 显式启动：`rdma_init` 创建 `rdma_init_seq`，`rdma_run` 创建 `rdma_run_seq`；`project_env` 不保存启动状态，也不在 phase 中自动创建或启动业务 sequence。独立 RDMA-only 案例使用相同的三个 sequence，见 [../project/tests/run_commands.sh](../project/tests/run_commands.sh)。

`load_params` 只有一个有效注册对象。当前 virtio 的环境重载 task 不是 virtual，因此 test 在 EOE 核对原 loader 身份后，通过 AIP 的公开 `unregister` 接口替换这一个入口；`vio_release` 和 VIO 业务命令保持原对象/实现。没有改写 AIP 宏，也不注册第二个加载范围。

统一重载先验证 RDMA 候选，再调用原 virtio 的 DPU/VIO 事务，成功后原地应用 RDMA。任一侧拒绝均不提交。当前依赖的父事务不推进仿真时间，版本与源码摘要记录在 [dependencies.tsv](dependencies.tsv)。VIO 有活动代时先由用户安排停机/释放；RDMA 首次初始化尝试后关闭重载窗口。

Restore 使用同一 binary；在未配置、未初始化时保存。恢复后立即重新 source 匹配的 AIP loader，再执行一次 `load_params`。保存的 `set_param` override 仍优先于新进程 CLI；清除 override 后，同一个命令会加载新的 CLI 值。

## 验证与当前边界

在 `ubuntu@10.11.10.53` 登录 bash 中设置上述七个依赖根和 `RDMA_ROOT`，运行：

```bash
RDMA_GRANT_SMOKE_ONLY=1 bash integration/virtio/tests/run.sh
```

结果、实际依赖与日志位置见 [VALIDATION.md](VALIDATION.md)。结构回归创建真实组合组件，验证多 Host/PF/VF 的快照/pool/PCIe 句柄、原 VIO 命令、事务拒绝和跨进程 restore。top 只提供空闲接口，没有 DUT 或 Completion responder，不能据此宣称真实配置写入或混合业务收发通过。

RDMA 保持单 bank，字段约束仍为 Host ID < 8、global Function ID 与 RDMA VF ID < 256。未手工提供 grant 时，组合配置自动生成，默认 RDMA VF ID 等于冻结 global Function ID；显式 grant 仍允许两者不同。SD/CEQ/source 属于 RDMA 独立资源；MSI-X 从 DPU 已占用的 LAN/mailbox/AF 前缀之后分配，不改写 VIO 分配。当前 DPU 未导出通用 RDMA allocator，组合配置显式适配并校验这一前缀契约。
