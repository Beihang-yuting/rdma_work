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
  访问错误回 NAK（0x61/0x62/0x63），请求方 CQE 为 0xB9 + RC_REMOTE_SYNDROME，驱动映射为
  REM_INV_REQ/REM_ACCESS/REM_OP。UD 先校验 DETH Q_Key（不符静默丢弃），接收缓冲前 40B 为 GRH
  （RoCEv2 IPv4），byte_len 含 40。SRQ 的 SGE>2 走 SGB（签名）。
- **可靠传输**：请求方每个 WQE 从首 PSN 起尝试；超时或 PSN 序列 NAK 消耗 PSN_RETRY_TH（耗尽 0x16/
  0x18），RNR NAK 等 rnr_delay 后消耗 RNR_RETRY_TH（7 无限，耗尽 0xB7），其余 NAK 致命（0xB9）。
  响应方：PSN 早于期望为重复请求（重发 ACK、重放 READ、回缓存的 ATOMIC 原值，不再执行），晚于期望
  回一次 PSN 序列 NAK；无 RQE 回 RNR NAK 且不推进期望 PSN。
- **URC 异常**：请求方致命错误或接收侧长度错误时设备写 ABNML CEQE（类型 SQ/RQ、ecode、远端 syndrome、
  异常 WQE 位置）并停止该 SQ；驱动记入 URC 信息区，轮询时异常位置前的 WQE 报异常完成，其后 FLUSH。
- **完成**：设备按 CQC 写 32B CQE（polarity），CQ armed 时写 CEQE；驱动 `poll_cq` 按 WQE_INDEX
  回查 wr_id 并更新 shadow CI。

## 3. 验收

- core：`rdma_drv_data_test`（两节点、逐项操作与 CQ arm 事件）、`rdma_tb_flow_test`（mock host_mem，
  loopback wire，完整流量序列）。
- e2e：`rdma_tb_e2e_test`：真实 host_mem + net_packet RoCEv2 帧编解码 wire，同一组 sequence。
- 传输矩阵：RC/UD/URC（qp_index 0/1/2；URC 在 rc_to_urc 下创建，用专属 CQ 的 frag，完成经 CEQE
  的 HW_CPL 上报，monitor 每轮先处理 CEQ）。状态：两项均通过（33 项检查零错误）。
- 高流量：`rdma_tb_e2e_high_traffic_test`（4096 个 SEND，整窗填满 256 深 SQ/RQ，4114 项检查）。
- 可靠性：`rdma_drv_reliability_test`（请求丢包重传、ACK/READ 响应/ATOMIC ACK 丢失的重复处理、RNR
  重试与耗尽、UD Q_Key/GRH、SRQ SGB、URC SQ/RQ 异常完成）；`rdma_multifunc_test` 的丢包项改为
  “丢一包重传成功 + 持续丢包重试耗尽 0x16”。

## 4. 后续

接入 DUT。未建模：URC 异常经 AEQE 上报的路径（当前只走 CEQE）、乱序到达后的选择性重传（当前整条
WQE 从首 PSN 重发）、RNR 定时器编码（当前固定 rnr_delay）。
