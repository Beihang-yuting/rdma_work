# RDMA UVM 验证流程设计（seq → 报文 → 内存）

日期：2026-10-05。分支：`feature/rdma-arch-slim`。范围：P1–P4（verb agent、NIC 行为模型、
记分板、MTU 分段与 WRITE/READ/ATOMIC）。当前没有 RTL DUT，NIC 行为模型先作为“设备”，
接入 DUT 后退为预测器。

## 1. 现状问题

- 仓库只有 host 侧驱动模型（WQE 写入、doorbell、CQ 消费）和报文编解码，没有设备侧：
  E2E 测试手工构造报文、手工把 payload 写进接收 buffer、手工发布 CQE。
- 没有 sequence/driver/monitor/scoreboard；`rdma_env` 只是 engine 容器。
- `rdma_packet` 只有 opcode/QPN/PSN/payload，扩展头只是原始 `header_bytes`，也没有
  FIRST/MIDDLE/LAST 分段语义。

## 2. 目标结构

```
test
 └ rdma_tb_env (uvm_env)
    ├ rdma_verb_agent[n]   seq → rdma_verb_item → driver → queue_data_engine.post_send/post_recv
    │                      monitor：poll CQ → rdma_verb_completion → analysis
    ├ rdma_nic_model[n]    TX：SQ PI 变化 → 读 SQE(host_mem) → 解码 → MR 转换 → DMA 读
    │                          → 按 MTU 分段 → wire；RC 等 ACK/READ 响应/ATOMIC ACK 后发布 SQ CQE
    │                      RX：wire → QPN→QP → SEND 取 RQE / WRITE 按 RETH / READ 回读 /
    │                          ATOMIC 读改写 → DMA 写 → 发布 RQ CQE、回 ACK/NAK
    ├ rdma_wire            点到点交付报文；analysis 端口观测全部报文；可替换为经 net_packet
    │                      帧编解码的实现（E2E）
    └ rdma_tb_scoreboard   影子内存预测（SEND/WRITE/READ/ATOMIC）+ 完成比对（wr_id/status/len）
```

新代码放在 `src/tb`（`rdma_tb_pkg`），只依赖 core/model/adapter 抽象接口；net_packet 等外部
实现只在测试侧通过 wire 子类接入。

## 3. 关键约定

- **节点配置** `rdma_tb_node_cfg`：engine、resource manager、host_mem、Function owner、
  QP 列表与连接表（本地 QP → 对端节点/QP）、CQ、数据 MR（含 backing mapping）、MTU。
  节点资源仍由测试/fixture 创建（Function/PD/CQ/QP/MR），tb 组件只借用句柄。
- **WQE 读取**：SQE/RQE 均为 64B，地址 = `qp_plan.sq_ref/rq_ref.mapping` +
  `mapping_offset + index*64`；用 codec registry 解码（SQE variant rc/ud/urc，RQE default）。
  SQ 超过 2 个 SGE 或 UD 非零 payload 走外部 SGB：driver 把 `sgb_iova` 设为当前 SQ PI × 512B 槽，
  NIC 读该槽并按 16B 大端描述符（length/lkey/iova）解析。UD/URC SQE codec 不支持仅凭 64B 镜像
  解码：URC 与 RC 同布局，用 RC codec；UD 由 `rdma_tb_dma` 按 `rdma_defs.svh` 字段直接解析。
  RQ 外部 SGB 目前 engine 本身不支持（post_recv 无 SGB backing，>2 SGE 的 RQE 无法编码），RECV 限 2 个 SGE。
- **地址转换**：key 高 24 位为 MR local ID，经 `lookup_local_resource(owner, MR, id)`
  取 MR，校验低 8 位 key、范围与访问权限，DMA 偏移 = va − backing mapping.iova。
- **报文**：`rdma_packet` 增加 segment（ONLY/FIRST/MIDDLE/LAST）和结构化扩展头
  （RETH、AETH、ImmDt、AtomicETH、AtomicAckETH），`pack_headers()/unpack_headers()`
  与 `header_bytes` 互转，net_packet adapter 只负责 BTH opcode 与字节搬运。
- **PSN/ACK**：每 QP 维护 send PSN 与 expected PSN；RC 每条消息最后一个包后回 ACK，
  READ 以 READ RESPONSE FIRST/MIDDLE/LAST/ONLY 返回，ATOMIC 以 ATOMIC ACK 返回原值。
  key/范围/权限错误时回 NAK（remote access error），请求方 CQE 带错误 ecode。
- **CQE**：沿用 `queue_data_engine.publish_cqe`（设备侧生产者接口），polarity 取自
  `query_runtime_producer_polarity`。

## 4. 验收

- core suite 新增 `rdma_tb_flow_test`：两节点、mock host_mem、loopback wire，跑
  SEND/RECV（含跨 MTU 多包）、WRITE(+IMM)、READ、CMP_SWAP、FETCH_ADD 与 rkey 错误场景，
  记分板零错误且内存逐字节一致。
- e2e suite 新增 `rdma_tb_e2e_test`：真实 host_mem + net_packet 帧编解码 wire，同一组 sequence。

- 传输矩阵：每节点 RC/UD/URC 三个 QP（qp_index 0/1/2）。URC 发出即完成，UD 单包且 RQ CQE 用 RQ/SRFQ
  overlay（engine 约束，不携带源 QPN），接收 buffer 不预留 GRH。

状态：两项均已通过（31 项检查零错误）。

## 5. 后续

RQ 外部 SGB（需先补 engine）、UD GRH/Q_Key 校验、PSN 乱序重传、RNR 重试、AEQE 错误上报、接入 DUT（NIC 模型退为预测器）。
