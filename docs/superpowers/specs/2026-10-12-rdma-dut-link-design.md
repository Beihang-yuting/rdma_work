# rdma-dut-link 设计规范

## 1. 目标与范围

本设计为 RDMA 验证环境增加 `rdma_dut_link`，把“模型对端与真实 DUT 之间的网络帧边界”从当前的语义 loopback 中独立出来。

第一阶段只解决网络数据面的边界，不伪造 DUT 的控制面或主机内存：

- 保留 `rdma_link` 作为模型到模型的快速 loopback；
- 保留 `rdma_link_netpkt` 作为模型内部 RoCEv2 编解码回归；
- 新增 `rdma_dut_link`，让模型 peer 生成的 `rdma_packet` 经 codec 编码后送给 DUT RX，让 DUT TX 原始帧经 monitor 解码后发布给 checker、scoreboard 和 coverage；
- 通过稳定的 frame endpoint 抽象接入 TAP、VPI/VHPI、PCIe/网卡 VIP 或厂商网络 BFM，不把任何外部组件实现写进 RDMA 核心；
- 不在本阶段扩展所有 RDMA opcode、VLAN、IPv6 或隧道格式。它们仍由后续 codec/packet-model 工作单独补齐。

真实 DUT 的控制面（CMQ/MMIO/PCIe）、Host memory/DMA 和 CQE/AEQ 仍由现有 driver、memory model 和 scoreboard 管理；`rdma_dut_link` 只拥有网络边界适配状态。

## 2. 模式与职责边界

环境通过 `rdma_env_cfg.link_type` 选择链路 backend：

| 模式 | backend | 传输对象 | 适用场景 |
| --- | --- | --- | --- |
| `MODEL_LOOPBACK` | `rdma_link` | `rdma_packet` | 快速语义回归、故障注入 |
| `MODEL_NETPKT` | `rdma_link_netpkt` | 编码后再解码的 RoCEv2 frame | codec 回归 |
| `DUT_MODEL_PEER` | `rdma_dut_link` | peer→DUT 为 raw frame，DUT→peer 为 raw frame | 真实 DUT + 模型对端 |

`rdma_dut_link` 不得调用基类 `rdma_link::deliver()` 把 DUT 伪装成 `funcs[dst].node.dev.nic`。模型 peer 的目的 MAC 命中 DUT 时直接调用 frame endpoint；DUT TX 到达时只交给 endpoint/monitor 和分析端口，不再二次投递给模型 NIC。模型 peer Function 之间的内部流量仍可委托基类 loopback。

## 3. 组件接口

### 3.1 `rdma_dut_frame_endpoint`

在 `src/tb/rdma_dut_link.sv` 定义一个虚拟 UVM 对象，作为外部网络组件的最小契约。endpoint 不拥有 DUT 或外部网络的生命周期，具体插件负责打开、关闭和 reset。

契约包含：

```text
send_to_dut(port, frame, status)
poll_from_dut(port, frame, status)
start/stop 生命周期钩子
```

- `send_to_dut` 将一帧原始 Ethernet 字节同步或异步注入 DUT RX；返回非 OK 时链路报告发送失败且不发布 RX 观测。
- `poll_from_dut` 阻塞或轮询获取一帧 DUT TX；无帧时由 endpoint 自己等待，正常停止返回可识别的关闭状态。
- endpoint 不解析 RDMA opcode，不修改 frame 字节，不重新计算 ICRC；所有协议解析留给 `rdma_netpkt_codec`。
- endpoint 的实现可以使用 DPI、virtual interface、TAP 或外部 VIP，但这些实现不能反向修改 `rdma_dev_nic` 或 `rdma_link` 核心。

第一阶段提供一个 memory endpoint test double，用于不连接真实 DUT 的单元测试；不提供生产环境的 TAP/厂商 BFM 实现。

### 3.2 `rdma_dut_link`

`rdma_dut_link` 继承 `rdma_link`，复用：

- `rdma_link_obs`、`tx_ap`、`rx_ap`；
- `rdma_link_fault` 的规则对象与 report 统计；
- 模型 Function 的 `attach()` 和 `rdma_dev_port` 语义出口；
- codec 的 encode/decode 和已有 checker/coverage 连接。

新增状态：

- DUT endpoint 非拥有引用；
- DUT 网络端口号；
- DUT MAC 与可选 peer MAC 路由映射；
- 独立 codec 实例；
- 运行/停止标志与接收线程句柄；
- 统计计数：注入帧、捕获帧、decode 失败、endpoint 错误和故障丢弃。

新增行为：

1. `bind_endpoint(endpoint, dut_port, dut_mac)` 在 start 前绑定一次 endpoint；重复绑定、空 endpoint 或与已登记 Function MAC 冲突时报配置错误。
2. 模型 NIC 发往 `dut_mac` 的 `rdma_packet` 先经过故障规则，再由 codec 编码，并调用 `send_to_dut`。成功发送发布 TX 侧的 semantic/frame 观测；失败只报告错误，不伪造 DUT RX 事件。
3. 模型 NIC 发往已 attach Function 的报文继续使用基类 loopback；发往未知 MAC 仍拒绝。
4. `run_phase` 启动接收循环，调用 `poll_from_dut` 获取原始帧；成功 decode 后构造 `rdma_link_obs`，保存原始 frame 并发布 `rx_ap`。第一阶段不把该帧自动送入模型 NIC，避免 DUT TX 被模型重复消费；如果需要模型 peer 响应，由独立 peer adapter 根据观测显式调用 peer NIC。
5. decode/ICRC/endpoint 失败计数并报告，原始 frame 保留在故障诊断日志中；不向现有 checker 发送 `pkt == null` 的观测，避免破坏当前 checker 的非空契约。
6. `stop` 或 phase 结束时先停止接收循环，再调用 endpoint 的 stop/close 钩子；重复停止必须幂等。

