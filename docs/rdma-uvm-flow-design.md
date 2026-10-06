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

Function 身份与 BAR 由 dpu_common 管理（`src/adapters/dpu/rdma_dpu_adapter_pkg.sv`）：
`rdma_dpu_system` 用 `rdma_dpu_topology` 声明 Host/PF/VF（BAR 随机放置），`dpu_device_resolver` 解析并
冻结快照；每个 Function 的 host_id、global Function ID（驱动 QPC/PD 的 VF_ID）、BDF、BAR0/MAILBOX/MSI-X
取自快照。`build` 为每个 Function 建主机内存（`rdma_dpu_mem_factory`）、设备、驱动 BAR 与驱动；`probe`
以快照身份初始化驱动；`find`/`pf_scope`/`host_scope`/`device_scope` 按快照求复位范围，`flr`/`recover`
对范围内 Function 复位并重新 probe。驱动 doorbell 写 BAR0（驱动 `pf->hw_addr`）基址 + 偏移的绝对地址，
`rdma_dpu_bar_router` 用 `snapshot.resolve_bar_address` 解码到所属设备；MAILBOX/MSI-X 与 BAR 外地址拒绝
（这两个 BAR 只分配，寄存器与中断未建模）。e2e 的 net_packet Function identity 也由快照生成。
全部单元测试（`tests/support/rdma_dpu_test_system.sv`）、tb 与 multifunc 都经 `rdma_dpu_system`。

设备对主机内存的访问全部经 `rdma_dev_dma`（task）。默认后门直接读写 host_mem；pcie_work suite
（`src/adapters/pcie_work/rdma_pcie_work_pkg.sv`）以 factory 覆盖为 PCIe 路径：

```
dpu_common 快照 ── pcie_topology（每 Host：RC<h> ── EP<h>）── pcie_dpu_cfg_adapter ── pcie_tl_env（TLM）
驱动 BAR 写  → RC<h> MemWr（BAR0 + 偏移）→ EP<h> → 队列 → 快照解码 → rdma_dev.write_register
设备 DMA     → EP<h> MemRd/MemWr（requester = Function BDF，≤512/256B，不跨 4KB）→ RC<h> → Host<h> host_mem
```

RC 的统一内存是绑定到该 Root 的 Host host_mem manager；没有 IOMMU，驱动分配用恒等 IOVA adapter。

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
- **可靠传输**：PSN 序列 NAK 从 NAK 指出的 PSN 起重发（READ 从第一个缺失的响应起只请求剩余部分），
  超时时 SEND/WRITE 从首 PSN、READ 从缺失处重发，两者消耗 PSN_RETRY_TH（耗尽 0x16/0x18）。RNR NAK
  的 syndrome 低 5 位为响应方 QPC LOCAL_RNR_CODE，请求方按 IB RNR 定时器表等待后从首 PSN 重发，消耗
  RNR_RETRY_TH（7 无限，耗尽 0xB7；URC 用 urc_rnr_code=8）。其余 NAK 致命（0xB9）。
  响应方：PSN 早于期望为重复请求（重发 ACK、重放 READ、回缓存的 ATOMIC 原值，不再执行），晚于期望
  回一次 PSN 序列 NAK；无 RQE 回 RNR NAK 且不推进期望 PSN。
- **URC 异常**：请求方致命错误或接收侧长度错误时设备写 ABNML CEQE（类型 SQ/RQ、ecode、远端 syndrome、
  异常 WQE 位置）并停止该 SQ；设备开关 `urc_abnormal_via_aeq` 改为写 URC AEQE，驱动处理 AEQ 时记入
  同一信息区并把 QP 转 ERR。轮询时异常位置前的 WQE 报异常完成，其后 FLUSH。
- **完成**：设备按 CQC 写 32B CQE（polarity），CQ armed 时写 CEQE；驱动 `poll_cq` 按 WQE_INDEX
  回查 wr_id 并更新 shadow CI。

## 3. 验收

- core：`rdma_drv_data_test`（两节点、逐项操作与 CQ arm 事件）、`rdma_tb_flow_test`（mock host_mem，
  loopback wire，完整流量序列）。
- e2e：`rdma_tb_e2e_test`：真实 host_mem + net_packet RoCEv2 帧编解码 wire，同一组 sequence。
- 传输矩阵：RC/UD/URC（qp_index 0/1/2；URC 在 rc_to_urc 下创建，用专属 CQ 的 frag，完成经 CEQE
  的 HW_CPL 上报，monitor 每轮先处理 CEQ）。状态：两项均通过（33 项检查零错误）。
- 高流量：`rdma_tb_e2e_high_traffic_test`（4096 个 SEND，整窗填满 256 深 SQ/RQ，4114 项检查）。
- 可靠性：`rdma_drv_reliability_test`（中间包丢失从 NAK PSN 重传、ACK/ATOMIC ACK 丢失的重复处理、
  READ 只重请求缺失段、RNR 按定时器编码重试与耗尽、UD Q_Key/GRH、SRQ SGB、URC SQ/RQ 异常完成经 CEQE
  与 AEQE）；`rdma_multifunc_test` 的丢包项改为
  “丢一包重传成功 + 持续丢包重试耗尽 0x16”。
- QP 生命周期：`rdma_drv_qp_lifecycle_test`（RTS→SQD 等 AEQE、doorbell 状态不符、RESET/INIT 接收丢包、
  销毁重建与编号复用）；multifunc 按快照范围做 Function/PF/Host 复位。
- PCIe：`rdma_pcie_rdma_test`（pcie_work suite）：Host0 PF0/VF1 与 Host1 PF0 经 PCIe 完成 probe 与
  SEND/WRITE，检查 MMIO TLP 解码数、DMA TLP 发出/送达数、各 Function 的 requester BDF、MAILBOX 拒绝。

## 4. 后续

接入 DUT。假设：硬件何时用 AEQE、何时用 CEQE 上报 URC 异常未知（设备开关二选一）；响应超时由
QPC RTO_CODE 换算，硬件编码表未公开，取驱动 xtrdma_rto_code_map（IB timeout → 编码）的逆（31 为
不超时，URC 固定 urc_rto_code=0x12）；SEND/WRITE 超时从首 PSN 重发（响应方只对末包 ACK，请求方无从得知
已收到的部分）。
