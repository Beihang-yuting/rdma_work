# RDMA 0.1.34 主要缺口与 net_packet 数据面集成设计

## 目标

本设计用于补齐当前 RDMA UVM driver 对 0.1.34 驱动的主要语义缺口，并把
`net_packet` 作为可选的真实网络报文生成/解析组件接入 RC、UD、URC 数据面。
实现结果必须能够在多 Host、多 PF、VF、PCIe、host-mem 和 AXIS 环境下保持
Function/authority/generation 隔离，同时不把外部组件耦合进 RDMA core。

## 依赖版本与边界

- `dpu_common` 继续作为 Host、PF/VF、BDF、BAR、global Function ID 和 topology
  的唯一权威；RDMA 只消费其不可变 snapshot。
- `net_packet` 使用 GitHub `main` 当前固定提交
  `e2af70204f53ede65e366c7a65f695c59acdbbc5`。依赖目录由仿真环境提供，不能把
  外部源码复制进本仓库或在 core package 中直接 import 外部 package。
- 外部 PCIe、host-mem、AXIS VIP 和 net_packet 的对象生命周期仍由各自环境管理。
  RDMA adapter 只保存非拥有引用，并在每次发送/接收前验证 function UID、generation
  和 reset epoch。
- 普通 SystemVerilog 源文件与测试使用 `.sv`；`.svh` 仅保留宏和必须文本包含的固定
  mask。新增文件入口、类、模块、task、function 和关键状态迁移均使用中文设计注释。

## 现状与问题

当前仓库已有 `rdma_packet` 语义对象和抽象 `rdma_net_api`，但没有真实
`net_packet` adapter、net_packet filelist 或 net_packet 仿真 target；现有网络测试
使用 `rdma_mock_net`。因此 `NET_PACKET_ROOT` 虽可由 `run_vcs53.sh` 传递，实际上
不能驱动 RDMA 数据面。

0.1.34 对比还暴露以下缺口：

1. QPC 缺少 `load_rq_pi_th`、RNR/RTO、运行态 flush/CC/shadow 的完整编解码，
   forwarding mode 的 2-bit 语义被错误压成 boolean。
2. CQE 固定 64B，缺少 32B/128B、header offset、resize、shared CQ、URC shadow/flush。
3. UD/URC SQE 仍为空壳，SEND_WITH_INV、REG_MR、BIND_MW、FLUSH、transport 校验和
   512B FWQE-SGB 行为不完整。
4. CMQ registry 缺少 0.1.34 新增 MW、key query、SD、source-address、stat、
   force-delete、IDX_OCC、IFA、kickout 等 opcode。
5. 用户态 ABI v5 缺少版本协商、context alloc、DB/QP/CQ/SRQ/shadow/FWQE-SGB mmap
   和 ucontext/udata 生命周期。
6. host-mem 缺少 UMEM/page pin/refcount、多级 PBL、MW 和真实用户 buffer 映射生命周期。

## 总体架构

```text
                       dpu_common snapshot
                    (Host/PF/VF/BDF/BAR/topology)
                                  │
                                  ▼
                    rdma_function_context / routing
                                  │
        ┌─────────────────────────┼─────────────────────────┐
        ▼                         ▼                         ▼
  control plane              queue engines               net adapter
  CMQ/QPC/CQ/ABI        SQ/RQ/CQ ring + host-mem      rdma_net_packet_adapter
        │                         │                         │
        ▼                         ▼                         ▼
  PCIe/doorbell             DMA/IOVA/PBL             net_packet::packet
                                                            │
                                                            ▼
                                                  AXIS VIP / DUT / PCAP
```

### 数据面报文适配

`rdma_net_packet_adapter` 位于 `src/adapters/net_packet`，实现 `rdma_net_api`，
但不创建 `axis_env`、`pcie_env` 或 `host_mem` 对象。发送流程如下：

1. 上层根据 QP snapshot、transport、opcode、PSN、QPN、payload 和 Function snapshot
   构造 `rdma_packet`。
2. adapter 将 `rdma_packet.header_bytes/payload` 转换成 net_packet `packet`：
   RC/UC/UD 使用 RoCEv2 BTH/RETH/AETH/DETH/IETH；iWARP 使用 iWARP header；
   Ethernet/IP/UDP 头由模板或显式字段提供。
3. adapter 调用 net_packet `do_pack()`，检查最小帧长、header length、checksum/ICRC
   和 transport/QPN/PSN 一致性，再通过注入的发送 sink 发布。
4. 接收 sink 返回 net_packet `packet` 后，adapter 解析并转换为 `rdma_packet`，
   保留原始 bytes、协议元数据和 Function/epoch 证据，交给 `receive_packet()`。

adapter 只负责值转换、边界检查和发送/接收计数；队列 PI/CI、CQE 生成和 host-mem
所有权仍由 RDMA queue engine 管理。

### 多 Host/PF/VF 路由

每个 adapter 实例绑定一份 `dpu_common` Function snapshot。发送和接收都必须验证：

