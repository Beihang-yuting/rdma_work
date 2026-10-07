# RDMA UVM env 改造方案（S1–S5）

日期：2026-10-07。分支：`feature/rdma-arch-slim`。
目标：把散在各测试里的过程式代码收进一套 UVM env：配置决定拓扑与传输，序列产生激励，资源库管理对象，
scoreboard/checker/coverage 负责判定与统计；测试只选配置与虚拟序列。代码精简易读，功能覆盖现有全部测试。

## 1. 结构

```
rdma_base_test ── rdma_env_cfg + vseq
 └ rdma_env
    ├ cfg        rdma_env_cfg：拓扑（dpu_common Host/PF/VF）、链路类型、内存、QP 默认值、检查开关、偏差清单
    ├ sys        rdma_dpu_system：快照 → 每个 Function 的 内存 + 设备 + 驱动；FLR/恢复
    ├ res        rdma_res_db：全部对象（见第 2 节），控制面 driver 是唯一写入者
    ├ ctrl       rdma_ctrl_agent：控制面（资源生命周期、QP 连接/状态迁移、FLR/恢复），全部 Function 共用一个
    ├ verb[f]    rdma_verb_agent：数据面（post_send/recv、SRQ recv、poll CQ/EQ）
    ├ link       rdma_link（本身即 loopback）及子类 rdma_link_netpkt | rxe，factory 按名字创建；tx/rx analysis、故障注入
    ├ plugins    rdma_env_plugin：传输相关扩展（pcie_work 承载 MMIO/DMA、rxe 远端 Function）
    ├ sb         rdma_scoreboard = rdma_mem_model（期望内存）+ rdma_expect（每 QP 期望完成）
    ├ checker    rdma_proto_checker + rdma_proto_rule 子类（每组 IBTA 规则一个类）
    ├ cov        rdma_coverage（每个覆盖面一个 covergroup）
    └ vseqr      rdma_vsequencer（持有全部子 sequencer 与 env 句柄）
```

## 2. 资源层（每类对象一个类，三层管理）

```
rdma_res_db ── funcs[uid] : rdma_res_func（每个 Function 一个；rxe 远端为 REMOTE）
                 ├ cmq、aeq、ceqs : 设备级队列（probe 时登记）
                 ├ pds/bufs/mrs/cqs/srqs/qps : rdma_res_pool #(T)
               └ ap : rdma_res_event（CREATED / STATE / DESTROYED）
```

- `rdma_res`（基类）：kind、uid（全局唯一）、owner、state（ALIVE/ERROR/DESTROYED）、generation（编号复用区分新旧）、
  deps（QP→PD/CQ/SRQ，MR→PD/BUF，CQ→CEQ）。
- 子类只持有驱动对象句柄 + 验证需要的元数据，不复制驱动状态：

| 类 | 驱动对象 | 验证元数据 |
| --- | --- | --- |
| `rdma_res_cmq` | `rdma_drv_cmq` | —（opcode/ecode 进覆盖率） |
| `rdma_res_eq` | `rdma_drv_eq` | CEQ/AEQ、深度；monitor 按它轮询 CEQ 与 AEQ（异步事件：QP 错误、SRQ limit、CQ 溢出等） |
| `rdma_res_pd` | `rdma_drv_pd` | — |
| `rdma_res_buf` | `rdma_drv_dma` | iova/size；`read/write`（仿真经驱动 hw，rxe 经对端进程，子类实现） |
| `rdma_res_mr` | `rdma_drv_mr` | buf、VA 范围、权限、key；`covers(va, len, right)` |
| `rdma_res_cq` | `rdma_drv_cq` | 深度 |
| `rdma_res_srq` | `rdma_drv_srq` | — |
| `rdma_res_qp` | `rdma_drv_qp` | 类型、状态镜像、对端 QP、send/recv CQ、SRQ、Q_Key、MTU |

- `rdma_res_pool #(T)`：编号 → 对象；add（编号冲突报错）、get、remove（仍被依赖报错）、all。
- `rdma_res_db`：跨 Function 查询（`qp(func, qpn)`、`mr_by_key`）、销毁顺序检查、`on_flr(scope)` 整组置
  DESTROYED 并广播事件。
