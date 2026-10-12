# `rdma_dut_link` 实施计划

## 目标

在不改变现有 `rdma_link` loopback 语义的前提下，增加真实 DUT 网络边界，并把此前约定的 QP/QPC、资源、message、netpacket、AIP 和 fault 参数通过冻结 snapshot 传到正确的消费者。

本计划不把所有缺失的 RDMA wire opcode、VLAN/IPv6/隧道 codec 行为一次性塞进 link；link 先建立稳定边界，codec 扩展按独立 profile/codec 任务推进。

## 约束与不变量

1. `rdma_link` 继续服务模型↔模型快速回归，默认 `link_type` 不变。
2. `rdma_dut_link` 不调用 `rdma_link::deliver()` 把 DUT 伪装成模型 NIC。
3. AIP/Tcl 只进入 profile/resolver；driver/dev/codec/link 只消费冻结 snapshot。
4. QPC snapshot 是硬件上下文唯一来源；netpacket 不能覆盖 QPN、PSN、MAC、VLAN、FWD、tunnel 能力等 QPC 字段。
5. PD/MR/QPC/SD 的非法组合由对应 profile 的 `INVALID` 策略驱动，link fault 只处理 frame/endpoint 方向的故障。
6. 外部 endpoint 的句柄、DPI/VPI/TAP/VIP 生命周期由插件拥有；link 只保存非拥有引用。
7. 每个观测拥有独立 raw frame 副本，不能复用 `rdma_link_netpkt.carried`。

## 文件变更清单

### 新增

- `src/model/rdma_flow_profiles.sv`
  - `AUTO/FIXED/RANDOM_LEGAL/INVALID` 策略；
  - `rdma_flow_plan`、`rdma_qp_profile`、`rdma_qpc_profile`、`rdma_hmc_profile`、`rdma_message_profile`、`rdma_netpacket_profile`、`rdma_endpoint_profile`、`rdma_fault_profile`；
  - 对应 immutable input/resolved snapshot 和 snapshot identity/epoch；
  - 不依赖 AIP、net_packet 或 DUT 外部组件。

- `src/model/rdma_flow_resolver.sv`
  - 跨 profile 合法性检查；
  - 自动资源关联和 `rdma_dut_link_snapshot` 生成；
  - snapshot freeze、source identity 和 reset epoch 校验。

- `src/tb/rdma_dut_link.sv`
  - `rdma_dut_frame_endpoint` 抽象 endpoint；
  - memory endpoint test double；
  - `rdma_dut_link`、DUT port、DUT MAC 路由、TX/RX frame 统计和接收线程。

- `tests/unit/rdma_flow_profiles_test.sv`
  - profile 默认值、策略边界、AUTO 资源关联、冻结 snapshot、非法组合和 QPC/netpacket 冲突测试。

- `tests/unit/rdma_dut_link_test.sv`
  - memory endpoint 注入/捕获、DUT frame decode、失败 frame、并发 frame 快照和 endpoint 生命周期测试。

### 修改

- `src/model/rdma_model_pkg.sv`
  - 按固定顺序 include `rdma_flow_profiles.sv` 与 `rdma_flow_resolver.sv`，让 codec、driver、env 共享 profile/snapshot 类型。

- `src/adapters/net_packet/rdma_netpkt_pkg.sv`
  - 增加接受 `rdma_netpacket_snapshot` 的 encode/decode 入口；
  - 保留旧 `encode(rdma_packet)` 兼容路径，默认使用当前固定 RoCEv2 地址；
  - 对 QPN/PSN/DETH/RETH/外层地址等执行只读一致性校验；不回写 QPC snapshot。

- `src/tb/rdma_env_pkg.sv`
  - include `rdma_dut_link.sv`，确保类型在 env factory 使用前可见。

- `src/tb/rdma_env_cfg.sv`
  - 增加 flow/resolved snapshot 和 endpoint plugin/config 引用；
  - 保持 `link_type = "rdma_link"` 默认值，增加 `rdma_dut_link` 所需的绑定校验。

- `src/tb/rdma_env.sv`
  - 在 build/start 阶段把冻结的 `rdma_dut_link_snapshot` 绑定给 link；
  - 模型 Function 继续 attach；真实 DUT 不注册为 `rdma_res_func.node.dev.nic`；
  - report 阶段检查接收线程、endpoint 错误和 snapshot epoch。

- `tests/rdma_env_test_pkg.sv`、测试 filelist/package
  - 注册 DUT link unit test；增加只使用 memory endpoint 的 env smoke test；不要求真实 DUT 或外部网卡才能编译。

- `tests/rdma_unit_test_pkg.sv`
  - 按依赖顺序 include profile/resolver/link 测试，保持既有 unit test package 的统一入口。

## 实施步骤

### Step 1：profile 和 snapshot 基础类型

1. 在 model 层定义策略枚举、profile 字段和 `freeze/validate` 契约。
2. 明确自动关联字段：`qp_h`、`local_qpn`、`send_cq_h`、`recv_cq_h`、SQ/RQ backing、QPC shadow、PD/CQ/EQ/CQN、PBL/PBLE、AEQ/CEQ/UAQ、HMC PBA。
3. 明确用户字段：TX/RX QP 数量、QP type/depth、PSN/dest QPN、PKEY/QKEY、MTU、MAC/IP/UDP source port、VLAN/FWD/tunnel、CQ/EQ depth/vector、SD page size/VLD/VF_ID、MR/PBL mode。
4. 对每个 QP 使用独立 profile；resolver 不把 `tx.qps[0]` 和 `rx.qps[0]` 合并成同一对象。
5. `rdma_flow_plan` 固化 `managed_link/static_peer`、TX/RX QP 配对和每 QP message profile 索引。

