# RDMA TX-only 参数化实施计划

## 目标

在 VirtIO 组合环境中增加真实 DUT 的 TX-only 发包路径。配置、初始化和发包仍由三个清晰阶段完成；本阶段不接 RX、环回或 ACK 完成。RC/UD 按 `rdma.qp.type` 选择，首轮 RC 无 ACK 只验证有限首发帧。

## 不变量

1. `project_env_cfg` 是参数和 grant 的唯一准备者；`project_env` 只组装、连接和发布句柄。
2. `dut_cfg_seq` 只下发表配置；`rdma_init` 才 probe/发布 ready；`rdma_run` 才创建 QP 和发送 WR。
3. 模型双端流量保持原语义；external TX 使用单本地 Function 和显式目的 QPN/QKey/MAC/IP，不制造 peer 或 RECV。
4. 源 MAC/IP 通过已有 `SRC_ADDR_UPDATE` CMQ 字段接口配置，源索引来自 grant；QP/WQE 只消费冻结后的物化值。
5. 参数按 Function、QP、WR 分层采样一次；实际 QPC/WQE、Host memory 和 TX 期望复用同一结果。固定值不隐式随机替换，非法值不裁剪。
6. TX 成功要求平台 monitor 观察到完整正确帧；RC ACK/CQE、远端收包和端到端 scoreboard 不作为本轮成功条件，但本地 DMA、编码、投递和 TX 超时仍失败。

## 实施步骤

### 1. 配置与参数

- 扩展 `rdma_scenario_cfg`、AIP loader 和运行时候选，加入 `dest_qpn`、源/目的 MAC、`data_fixed`、`data_pattern`、`imm`，沿用 AIP 常量、范围、候选和权重表达式。
- 增加 Function/Host/精确 PF/VF 的网络字段覆盖，build 时只采样拓扑和 grant 固定字段。
- 为源地址保存 Function 级物化 MAC/IP；为目的地址、VLAN、UDP 源端口、目标 QPN 保存 QP 级物化值；为 payload/IMM 保存 WR 级值。

### 2. 硬件编码和源地址

- 在 `rdma_drv_dev` 的初始化窗口使用 `rdma_hw_cmq_field_codec` 下发 `SRC_ADDR_UPDATE`，并用最小可观察存储/QUERY 处理验证模型不再默认成功。
- 在 QPC modify 路径传递源索引、目标字段、VLAN 和 UDP 源端口；在 UD WQE 填充源索引、VLAN、目标字段和 IMM；移除 UDP 源端口隐式随机。
- 复用现有字段编码和位宽定义，不新增 MMIO 表或外部依赖。

### 3. TX sequence

- 在现有 `rdma_traffic_vseq`/运行入口增加 external TX 分支：单 Function、多 QP、SEND/SEND_IMM、无 RECV/peer。
- 预检本地 PD/MR/CQ/QP、SQ/发送窗口和 buffer 容量；RC 首轮每 QP 一条、长度不超过 MTU，后续扩大窗口需单独验证。
- 贯通 CQE 等待、补 signaled、`wait_idle` 和 scoreboard leftovers 的 TX 语义，不能仅删除某个等待点。
- 通过平台已有完整帧 monitor 验收数量、出口、QP/PSN、头字段和 payload；区分 WR 数、首发帧、分片与重传。

### 4. 集成与回归

- 保持 `dut_cfg_seq → rdma_init → rdma_run` Tcl/SV 两条入口，显式 TX 选择不能被默认 flow groups 覆盖。
- 增加参数固定值/随机表达式、Function/QP/WR 一次采样、源表 QUERY、QPC/WQE 字段和 TX 观测 fixture。
- 复用现有多 Host/PF/VF、多 QP、固定参数 reload 和模型双端测试；新增 external TX 仅依赖平台 monitor，不把结构 fixture 当真实 DUT 证据。

## 验证门禁

- `git diff --check`、SV 风格检查、参数/profile 静态检查。
- 本地 codec/CMQ/sequence fixture 编译与单测。
- 所有 VCS 仿真在 `ubuntu@10.11.10.53` 登录 bash 环境运行；真实 TX 需用户平台提供 ready/backpressure、PCIe completion 和完整帧 monitor。
- 全目录复审文件头、函数中文注释、对象所有权、固定参数生命周期、错误路径和 reset 限制。