- 设备级队列由驱动 probe 创建，env 在 probe 后登记、FLR/remove 时失效；SQ/RQ 是 QP 的一部分，不单列；
  驱动内部对象（HMC、PBLE、位图）不登记。
- 边界：在途 WR 属于“期望”，放 scoreboard（按 QP uid），不放资源类。

## 3. 组件

- **rdma_env_cfg**：一个类，字段分组（拓扑、链路、内存、QP 默认、检查）；不再拆成多个子配置类。
- **rdma_ctrl_agent**（一个，item 带 Function 下标；FLR 范围跨 Function，控制命令本就串行）：item
  `rdma_ctrl_item`（op：ALLOC_PD/ALLOC_BUF/REG_MR/CREATE_CQ/CREATE_SRQ/CREATE_QP/CONNECT/MODIFY_QP/DESTROY/
  FLR/RECOVER；属性；expect_fail）。driver 调用 `rdma_drv_*`，结果写资源库；资源库的 analysis 端口即控制面
  事件流（不另设 monitor）。命令进行中 monitor 暂停取 AEQ（驱动内部等待如 RTS2SQD 自己取）。
- **rdma_verb_agent**：item 增加 QP/MR 句柄、显式 SGE 列表、SRQ 接收、数据模式（见第 5 节）、期望完成状态；
  monitor 模拟中断处理：该 Function 全部 CEQ、AEQ、全部 CQ；上报 wc 状态/vendor/src_qp 与 AEQ 事件。
- **rdma_link**：基类提供 `port(func)`、`tx_ap/rx_ap`、`drop/corrupt/delay(dir, nth)`；loopback 与 netpkt 在
  tb 包内，rxe 在 rxe 包内（工厂按名字创建，tb 不依赖 rxe 包）。
- **rdma_env_plugin**：钩子 `pre_build(env)`、`build(env)`、`start(env)`、`report(env)`。
  - `rdma_pcie_plugin`（tests/rdma_env_test_pkg，需 host_mem 工厂）：安装 BAR/DMA 覆盖、按快照建 PCIe 系统、
    结束时检查 MMIO/DMA TLP 计数、每个 BDF 都发过 DMA、MAILBOX 写被拒绝。
  - `rdma_rxe_plugin`（src/adapters/rxe/rdma_rxe_env.sv）：远端 Function（`cfg.remote_funcs`，下标在 dpu
    Function 之后）由 rxe_peer 进程承载；覆盖 ctrl/verb driver 与 monitor，远端资源/投递/完成经对端命令，
    缓冲为 `rdma_rxe_buf`（rbuf/wbuf 分块）；链路 `rdma_link_rxe`（TAP）。对端限制：单 PD/CQ/MR/SRQ、单 SGE、
    无 URC；Q_Key 用非受控值；仿真侧 QP 不设响应超时。
- **链路故障注入**：`rdma_link_fault`（DROP/DUP/DELAY/CORRUPT，按源 Function/opcode 过滤、skip/count）；
  CORRUPT 在 netpkt 链路上翻转帧字节并要求接收端 ICRC 校验拒绝，loopback 上等同丢弃。
- **rdma_scoreboard**：拆为 `rdma_mem_model`（每个 buf 的期望字节，写入/读取/原子/GRH）与 `rdma_expect`（每 QP
  的期望完成队列：成功/错误码/flush/SRQ 顺序/UD）；scoreboard 只负责接事件与比对。错误预测依据资源库
  （rkey、权限、越界、接收容量、Q_Key），错误后预测 QP 进入 ERR、其后 WR 为 FLUSH；FLR 撤销范围内期望。
- **rdma_proto_checker**：按 QP 维护 PSN/在途/MSN 状态；规则类 `rdma_rule_frame`（ICRC/pad/UDP/TVer/P_Key）、
  `rdma_rule_psn`（连续、重传起点、READ 只重读缺失段）、`rdma_rule_ack`（AckReq、ACK/NAK 范围、MSN、NAK 码）、
  `rdma_rule_rnr`（定时器编码、重试间隔）、`rdma_rule_state`（非 RTS/RTR 不收发、SQD 不发新 SQE）、
  `rdma_rule_ud`（DETH、Q_Key）。偏差清单按规则名降级为 info。
- **rdma_coverage**：verb（op × 链路 × 长度区间 × SGE 数 × imm × QP 类型 × 数据模式）、error、qp_state、
  link_fault、function（PF/VF × 复位范围 × 在途流量）、cmq（opcode × ecode）。