验证：先运行 `rdma_flow_profiles_test` 的 RED/编译检查，再补实现；检查 null、重复 index、策略冲突、快照 freeze 后修改、TX/RX 交叉引用和非法 page/VLD/FWD。

### Step 2：resolver 和 AIP 边界

1. 增加 hardware-neutral `rdma_config_resolver`，输入 profiles，输出资源/QPC/message/netpacket/link snapshots。
2. resolver 负责跨字段约束：QP type↔合法 opcode、depth↔backing、PD↔MR/CQ、VLD↔PBA、VLAN/FWD/tunnel capability、QPC path↔netpacket wire 字段。
3. normal 模式中同名 QPC/netpacket 字段不一致直接返回配置错误；显式 `field_override` fault 才允许生成不一致 frame，并写入 fault identity。
4. AIP 适配只调用 profile setter/随机化接口，支持 `aip_int`、动态数组、索引覆盖、范围/候选/权重和 Tcl `set_param`；不让 driver/link 直接读取 Tcl/AIP。
5. snapshot 携带 reset epoch 和 source identity，供 reset 后拒绝旧 binding。

验证：profile-only 单元测试覆盖固定、合法随机、非法随机、TX/RX 独立 QP 数量、managed/static 两种 peer 建模、field conflict 和 fault override。

### Step 3：codec 的 snapshot 入口

1. 给 `rdma_netpkt_codec` 增加 snapshot-aware encode/decode；旧接口保留并构造默认 snapshot。
2. codec 使用 message snapshot 生成业务扩展头，使用 QPC snapshot 只读校验 QPN/PSN/path；netpacket snapshot 只控制外层和 payload。
3. 对当前不支持的 opcode/transport/outer encapsulation 返回明确 `UNSUPPORTED_OPCODE` 或 `CODEC_ERROR`，不静默降级为 SEND。
4. raw frame 作为独立队列复制到观测对象，支持后续 VLAN/tunnel 扩展而不改变 link API。

验证：现有 codec 测试必须保持通过；新增 QPC/netpacket 一致、不一致、故障 override 和 frame 字节保真测试。

### Step 4：实现 `rdma_dut_frame_endpoint` 与 `rdma_dut_link`

1. 新增 endpoint 抽象：`send_to_dut`、`poll_from_dut`、start/stop；明确 status、关闭和超时语义。
2. 新增 memory endpoint，具备发送捕获队列、DUT TX 注入队列、可控延迟/错误和独立 frame copy。
3. `rdma_dut_link::bind_endpoint` 校验 endpoint、DUT MAC、端口、route、epoch 和重复绑定。
4. 模型 peer→DUT：应用已编译 fault plan，snapshot-aware encode，调用 endpoint；成功才发布 TX 观测。
5. DUT→model：接收原始 frame，保留副本，decode 成功才发布 RX 观测；失败只记录 raw frame/status，不发布 `pkt == null`。
6. 模型 Function→模型 Function 继续委托基类 loopback；未知 route、DUT route 和内部 route 三类路径分别统计。
7. 接收线程使用每帧局部 buffer，stop/reset 幂等，报告未关闭线程、endpoint error、decode failure 和未完成 fault。

验证：memory endpoint 单测、factory 创建、DUT MAC 冲突、未绑定 endpoint、发送失败、decode/ICRC 失败、并发收发和 reset epoch 拒绝。

### Step 5：env/plugin 集成

1. `rdma_env_cfg.link_type="rdma_dut_link"` 时由插件创建 endpoint 并在 start 前绑定 snapshot。
2. env 只把模型 Function attach 到 link；真实 DUT 的控制面与网络 endpoint 不伪造为 `rdma_res_func`。
3. checker/coverage 继续订阅 `tx_ap/rx_ap`；scoreboard 增加 DUT TX semantic/frame adapter，不修改现有模型 loopback 契约。
4. 提供 `DUT_MODEL_PEER` smoke test；未设置 endpoint 时必须给出可定位的 fatal。

验证：默认 `rdma_env_basic_test`、`rdma_env_netpkt_test` 和原有 rxe/loopback 测试保持行为不变；新 smoke test 只依赖 memory endpoint。

### Step 6：真实外部 endpoint 适配预留

1. 不修改外部 `net_packet`、TAP、PCIe 或 VIP 仓库。
2. 在本项目中提供 endpoint plugin 适配模板，外部实现仅填充 raw frame send/poll、reset epoch、port state 和错误状态。
3. 所有真实 VCS 仿真按 `AGENTS.md` 在 `ubuntu@10.11.10.53` 登录 bash 环境执行；本地单元测试不得假设外部 DUT 存在。

## 验证命令与门禁

- `git diff --check`
- profile/link unit tests（先本地 compile，再 VCS）
- 现有 netpacket codec tests
- 现有 env loopback/netpkt/rxe regression
- `scripts/run_vcs53.sh core <test>` 或项目对应的 VCS wrapper（登录 bash）
- 变更目录全量复审：文件头、每个函数三段中文注释、所有权、reset/epoch、错误路径和 frame copy

## 提交拆分

1. `feat: add rdma flow profiles and resolved snapshots`
2. `feat: add snapshot-aware netpacket codec`
3. `feat: add rdma dut link endpoint bridge`
4. `test: cover rdma dut link and parameter ownership`
5. `docs: record external endpoint integration contract`

每个提交独立可审查，禁止把外部依赖修改、无关格式化或真实 DUT 专属实现混入基础 link 提交。
