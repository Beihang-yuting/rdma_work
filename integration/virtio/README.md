# 在 virtio project_env 上加入 RDMA

本目录直接编译 `virtio_work/integration/project/project_env_pkg.sv`，在其环境上增加 RDMA；原 VIO 的 Host 内存、Intel RC、DPU 解析、协议连接及业务命令均复用。独立 RDMA 示例仍在 [../project](../project/README.md)。

```text
rdma_virtio_env_cfg extends project_env_cfg
  dpu_cfg / pcie_cfg / vio_cfg / vio_cfg_by_host / VIF / pool  ← 原 virtio 字段
  rdma_cfg / rdma_enabled / rdma_functions                  ← 本项目新增

rdma_virtio_env extends project_env
  pcie_env                 ← 原 virtio 创建，每 Host 一个 Intel RC
  shared_pool              ← 全项目唯一 host_mem_pool
  dpu_env                  ← 原 dpu_device_env，只解析一次身份/资源
    vio_h0, vio_h1, ...     ← 原 virtio 创建，每 Host 一个 VIO env
    rdma                   ← 新增一个 RDMA env，包含所选 Host/PF/VF 的全部节点
```

两个业务均在 DPU 子树构建，消费同一 `device_snapshot/resource_snapshot`。RDMA 默认关闭；只有 `rdma_enabled=1`，或显式提供 `rdma_functions`/RDMA grant 时才创建 RDMA 子环境和 service。RDMA 开启但未给出 Function 时才选择全部 DPU Function，VIO-only 场景不会因为 DPU 有 Function 就触发 RDMA 配置。RDMA Function 的 `host_mem_manager` 与同 Host 的 VIO、PCIe 完全相同；不同 Host 使用独立 manager。global Function ID/BDF/BAR 仍由 DPU 唯一分配，RDMA 不重新 resolve。

| 文件 | 复用关系与职责 |
| --- | --- |
| [rdma_virtio_env_cfg.sv](rdma_virtio_env_cfg.sv) | 继承 `project_env_cfg`；仅追加 RDMA service 需求及参数 |
| [rdma_virtio_env.sv](rdma_virtio_env.sv) | 继承 `project_env`；追加一个 RDMA 子环境及显式生命周期 |
| [rdma_virtio_cfg_seq.sv](rdma_virtio_cfg_seq.sv) | 继承 `vio_dpu_cfg_seq`；复用 RDMA 预检和 Notify/RNET 写表 |
| [rdma_virtio_test.sv](rdma_virtio_test.sv) | 继承 `project_base_test` 的三个平台钩子；run 阶段只运行 AIP bridge |
| [../filelists/rdma_virtio.f](../filelists/rdma_virtio.f) | 独立组合 filelist，不加入旧 `sim/filelists` |

## 平台怎么接

从 RDMA 仓库根使用 `rdma_virtio.f`，将 `@AIP_CORE_ROOT@`、`@DPU_COMMON_ROOT@`、`@HOST_MEM_ROOT@`、`@NET_PACKET_ROOT@`、`@PCIE_WORK_ROOT@`、`@PCIE_INTEL_ROOT@`、`@VIRTIO_WORK_ROOT@` 展开为实际路径，再追加自己的 test package 和 top。该清单已编译全部依赖，不叠加原独立 `rdma_project.f` 或重复编译 `project_env_pkg`。

平台 test 继承 `rdma_virtio_test`，继续实现 virtio 已有的接口：

1. `bind_platform_handles()`：在 cfg 加载后、env build 前注入 Intel VIF、可选已有 pool/IOMMU 和网络 endpoint。通过 `$cast(combined, cfg)` 取得 `rdma_virtio_env_cfg`，用 `combined.rdma_cfg` 设置 RDMA link/endpoint；原 `cfg.intel_rc_vifs` 等字段直接沿用。
2. `prepare_platform()`：仅由 Tcl `dut_config` 调用。等待真实 reset/readiness，并用 `project.rdma.sys` 给各 Function 绑定硬件上下文与明确的 RDMA 资源授权。失败按原 virtio 钩子契约报 fatal。
3. `finish_platform()`：Tcl 结束后检查数据、完成和资源，确认 DUT 不再 DMA，再撤销平台借出的句柄。