- **序列**：`rdma_base_vseq`（取资源、发 ctrl/verb、等待）＋每个场景一个 vseq：basic_traffic、ud、srq、
  qp_lifecycle、reliability、errors、multifunc、high_traffic、random。

## 4. 拆分审查结论

| 部分 | 结论 |
| --- | --- |
| 资源 | 每类对象一个类 + 通用池 + 按 Function 分组（第 2 节） |
| scoreboard | 拆：期望内存 / 期望完成 / 比对三部分，各自可读可测 |
| 协议检查 | 拆：每组 IBTA 规则一个类，独立开关与偏差降级 |
| 链路 | 拆：每种传输一个子类；PCIe 不是链路，作为插件 |
| 序列 | 拆：每个场景一个 vseq，公共动作在 base vseq |
| 覆盖率 | 一个 subscriber，内部按覆盖面分 covergroup（不再细拆类） |
| 配置 | 不拆：一个配置类，字段分组即可 |
| verb item | 不拆：RC/UD/atomic 共用一个 item，字段按用途分组 |
| 驱动/设备模型 | 不在本次范围（已按对象分类） |

## 5. net_packet 生成数据

`rdma_data_gen` 用 net_packet 的负载引擎生成源数据：空层栈的 `packet`，`payload_mode` = RANDOM/FIXED/
INCREMENT/PATTERN，`pkt_len` = 长度，`do_pack()` 后 `raw_data` 即负载。

- verb item 只写数据规格（模式、固定值或样式、长度），driver 生成字节、写入源内存并在 item 上保留原始数据。
- scoreboard 记录“目的区域 ← 原始数据”：完成时立即读目的内存与原始数据比对（定位到具体 WR），结束时再整块
  比对一次（发现越界写）。
- rxe 远端的源数据同样由它生成并写入对端内存。
- 价值：数据样式可控（全 0/全 1 会掩盖地址错误，递增与随机能暴露），模式进入覆盖率；原始数据是唯一判据。

## 6. 回归 suite

| suite | 内容 | 依赖 |
| --- | --- | --- |
| core / cmq_gate / rdma_defs | 模型单元测试（不含 env） | dpu_common |
| env | env 全部场景（loopback/netpkt × mock/真实 host_mem）＋ net_packet adapter 测试 | dpu_common、host_mem、net_packet |
| pcie_work | rdma_env_pcie_test（PF/VF ↔ 另一 Host 的 basic_traffic）+ PCIe 插件 | 上述 + pcie_work |
| rxe | rdma_env_rxe_test（basic_traffic ↔ Soft-RoCE）+ 原 rxe 互打测试（需 TAP，手动） | net_packet、DPI、rdma_rxe |

原 host_mem、net_packet、e2e 三个 suite 并入 env。

env 回归每个测试以 `-cm_name <测试名>` 运行，结束后 urg 合并全部测试的 covergroup 并打印
`RDMA_COV merged=`（回归汇总的 merged 字段）。单个测试的 `RDMA_COV total=` 只反映该场景，专项测试
（srq、high_traffic）天然只覆盖一部分；合并值才是覆盖率指标。

## 7. 迁移

| 现有测试 | 去向 |
| --- | --- |
| drv_cmq_golden、dev_cmq、drv_cmq、drv_dev、drv_verbs、defs、types | 保留（模型单元测试） |
| tb_flow、tb_host_mem、tb_e2e、e2e_high_traffic | basic_traffic / high_traffic vseq |
| drv_data、drv_reliability、drv_qp_lifecycle | 场景级检查点由 basic/errors/reliability/srq/qp_lifecycle vseq 覆盖；
  保留（其余检查点是驱动/设备内部行为：inline、CQ arm/resize/cq_clean、CEQ cleanup、SRFQ、SRQ limit AEQE、URC frag、
  SQD doorbell AE、RNR/重试耗尽、QP 编号复用策略，env 层不可表达） |