## 4. 数据流

### 4.1 peer → DUT

```text
peer rdma_dev_nic
    → rdma_dut_port.send(packet, dut_mac)
    → rdma_dut_link encode
    → frame fault policy
    → endpoint.send_to_dut()
    → DUT RX
```

### 4.2 DUT → peer/scoreboard

```text
DUT TX
    → endpoint.poll_from_dut()
    → rdma_dut_link decode
    → rdma_link_obs{pkt, frame, src, dst}
    → rx_ap
    → protocol checker / coverage / scoreboard adapter
```

原始 DUT TX frame 必须在 decode 前复制保存。scoreboard 比较 wire 行为时使用原始 frame，语义预测使用 decode 后的 `rdma_packet`；不能用重新 encode 的 frame 替换 DUT 原始 frame。

## 5. 配置与环境集成

`rdma_env_cfg` 增加 DUT link 配置引用或插件注入钩子，但不把 endpoint 类型硬编码到 env：

- `link_type = "rdma_dut_link"` 只选择 UVM factory 类型；
- `rdma_dut_link` 在 `build_phase` 检查 endpoint 是否由插件/config DB 提供；缺失时 fatal；
- `rdma_env.run_phase` 对模型 Function 仍执行 `attach()`；真实 DUT 不作为 `rdma_res_func.node.dev.nic` attach；
- 插件在 `pre_build/build/start/report` 管理 endpoint 的创建、外部句柄、reset epoch 和关闭；
- `rdma_dut_link` 只读取已冻结的 Function/MAC 路由信息，不创建或改写 dpu_common topology。

建议的配置路径为：

```text
cfg.link_type = "rdma_dut_link"
cfg.dut_link_plugin = <external adapter plugin>
plugin.bind_endpoint(env.link, endpoint, dut_port, dut_mac)
```

若外部 VIP 已经完全管理网络路由，后续可以不实例化 `rdma_dut_link`，但必须发布等价的 `rdma_link_obs`/原始 frame 事件；本规范的 checker、coverage 和 scoreboard 不直接依赖具体 link 类。

## 6. 错误、并发与所有权

- endpoint 发送失败、接收关闭、frame 过短、非 RoCEv2、ICRC 错误和 codec 不支持组合都必须带状态码报告；失败帧不得进入模型 NIC。
- DUT TX 接收循环与 peer TX 发送可以并行；每个观测必须拥有自己的 frame 副本，不复用 `rdma_link_netpkt` 的单一 `carried` 队列。
- endpoint 和 DUT 外部资源由插件拥有；link 只保存非拥有引用，reset/epoch 由插件验证后再允许收发。
- 故障注入按方向区分：模型→DUT 的 frame 注入在 endpoint 发送前生效；DUT→模型 的丢包/损坏由 endpoint 或接收循环在 decode 前生效；不能把 DUT 已捕获的原始帧静默替换成模型副本。
- report 阶段检查未应用完的故障规则、未关闭的接收循环、endpoint 错误计数和残留未消费 frame。

## 7. 验证范围

第一阶段新增以下测试：

1. memory endpoint 将模型 peer 的 RC SEND frame 收到并验证字节不被 link 修改；
2. memory endpoint 注入合法 RoCEv2 frame，`rdma_dut_link` decode 后发布 `rx_ap`，checker 能看到正确 QPN/PSN/opcode/payload；
3. encode/decode/ICRC 失败时只报告错误，不向 `rdma_proto_checker` 发送空 packet；
4. 模型 Function→模型 Function 仍走基类 loopback，现有场景不改变；
5. DUT TX 与 peer TX 并发时每个 `rdma_link_obs.frame` 独立，不能出现上一帧覆盖；
6. endpoint 未绑定、重复绑定、DUT MAC 冲突和重复 stop 均按规定处理；
7. `link_type` 选择 `rdma_dut_link` 时 env factory 能创建该类型，默认 `rdma_link` 测试不受影响。

真实 VCS DUT 仿真、TAP/VPI/DPI 和 PCIe/Host-memory 对接不在第一阶段单元测试中实现，待 endpoint 契约稳定后分别增加适配器测试。

## 8. 非目标与后续扩展

- 本设计不把 `rdma_dut_link` 变成完整交换机，不实现 VLAN/FWD/IP 路由、重传、拥塞或 QP 状态机。
- 本设计不把 `SEND_WITH_INV`、IPv6、VXLAN/GRE、VLAN 等缺失 wire 语义偷偷映射成 SEND；它们需要扩展 `rdma_packet`、codec、NIC 行为和 checker/coverage。
- 本设计不改变 CMQ、QP、MR、PBL、CQ、AEQ/CEQ 的资源所有权；真实 DUT 控制面使用独立 driver/backend。

