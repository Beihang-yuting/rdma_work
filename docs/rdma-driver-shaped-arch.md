# RDMA 驱动形状架构与迁移计划

日期：2026-10-05。分支：`feature/rdma-arch-slim`。前置：CMQ 已按驱动 `cmq.c` 重写（ce10173..31b5719）。

## 1. 现状问题

- 主机侧模型 src 约 9.4 万行，驱动全部约 2.1 万行 C。多出的部分主要是驱动没有的机制：
  recovery/replay/pending 账本、authority/epoch/generation/lease、detached 快照 projector、
  null 归一化。CQ/CEQ/AEQ/SRQ policy 结构相同（CEQ/AEQ 仅差 1 行），但模型类型与字段名各自独立。
- 设备边界不真实。现有 tb 数据通路虽然逐字节比对，但 NIC 模型直接读取主机侧软件状态：
  `qp.qp_plan.sq_ref`（SQ 地址）、`engine.query_runtime_cursors()`（SQ PI）、
  `manager.lookup_local_resource()`（MR 校验）、`engine.publish_cqe()`（写 CQE）。
  CMQ 在 tb 中接 `rdma_mock_cmq_port`，命令不被任何设备消费；MR 绕过 CMQ 直接写 resource manager。
- 驱动行为缺口：CQ resize 不下发 `CQC_RESIZE`、无 CQ arm、无 SRQ modify/limit、destroy CQ 不清理 CEQE、
  QP 转 ERR 无 flush doorbell、SQ doorbell 每 WR 一次（驱动每链一次）。

## 2. 目标结构

硬件边界只有三种接口，主机侧与设备侧都只经由它们交互：

| 接口 | 主机侧（驱动模型） | 设备侧（NIC 模型） |
| --- | --- | --- |
| CMQ | `rdma_cmq_engine`（已完成）在主机内存环写 SQE、敲 CMQ doorbell、轮询 CQE | 读 CMQ SQE、解码、更新 context 存储、写 CQE |
| MMIO doorbell | `rdma_pcie_api.mmio_write` | doorbell 解码 → SQ/RQ/SRQ PI、CQ arm、EQ CI |
| DMA | `rdma_host_mem_api` 读写 WQE/CQE/EQE/数据/shadow | 同一 host_mem，按 context 中的地址访问 |

层次（一个模块对应驱动一个源文件）：

```
L0 types/defs   rdma_types_pkg + rdma_defs.svh（寄存器/上下文/WQE 布局）
L1 codec        位打包：CMQ（驱动 golden）、QPC/CQC/MRT/EQC/SRFQC、SQE/RQE/CQE/EQE、doorbell
L2 drv          主机侧驱动模型（新）：
                  rdma_drv_dev   probe/remove：HMC 静态切分、bitmap 分配、CMQ 初始化、CEQ/AEQ 创建
                  rdma_drv_pd/mr PD 分配；reg_mr（stag + PBLE + MR_REGISTER）、dereg_mr（OCC flush + MR_DEREGISTER）
                  rdma_drv_cq    create/destroy/resize（CQC_RESIZE + copy_resize_cqes）/arm/poll
                  rdma_drv_srq   create/modify(limit+arm)/destroy/post_srq_recv
                  rdma_drv_qp    create/modify(含 SQD/ERR flush doorbell)/destroy/post_send/post_recv
                  rdma_drv_eq    process_ceq/process_aeq + CI doorbell
L3 dev          设备侧 NIC 模型（由现 src/tb/rdma_nic_model 演化）：
                  CMQ 消费者 + context 存储（QPC/CQC/MRT/SRFQC/CEQC/AEQC，按 Function 隔离）
                  doorbell 接收；SQ 处理/RX/ACK；按 CQC 写 CQE、按 EQC 写 CEQE/AEQE
L4 adapter      现 src/adapter 抽象接口 + src/adapters 外部 VIP 绑定（不变）
L5 tb           verb agent / wire / scoreboard（不变，driver 换成 L2）；多 Function env
```

失败处理按驱动 goto 链：硬件命令失败即返回错误并回退本次已完成步骤，不做重试、恢复或歧义分类。
多 Function 按驱动：每个 Function 一个独立 `rdma_drv_dev` 实例（probe/remove），FLR 等价于 remove + probe。

## 3. 迁移阶段（每阶段全量回归）

| 阶段 | 内容 | 旧代码 |
| --- | --- | --- |
| A | 设备侧 context 存储 + CMQ 消费者（由 `rdma_cmq_device_responder` 演化），覆盖 70 个 opcode 的状态效果；单元测试用 CMQ golden 驱动 | 不动 |
| B | L2 驱动模型：dev/pd/mr/cq/srq/qp/eq，补齐 §1 缺口；单元测试直接对接 A 的设备 | 不动 |
| C | NIC 模型改走真实边界（doorbell、context 存储、按 CQC 写 CQE），tb 改用 L2；`rdma_tb_flow_test`/`rdma_tb_e2e_test` 迁移，数据端到端检查不变 | 不动 |
| D | 集成：多 Function env 基于 L2 实例；E2E（dual env、multi-VF、high traffic、AEQE）迁移；multi-VF recovery、reset cascade 改为验证 remove/probe 隔离 | 不动 |
| E | 删除旧层：queue_data_engine、queue/QP lifecycle executor+policy、resource_manager/projector、queue_runtime、doorbell scheduler、integration reset/epoch 机制、对应模型与测试、只服务旧层的门禁 | 删除 |

A–D 只新增代码，旧回归保持全绿；E 一次性删除，验收为迁移后的套件全绿。

## 4. 保留

CMQ 引擎与驱动 golden 门禁、全部 codec 与其 golden/字段门禁、host_mem/net_packet/pcie_work 适配器、
tb 的 sequence/wire/scoreboard。
