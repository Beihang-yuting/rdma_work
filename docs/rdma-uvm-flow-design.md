# RDMA UVM 验证流程设计（seq → 驱动 → 设备 → 报文 → 内存）

日期：2026-10-06（取代 2026-10-05 的 NIC 行为模型版本）。分支：`feature/rdma-arch-slim`。
当前没有 RTL DUT，`src/dev` 设备模型作为“设备”；接入 DUT 后设备模型可退为预测器。

## 1. 结构

```
test
 └ rdma_tb_env (uvm_env)
    ├ rdma_verb_agent[n]   seq → rdma_verb_item → driver → rdma_drv_wr.post_send/post_recv
    │                      monitor：rdma_drv_wr.poll_cq → rdma_verb_completion → analysis
    ├ rdma_wire            按目的 MAC 路由设备 NIC 发出的报文；analysis 端口观测全部报文；
    │                      可替换为经 net_packet 帧编解码的实现（E2E）
    └ rdma_tb_scoreboard   影子内存预测（SEND/WRITE/READ/ATOMIC）+ 完成比对（wr_id/status/len/imm）

每个节点（测试创建，经 rdma_tb_node_cfg 交给 env）：
  host_mem ── rdma_drv_dev（probe：CMQ、HMC、EQ）── BAR ── rdma_dev（CMQ 消费者 + context 存储 + NIC）
```

主机与设备之间只有真实硬件边界：CMQ 环（命令与 context 经 DMA 读取）、MMIO doorbell
（BAR+0x2000 窗口）和按 IOVA 的 DMA。设备不调用任何主机对象。

## 2. 关键约定

- **节点配置** `rdma_tb_node_cfg`：MAC、`rdma_dev`、`rdma_drv_dev`、CQ、QP 连接表（本地 QP →
  对端节点/QP 下标）、数据 MR（`rdma_drv_mr`，覆盖整个 `data_buf`，VA = IOVA）、MTU、UD Q_Key。
- **投递**：driver 把源数据写入 `data_buf`，按 `rdma_drv_wr` 填 64B WQE（inline/SGE/SGB、签名、
  polarity）并按 `hw_drop_db_cnt` 规则敲 SQ doorbell；RECV 写 RQE、shadow PI 与 RQ doorbell。
- **设备 TX**（`rdma_dev_nic`）：SQ doorbell → 从 QPC 的 SQ PBA/OM 读 SQE → 校验签名 → MRT 校验
  （key、状态、PD、权限、范围，PBL 模式 0/1/2）→ DMA 读 → 按 PMTU 分段发包；RC 等 ACK、READ 响应
  或 ATOMIC ACK 后写 SQ CQE；drain 后回写 `hw_drop_db_cnt`。
- **设备 RX**：SEND 取 RQE（shadow PI）散写，WRITE 按 RETH/rkey 写入（WRITE_IMM 消费 RQE），
  READ 读出回包，ATOMIC 读改写；RC 响应的目的 QPN 取自本端 QPC（BTH 不带源 QPN）。
  访问错误回 NAK，请求方 CQE 带错误 ecode。
- **完成**：设备按 CQC 写 32B CQE（polarity），CQ armed 时写 CEQE；驱动 `poll_cq` 按 WQE_INDEX
  回查 wr_id 并更新 shadow CI。

## 3. 验收

- core：`rdma_drv_data_test`（两节点、逐项操作与 CQ arm 事件）、`rdma_tb_flow_test`（mock host_mem，
  loopback wire，完整流量序列）。
- e2e：`rdma_tb_e2e_test`：真实 host_mem + net_packet RoCEv2 帧编解码 wire，同一组 sequence。
- 传输矩阵：RC/UD（qp_index 0/1）。状态：两项均通过（28 项检查零错误）。

## 4. 后续

URC（驱动与设备）、SRQ 接收、CQ resize、AEQE 错误上报、flush、UD GRH/Q_Key 校验、
PSN 乱序重传、RNR 重试、接入 DUT。