需要在加载参数前自定义默认值/Function 选择时，先创建 `rdma_virtio_env_cfg`，通过 `uvm_config_db#(project_env_cfg)` 的 `project_cfg` 键提供给 test，并设置 `rdma_enabled=1`。也可以使用 `+rdma.enabled=1`；显式 Function/grant 会自动打开 RDMA。父类的 `cfg/env` 字段与新增 `project/project_cfg` 引用指向同一对象，没有兼容字段同步或配置复制。

普通业务参数继续使用 `+rdma.qp.*`、`+rdma.mem.*`、`+rdma.pkt.*`、`+rdma.traffic.*`；VIO/DPU 参数完全沿用 virtio 项目。VIO 默认 pairs=0，需要业务时按 virtio 的契约提供 Packed/Custom 队列几何、Notify 和完成模式。真实表布局、Function 策略与 MSI-X 消息由平台提供；本示例不会猜测硬件偏移或 requester 编码。

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
# RDMA 需要平台已具备真实硬件及 RDMA grant。
rdma_init
rdma_run f0=0 f1=1 qps=2
# 0/1 只是例子，必须替换为该快照中的实际 global Function ID。
```

可直接使用 [rdma_start.tcl](rdma_start.tcl)：先设置 `::rdma_f0/::rdma_f1`，再 source。该脚本逐项检查 AIP 返回状态，不会在配置或初始化失败后继续发包。

`dut_config` 在 RDMA 开启时运行一条 `rdma_virtio_cfg_seq`：先 RDMA 完整目录预检，随后由原 virtio 父序列执行 AF/BDF/MSI-X 等公共表；在准备 VIO ring 前加入 RDMA Notify/RNET，然后继续原 VIO Notify/QSCH/队列配置与确认。RDMA 关闭时直接运行原 `vio_dpu_cfg_seq`，因此不会生成 RDMA catalog、hardware plan、Notify/RNET 或 RDMA 写表。公共表只配置一次。配置成功不表示 RDMA driver 已初始化。

`load_params` 只有一个有效注册对象。当前 virtio 的环境重载 task 不是 virtual，因此 test 在 EOE 核对原 loader 身份后，通过 AIP 的公开 `unregister` 接口替换这一个入口；`vio_release` 和 VIO 业务命令保持原对象/实现。没有改写 AIP 宏，也不注册第二个加载范围。

统一重载先验证 RDMA 候选，再调用原 virtio 的 DPU/VIO 事务，成功后原地应用 RDMA。任一侧拒绝均不提交。当前依赖的父事务不推进仿真时间，版本与源码摘要记录在 [dependencies.tsv](dependencies.tsv)。VIO 有活动代时先由用户安排停机/释放；RDMA 首次初始化尝试后关闭重载窗口。

Restore 使用同一 binary；在未配置、未初始化时保存。恢复后立即重新 source 匹配的 AIP loader，再执行一次 `load_params`。保存的 `set_param` override 仍优先于新进程 CLI；清除 override 后，同一个命令会加载新的 CLI 值。

## 验证与当前边界

在 `ubuntu@10.11.10.53` 登录 bash 中设置上述七个依赖根和 `RDMA_ROOT`，运行：

```bash
bash integration/virtio/tests/run.sh
```

结果、实际依赖与日志位置见 [VALIDATION.md](VALIDATION.md)。结构回归创建真实组合组件，验证多 Host/PF/VF 的快照/pool/PCIe 句柄、原 VIO 命令、事务拒绝和跨进程 restore。top 只提供空闲接口，没有 DUT 或 Completion responder，不能据此宣称真实配置写入或混合业务收发通过。

RDMA 保持单 bank，字段约束仍为 Host ID < 8、global Function ID 与 RDMA VF ID < 256。真实初始化由平台为每个 Function 发布 RDMA grant；组合层不会把 VIO 队列授权冒充 RDMA 授权，也不会强制两个 ID 相等。