- `function_uid`、PF/VF 类型、VF ID、BDF 和 port；
- snapshot generation 与当前 `rdma_function_context` generation 相同；
- reset epoch 没有变化；
- QP/CQ/host-mem handle 的 authority 与报文所属 Function 一致。

任何不匹配都返回明确的 `RDMA_SC_STALE_HANDLE` 或 `RDMA_SC_ROUTE_ERROR`，不得发送
部分报文、推进 PI/CI 或修改 CQ shadow。

## 分阶段交付

### 阶段 0：回归分层

将 `run_queue_lifecycle_regression53.sh` 中 integration-only 测试从 core 列表移出，
修复 `sim/Makefile` 的 suite/target 对齐，并为 net_packet/axis_vip 增加显式依赖检查。

### 阶段 1：CQE 与 CQ 生命周期

引入 32/64/128B CQE profile、header offset 和长度校验；扩展 CQ resize、shared CQ、
URC CQ shadow/flush、owner/polarity/wrap 处理。所有 CQE codec 通过 golden vectors 和
非法长度/保留位测试。

### 阶段 2：SQE/WQE 与数据面语义

完成 UD/URC SQE codec 和 transport 校验；补齐 SEND_WITH_INV、REG_MR、BIND_MW、FLUSH
以及 direct/inline/SGB/512B FWQE-SGB 行为。每种 WQE 都验证 payload、host-mem 映射、
doorbell 和 CQE 结果的端到端关联。

### 阶段 3：net_packet 报文生成器适配

新增 `rdma_net_packet_adapter`、`sim/filelists/net_packet.f`、Makefile target 和
`rdma_net_packet_adapter_test`。先覆盖 RoCEv2 RC SEND/WRITE/READ/ACK，再覆盖 UD/URC、
iWARP、SEND_WITH_INV、ICRC/checksum、报文 drop/corrupt/delay 故障策略；接收方向使用
net_packet parser/comparator 和 PCAP writer 形成可复现证据。

### 阶段 4：ABI v5 与 host-mem

增加 ABI version negotiation、context alloc req/resp、8 KiB doorbell mmap、QP/CQ/SRQ/
shadow/FWQE-SGB mmap descriptor 和生命周期 refcount。host-mem 增加 UMEM pin/refcount、
多级 PBL、用户 buffer 映射和 MW 绑定/失效；所有 mapping 失败按 acquisition 逆序回滚。

### 阶段 5：CMQ 与 0.1.34 基线

扩展 opcode enum/profile/registry，覆盖驱动新增命令；更新 source manifest、golden
vectors 和 0.1.34 SHA-256 checker，最后执行 core、integration、host_mem、net_packet、
axis_vip 全量回归。

## 错误与恢复模型

- adapter、queue engine 和 ABI adapter 都采用“先验证、后提交”策略；验证失败不推进
  游标、不写 CQE、不释放借用资源。
- 发送中 reset/generation 变化时，当前事务标记 stale，保留原始 packet 和 ticket，
  由恢复协调器执行 queue flush/delete；不自动重放可能产生重复报文的事务。
- host-mem owned mapping exactly-once release；borrowed mapping 永不由 RDMA adapter
  release。net_packet packet 对象只保存值快照，不转移外部对象所有权。
- drop/corrupt/delay 仅允许通过显式 `rdma_net_fault` 注入，并记录 fault kind、
  packet sequence、Function snapshot 和 reset epoch。

## 验证策略

每个阶段严格遵循 TDD：先提交一个能够证明缺口存在的失败测试，再实现最小行为，最后
在 53 的 login bash 环境中编译和执行。最小验证矩阵如下：

| 层次 | 关键证据 |
| --- | --- |
| codec | 0.1.34 golden bytes、端序、保留位、非法长度/枚举 |
| queue | PI/CI、credit/doorbell、owner/wrap、reset recovery |
| host-mem | IOVA/PBL/page pin/refcount、owned/borrowed 生命周期 |
| net_packet | RoCE/iWARP pack/unpack、checksum/ICRC、parser/comparator、PCAP |
| routing | 多 Host/PF/VF、BDF/port、stale generation、reset epoch |
| integration | PCIe/host-mem/AXIS/DUT 端到端事务和 UVM error/fatal 为 0 |

所有 VCS 仿真命令通过 `scripts/run_vcs53.sh` 在 `10.11.10.53` 执行；本机只做静态
检查和不依赖外部 VIP 的单元测试。

## 非目标

- 不修改 `net_packet`、`pcie_work`、`host_mem`、`axis_vip` 或 `dpu_common` 外部仓库。
- 不把 net_packet 的协议类直接 import 到 `src/core`；core 只依赖抽象 `rdma_net_api`。
- 本轮不实现真实 NIC/线速调度器，net_packet 只作为验证报文生成/解析器和可注入 sink。
- 不在没有驱动 ABI/golden evidence 时猜测未定义寄存器字段；未知字段保持显式保留位和
  `UNSUPPORTED` 错误。