| multifunc | 复位范围与隔离由 multifunc vseq 覆盖；保留（BAR 解码拒绝、CMQ 卡死超时、外部 IOVA 访问错为驱动/平台内部） |
| pcie_rdma | 已删除：rdma_env_pcie_test + PCIe 插件覆盖其全部检查 |
| rxe_test、rxe_fault_test | env rxe 测试覆盖 basic/errors/srq/reliability；保留（rxe 作请求方的 READ/ATOMIC、rxe 侧 RNR、
  rxe 请求方丢包等以对端视角断言的检查点未全部迁移；suite 手动运行、代价低） |

原则：旧测试只在其全部检查点都有对应时删除；驱动/设备内部行为的单元测试作为模型单元测试保留。

## 8. 阶段

| 阶段 | 内容 | 验收 |
| --- | --- | --- |
| S1 ✅ | 配置、资源层、数据生成、ctrl/verb agent、loopback/netpkt 链路、scoreboard 拆分、env、base vseq、basic_traffic/high_traffic；env suite | 替代 tb_flow/host_mem/e2e/high_traffic，全量通过 |
| S2 ✅ | 链路故障注入；pcie 插件；rxe 链路 + 远端 Function 插件 | basic_traffic 在 4 种传输下通过 |
| S3 ✅ | 协议检查规则类；scoreboard 错误/flush/SRQ/UD/FLR 预测 | 每条规则有变异检查（见第 9 节） |
| S4 ✅ | errors/reliability/srq/qp_lifecycle/multifunc vseq（UD 场景并入 basic/errors）；删已完全覆盖的旧测试 | 全量通过 |
| S5 ✅ | 覆盖率、random vseq、覆盖率报告进入回归汇总 | 覆盖率基线（回归汇总的 RDMA_COV 行） |

## 9. S3 验收：变异检查

每条规则对设备/适配器做一次临时变异，目标测试须报出对应违例（11/11 检出）：

| 变异 | 目标测试 | 检出规则 |
| --- | --- | --- |
| SEND/WRITE 末包不置 AckReq | basic | rdma_rule_ack |
| 3 包消息中间包 PSN +1 | basic | rdma_rule_psn |
| RNR NAK 定时器编码 +1 | reliability | rdma_rule_rnr |
| RNR 重试只等 1/4 定时器 | reliability | rdma_rule_rnr |
| ACK 源 QPN 错 | basic | rdma_rule_state |
| ACK MSN 回退 | basic | rdma_rule_ack |
| UD 报文段类型 LAST | basic | rdma_rule_ud |
| BTH P_Key 0xFFFE | netpkt | rdma_rule_frame |
| READ 响应 PSN +1 | basic | rdma_rule_psn |
| 响应方不查 MR 权限 | errors | scoreboard 状态预测 |
| 响应方不查 MR 的 PD | errors | scoreboard 状态预测 |
| 响应方致命 NAK 后不转 ERR | errors | scoreboard（响应方 RECV 未 flush） |

## 10. 发现与偏差

- 设备模型 RC 请求方收到致命 NAK（如 REM_ACCESS）后曾写错误 CQE 但继续处理后续 SQE；IBTA 要求 QP 转 Error、
  其余 WR flush。已修正：RC 错误完成后设备把 QPC 置 ERR、写 RQ flush CQE，ERR 下的 SQ/RQ doorbell 写
  flush CQE（ERR 下投递的 WR 也 flush）；原偏差 `rc_error_no_flush` 已删除，scoreboard 严格预测。
- 响应方回致命 NAK（远端访问错、接收容量不足）后 RC QP 同样转 ERR 并 flush（IBTA C 类错误，rxe 亦然）；
  flush 排在在途 SQ 工作之后，不越过在途 WQE 的完成。scoreboard 在请求预测为 REM_* 时把对端 QP 记为
  出错（此后投递的期望 FLUSH，在途项可 FLUSH）。URC 响应方不转 ERR（URC 异常经 CEQE/AEQE 上报）。
- 合并覆盖率中 cg_error/cg_completion 的 REM_OP_ERR 只在 rxe 对端出现（被测设备接收容量不足回 0x61，
  即 REM_INV_REQ）。
- rxe 响应方出错后 QP 转 ERR、不再应答（IBTA 行为）；errors 场景在远端对每个错误使用新 QP 对。
- AckReq 规则只约束 SEND/WRITE 末包（READ/ATOMIC 必有响应）；UD Q_Key 取自 WR，不符时由接收端丢弃，
  不作为发送方违例（scoreboard 验证丢弃）。
