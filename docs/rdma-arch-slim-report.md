# RDMA 架构精简报告（feature/rdma-arch-slim）

日期：2026-10-05。基线：`1ea354f`（`feature/rdma-structural-batch226` 末端，Batch247）。
本分支不修改其它分支；所有仿真经 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 执行。

## 最终总结（2026-10-07，HEAD 6738db6，最后一轮全量 v40）

1. **第一阶段：精简**（v1–v17）。合并重复代码；CMQ 引擎按驱动流程重写（13,763→849 行），70 个驱动 opcode
   的请求/响应与 golden 逐字节对齐；删除按源码文本冻结结构的 Python 门禁；注释改写为三段式。
2. **第二阶段：驱动形状重构**（v18–v28）。新建 `src/drv`（驱动模型）与 `src/dev`（设备模型），两者只经
   CMQ 环、MMIO doorbell 与按 IOVA 的 DMA 交互；tb 改为 seq → 驱动 → 设备 → 报文 → 内存；删除旧 core、
   integration 层、CMQ port 栈、SR-IOV 与死代码。
3. **第三阶段：协议补全与 dpu_common 接入**（v29–v34）。补齐可靠传输（PSN 续传、重复请求、RNR、RTO）、
   URC 异常完成（CEQE/AEQE）、UD Q_Key/GRH、SRQ SGB；Function 身份与 BAR 统一由 dpu_common 快照生成，
   doorbell 写 BAR0 绝对地址并经快照解码。
4. **第四阶段：去旧层、dpu 系统层与 pcie_work**（v35–v39）。删除老 core/model/codec 层与其测试，CMQ golden
   改由新驱动模型生成；`rdma_dpu_system` 由 dpu_common 快照统一建立并控制全部 Function（probe、按 Function/
   PF/Host/设备范围 FLR 与恢复）；QP 状态门控与 SQD；MMIO 与设备 DMA 都经 pcie_work 传输：dpu_common 生成
   PF/VF 与随机 BAR，pcie_work 承载 TLP（RC→EP MemWr 送 doorbell，EP→RC MemRd/MemWr 访问 Host 内存），
   RDMA 模型产生数据。
5. **第五阶段：与 Linux Soft-RoCE 互打**（v40）。仿真驱动 + 设备经 TAP 与真实 rdma_rxe 双向收发，用真实实现
   检验线上协议，修正 net_packet 的 RoCEv2 编码（ICRC、pad、BTH/DETH 字段位置）与设备的三处协议错误。

| | 基线 1ea354f | 最终 HEAD | 变化 |
| --- | ---: | ---: | ---: |
| src（.sv/.svh 行） | 114,092 | 15,261 | −86.6% |
| tests（.sv/.svh 行） | 164,612 | 6,399 | −96.1% |
| 分支提交数 | — | 66 | |

第三阶段结束时（v34）src 42,434 行、tests 40,447 行；第四阶段删除老 core/model/codec 层后降至上表。
最终回归（v40，全部通过，告警 0）：Python、style、驱动契约门禁、CMQ gate 5、core 14、host_mem、net_packet、
pcie_work、e2e（`rdma_tb_e2e_test` 与 4096 SEND 高流量）。Soft-RoCE 互打（`make rxe`，需 sudo 建 TAP）13 项
双向用例全部通过，不在默认全量内。
新功能均做过变异检查（注入对应缺陷后测试失败）。

## 目标与取舍

此前的结构重构以单批小改动推进，每批附报告和按源码文本冻结结构的 Python 门禁，
收益递减明显。本轮改为较大粒度的合并：

- 能精简的重复代码直接合并，行为由 VCS 回归和驱动契约保证，不再用文本门禁冻结实现形状；
- 函数注释保留“功能 / 输入/输出及副作用 / 失败/边界”三段，但去掉模板套话并按实现改写；
- 不再在仓库根目录逐批生成报告，历史报告归档到 `docs/history/batch-reports/`。

## 规模变化（src）

| 指标 | 基线 1ea354f | 本分支 | 变化 |
| --- | ---: | ---: | ---: |
| 代码行 | 91,544 | 76,578 | −14,966 |
| 注释行 | 16,412 | 11,423 | −4,989 |
| 总行数 | 114,092 | 93,573 | −20,519（−18.0%） |

主要文件：`rdma_cmq_engine` 13,763→849（按驱动流程重写）；`rdma_queue_data_engine` 9,911→9,295
（含新增 SQ/RQ 外部 SGB）；`rdma_resource_manager` 7,936→7,543；`rdma_control_plane` 4,490→3,669；
`rdma_cmq_codecs` 3,436→3,320。新增 `rdma_cmq_field_codec` 300 行与生成字段表 138 行。
tests 179,228→135,872（旧 CMQ 引擎测试 26,435 行下线，新引擎测试 691 行、golden 测试 647 行）。
全分支相对基线：405 个文件，+22,486/−84,376 行（含 tests、Python 门禁与文档归档）。

## 结构改动

1. **死代码**：删除 src/tests 中无任何调用的 32 个内部函数、未使用局部变量，并内联只转发到
   package helper 的薄包装（cmq engine、cmq codecs、port adapter、txn types）。
2. **公共原语**（`rdma_types_pkg`）：
   - `rdma_deep_copy#(T)::of()` / `try_of()`：替代约 160 处手写“判空→clone→$cast→身份检查→
     fatal/错误”样板，fatal ID 仍为 `RDMA_COPY_TYPE`；
   - `rdma_status::nonnull()`：合并约 100 处“调用返回 null 时归一化为 INVALID_*”样板；
   - `RDMA_BREAK_IF_FAILED`（`rdma_status_macros.svh`）：控制面事务块内 69 处 5 行判定样板。
3. **模型工厂**：`rdma_make_cmq_opcode_key/rdma_make_cmq_command` 统一 CMQ 命令构造；
   恢复阶段账本操作（`rdma_recovery_step_*`、`rdma_recovery_publish_required` 等）
   由 control plane 与 queue lifecycle executor 共用。
4. **控制面**：
   - `admit_locked_request`：锁前校验 binding/请求/目标 → 取 Function 锁 → 锁内重新读取请求复验，
     queue create、queue/QP destroy、QP create/modify、PD create 共用；
   - `run_qp_operation` 合并 create_qp/modify_qp，`run_destroy_operation` 合并 queue/QP destroy；
   - MR 注册三段重复校验收为 `register_mr_input_status/owned_mr_input_status`，深拷贝检查收为
     `detach_mr_request/detach_mr_backing/detach_dma_context`，OCC/MR_DEREGISTER/TQ_FLUSH
     命令统一由 `make_mr_hw_command` 构造。
5. **资源管理器**：`init_candidate/attach_dependency` 收敛 8 个 create_* 的候选初始化与依赖挂接。
6. **队列 facade**：新增 `rdma_queue_facade` 基类承载 SQ/RQ/EQ/CQ 共有的 delegate/authority 状态、
   one-shot configure、授权门禁和 null 归一化；CQ 的 shared-shadow 约束通过 `configure_admission` 钩子保留。
7. **集成层**：device env 的 VF FLR/PF/Host/Device 复位入口共用 `run_reset_request`；reset coordinator
   的 router epoch 校验/推进共用 `call_host_router_epoch`。
8. **小修**：net_packet adapter 两处无初始化 for 循环（消除 VCS FLWI 告警，E2E 编译告警 4→2，
   余下 2 条来自外部 net_packet 仓库）。

9. **legacy execute 迁移**：`rdma_cmq_port` 只保留 `execute_observed()/reconcile()`；删除 legacy
   `execute()`、端口上的“最近一次未提交”可变标志及 base 端口的 legacy→observed 快照回退。
   控制面、queue/QP lifecycle executor 统一经 `rdma_cmq_dispatch()` 调用并拆包，“确定未提交”
   由 `rdma_cmq_result_no_submit_proven(result)` 按结果判定（与原 adapter 判据相同），后端 status
   对象 identity 不变。测试 mock 的 `execute()` 退化为 mock 内部实现，由其 `execute_observed()` 包装。

10. **UVM 验证流程（seq → 报文 → 内存）**：新增 `src/tb`（`rdma_tb_pkg`），设计见
   `docs/rdma-uvm-flow-design.md`。verb agent（sequence/driver/monitor）经 queue-data engine 投递 WQE、
   轮询 CQ；NIC 行为模型读取并解码 SQE/RQE、按 MR 校验 key/范围/权限做 DMA、按 MTU 分段收发
   SEND/WRITE(+IMM)/READ/ATOMIC，回 ACK/NAK/READ 响应/ATOMIC ACK 并经设备侧接口发布 CQE；
   记分板用影子内存预测并逐字节比对。`rdma_packet` 增加 segment 与结构化扩展头
   （RETH/AETH/AtomicETH/AtomicAckETH/ImmDt），net_packet adapter 按 IBTA 表做分段 opcode 映射。
   测试：core `rdma_tb_flow_test`（mock host_mem + loopback wire）、e2e `rdma_tb_e2e_test`
   （真实 host_mem + net_packet 帧编解码 wire），覆盖 RC/UD/URC 与 SQ/RQ 外部 SGB，均为 33 项检查零错误；
   注入 NIC 缺陷可被记分板捕获。顺带修复 net_packet adapter decode 把 UD DETH 留在 header_bytes 中、
   导致 UD SEND_WITH_IMM 立即数被读成 Q_Key 的问题。
11. **RQ 外部 SGB（engine）**：新增 backing 角色 `QP_RQ_SGB` 与 `rdma_create_qp_req.rq_sgb_backing`（可选，仅 RC 私有 RQ），
   QP lifecycle executor 分配/清零/释放（释放顺序排在最后，不改变既有角色顺序），resource manager/projector/
   recovery 校验同步覆盖；queue-data engine 在 post_recv 有效 SGE>2 时写 SGB 槽并在 RQE 填 SGB_PA，host-producer
   recovery 重放时重写该槽。SQ/RQ 共用 `sgb_slot_iova` 槽位解析。新增 `check_rq_external_sgb` 单元检查。
12. **对象别名复制修复**：UVM 1.2 `uvm_object::copy` 在一次顶层复制中按源对象记录 global copy map，同一对象
   第二次被嵌套 clone 时直接返回默认值对象（SGE 列表重复元素、send/recv CQ 共用句柄、plan 内多处共享 mapping
   等会静默丢值）。新增 `rdma_object_utils`（`types/rdma_object_macros.svh`），src 内全部对象类改用它，
   提供 create + 字段自动化 + do_copy 的别名安全 clone()；测试子类覆盖 clone() 的故障注入语义不变。
   `request_model_test` 覆盖列表、跨字段与跨层三类别名。

13. **恢复函数拆分**：queue `recover_locked`、control plane `recover_resource`（MR）、QP
   `recover_destroy_locked` 按恢复阶段拆成独立函数，行为不变（893b5fd、bc037d5、f31cdec）。
14. **CMQ 按驱动 `cmq.c` 重写**（设计与取舍见 `docs/rdma-cmq-driver-alignment.md`）：
   - 引擎（ce10173）：SQ 环 + PI、polarity/wrap、doorbell、CQE 有效性/wrap/opcode/ecode 校验、pending
     链表、`clean_pending` 式 reset/teardown、看门狗（超时 → POISONED），保留 `rdma_cmq_port` 契约；
     13,763 行 → 约 850 行。旧引擎测试与 18 个 CMQ gate 分片下线，改为共享设备 responder
     （`tests/support/rdma_cmq_device_responder.sv`）+ 新引擎测试。fb8cc4b 删除只服务旧引擎的
     journal/digest/typed-snapshot/body-value 模型与 profile 快照接口。
   - 操作全覆盖（3c8e3f3）：驱动 `exec_cmq_cmd` 分派的 70 个 opcode 全部可编码。49 个由表驱动字段
     codec 编码，字段表由 `tools/gen_cmq_request_fields.py` 从驱动填充函数与字段宏生成；21 个沿用专用
     body 编码器。唯一有意偏离：驱动对 7 个无填充函数的 opcode 提交全零 WQE，模型发信封头。
   - review 修复（bc99db7）：超时请求移出 pending、teardown 只报告自身取消的请求、QUIESCED 下 reset
     返回 INVALID_STATE、CQE `wqe_index` 与环位置不符即毒化引擎、SD 附加数据仅允许 SD_UPDATE。
15. **驱动 golden 与能力表闭环**（31b5719）：把驱动原文编译进用户态 harness（53 上对锁定归档执行）生成：
   - 请求：表驱动 49 个 opcode 50 例（`cmq_requests.hex`）+ 专用编码器 21 个 opcode 31 例
     （`cmq_requests_dedicated.hex`，覆盖 QPC 各状态/模式、KEY_ALLOC/MR_REGISTER pbl 0–2 级、
     OCC_FLUSH 5 种驱动组合等），SV 侧逐字节比对，上下文类另解码核对关键字段；
   - 响应：逐位翻转 CQE 测出驱动实际读取位，71 例（`cmq_responses.hex`）；发现驱动 KEY_QUERY/CQC_QUERY
     分别越过 64B CQE 读 16/8 字节，模型不跟随；
   - `cmq_capabilities.tsv` 由 `tools/check_cmq_capabilities.py` 从驱动枚举、提交/完成两个 switch 与 golden
     重建，驱动分派的方向必须有 golden 证据；驱动不分派的 5 行标 `DRIVER_NOT_DISPATCHED`。
     completion 支持集合改为与驱动 CQ 侧分派一致（加 QP_FLUSH，去 OCC_PD_SEARCH/IDX）。

## 验证

每轮均为全量：Python 门禁、changed-SV style、驱动契约（rdma_defs）、core、CMQ gate、integration、
host_mem、PCIe、E2E（dual env / multi-VF / high traffic）。

| 轮次 | 提交 | 结果 |
| --- | --- | --- |
| baseline | 1ea354f | core 115 / CMQ 28 / integration 10 / host_mem 3 / PCIe 1 / E2E 3 全部 pristine |
| v1 | e5d2da6 | 同上全部通过 |
| v2 | 60082eb | 同上全部通过，E2E 编译告警 2 |
| v4 | d898006 | 同上全部通过 |
| v5 | 303730e | 同上全部通过 |
| v6 | 914203a | 同上全部通过，另含 core `rdma_tb_flow_test`、e2e `rdma_tb_e2e_test` |
| v7 | f6d47f9 | 同上全部通过，另含 net_packet suite |
| v8 | 2996737 | 全部通过（core 116 / CMQ 28） |
| v9 | 6dffa60 | 仅驱动门禁失败（错误码宏门禁不认 `rdma_object_utils`），其余全通过 |
| v10 | 711d6a2 | 门禁正则修复后全部通过 |
| v11–v13 | 893b5fd / bc037d5 / f31cdec | 恢复函数拆分，每步全部通过 |
| v14 | ce10173 | 新 CMQ 引擎全部通过（旧引擎测试下线后 core 92 / CMQ 11） |
| v15 | fb8cc4b | 全部通过 |
| v16 | 3c8e3f3 | 仅驱动门禁失败（SD_UPDATE 签名写法不符 composer 单写者规则），其余全通过（CMQ 12 / core 93） |
| v17 | 31b5719 | 全部通过：Python、style、驱动门禁、CMQ 12、core 93、net_packet、PCIe、host_mem 3、integration 10、E2E 5 组（告警 2 来自外部 net_packet） |

v14 起 core/CMQ 用例数下降来自旧 CMQ 引擎测试与分片整体下线，不是用例失败。注释改写由脚本逐文件校验：
去除注释与空白后的代码 token 与改写前完全一致。注释改写由脚本逐文件校验：去除注释与空白后的代码 token
与改写前完全一致。

## 第二阶段：驱动形状重构（2026-10-06，S0–S6 / 阶段 A–E）

目标：主机与设备只经真实硬件边界交互（CMQ 环、MMIO doorbell、按 IOVA 的 DMA），数据端到端检查
走这一边界。计划与完成状态见 `docs/rdma-driver-shaped-arch.md`，UVM 流程见 `docs/rdma-uvm-flow-design.md`。

| 阶段 | 内容 |
| --- | --- |
| A/B | `src/dev` CMQ 消费者、context 存储、HMC 翻译；`src/drv` probe/remove、CMQ、HMC、EQ、PD/MR/CQ/SRQ/QP |
| C | 设备 NIC（RC/UD/URC、READ/ATOMIC、NAK、CQE/CEQE/AEQE、flush）与驱动数据路径（post/poll、CEQ/AEQ、SRQ、CQ resize、cq_clean、cleanup_ceqes、URC frag CQ）；tb 改为驱动 + 设备 |
| D | `rdma_multifunc_test`（5 Function 隔离、故障矩阵、VF/PF/设备复位）、真实 host_mem 与高流量 e2e、CMQ 失败注入回退 |
| E | 删除旧 core（只留 CMQ 参考引擎/transport/doorbell 调度器）、integration 层、CMQ port 栈、SR-IOV、死模型代码与对应测试 |

规模（全部 `.sv/.svh`）：

| | 基线 1ea354f | 第一阶段末 510fd27 | 第二阶段 86ee72e | 第三阶段 HEAD |
| --- | ---: | ---: | ---: | ---: |
| src | 114,092 | 93,573 | 41,442 | 42,434 |
| tests | 164,612 | 126,870 | 39,846 | 40,447 |

数据端到端：`rdma_tb_flow_test`（loopback）、`rdma_tb_host_mem_test`（真实 host_mem）、
`rdma_tb_e2e_test`（再加 net_packet RoCEv2 帧，含 URC 的 XTR 0b110 opcode）各 33 项检查零错误；
`rdma_tb_e2e_high_traffic_test` 4114 项。每个新功能都做了变异检查（注入对应缺陷被测试捕获）。

| 轮次 | 提交 | 结果 |
| --- | --- | --- |
| v18–v21 | 2c49a3e…94e0c5d | A/B 各步全部通过 |
| v22 | 7fa9f7a | 全部通过（core 93） |
| v23 | 5dbfc48 | 全部通过（驱动数据路径 + 设备 NIC） |
| v24 | 19cc6d0 | 全部通过（tb 迁移） |
| v25 | 1f54939 | 全部通过（SRQ、resize、flush、AEQ） |
| v26 | 5b27ae7 | 全部通过（URC） |
| v27 | c61437c | 仅 style 失败（09f534e 插入函数挤掉相邻注释），其余全部通过；E 提交中修复 |
| v28 | 86ee72e | 全部通过：Python、style、驱动门禁、CMQ 12、core 42、net_packet、PCIe、host_mem 3、e2e_tb、e2e 高流量（告警 2 来自外部 net_packet） |
| v29 | f2c46d9 | 全部通过（core 43，新增 `rdma_drv_reliability_test`）：PSN 重传、RNR 重试、URC 异常完成、UD Q_Key/GRH、SRQ SGB |
| v30 | a43107a | 全部通过（core 43）：按 NAK PSN 续传、READ 只重请求缺失段、RNR 定时器编码、URC 异常经 AEQE |
| v31 | 9011339 | 全部通过：响应超时按 QPC RTO_CODE 换算 |
| v32 | 131140d | 全部通过：dpu_common 接入（Function 身份与 BAR 由快照生成，BAR0 绝对地址解码），所有 suite 依赖 DPU_COMMON_ROOT |
| v33 | 89a7fd3 | 全部通过：驱动层单元测试改用 dpu_common（rdma_dpu_test_bar 取代 rdma_drv_dev_bar） |
| v34 | 914e68e | 全部通过：老模型层基线 binding（cmq_engine/golden、doorbell 系列、adapter_contract）由 dpu_common 快照投影 |
| v35 | b5f1883 | 全部通过（core 14、CMQ 5）：删除老层后的首轮；QP 状态门控、SQD、`rdma_drv_qp_lifecycle_test` |
| v36 | c90ab2a | 全部通过：`rdma_dpu_system` 全局 Function 控制 |
| v37 | abcf720 | 全部通过：MMIO 经 pcie_work（pcie_work suite 重新纳入全量） |
| v38 | 26d800d | 全部通过：设备 DMA 端口 `rdma_dev_dma`（task 化，默认后门，行为不变） |
| v39 | 0f1fd94 | 全部通过：设备 DMA 经 pcie_work EP→RC（MemRd 73、MemWr 55 全部送达，requester = Function BDF）；告警 2 来自外部 net_packet |
| v40 | 6738db6 | 全部通过，告警 0：net_packet 换为修正后的 fe37a59；设备 AckReq、起始 PSN、AETH 类型判定修正；rxe 互打 13/13 |

## 第三阶段：协议补全与 dpu_common 接入（2026-10-06，v29–v34）

| 提交 | 内容 |
| --- | --- |
| f2c46d9 | 请求方重试循环（超时/PSN 序列 NAK → 0x16/0x18，RNR → 0xB7，其余 NAK → 0xB9 + 远端 syndrome）；响应方重复请求（重发 ACK、重放 READ、回缓存的 ATOMIC 原值）；URC 异常 CEQE 与驱动异常轮询；UD Q_Key 校验与 40B GRH；SRQ SGB；驱动 REM_ACCESS/REM_OP；新 `rdma_drv_reliability_test` |
| a43107a | 从 NAK 指出的 PSN 续传、READ 只重请求缺失段；RNR NAK 携带 QPC LOCAL_RNR_CODE，按 IB 定时器表等待；URC 异常可经 AEQE 上报，驱动处理后 QP 转 ERR |
| 9011339 | 响应超时由 QPC RTO_CODE 换算；驱动按 `xtrdma_get_rto_code` 映射 IB timeout，URC 固定 urc_rto_code |
| 131140d | `src/adapters/dpu/rdma_dpu_adapter_pkg.sv`：dpu_common 声明 Host/PF/VF → resolver 冻结快照 → Function 投影（host_id、global Function ID = QPC/PD VF_ID、BDF、BAR0/MAILBOX/MSI-X、net_packet identity）；BAR0 绝对地址经 `resolve_bar_address` 路由到设备，MAILBOX/MSI-X/越界地址拒绝；multifunc（2 Host、5 Function）与 tb/e2e 接入 |
| 89a7fd3 | 驱动层单元测试（cmq/dev/verbs/data/reliability）经 `rdma_dpu_test_bar` 走 dpu_common，删除直连的 `rdma_drv_dev_bar` |
| 914e68e | `rdma_dpu_function::binding()`；cmq_engine/golden、doorbell 系列、adapter_contract 的基线 binding 由快照投影 |

假设（驱动源码未给出，模型按推定实现，可替换）：
- URC 每个完成都发 CEQE（硬件是否依赖 arm 未知）；URC 异常经 CEQE 还是 AEQE 上报未知，设备开关二选一。
- RTO_CODE → 超时时长：硬件编码表未公开，取驱动 `xtrdma_rto_code_map` 的逆（编码 0 = 8.192us，31 = 不超时）；
  RC 未设 timeout 时编码 0，超时很短。RC 默认 RNR 编码 0 = 655ms，测试在 RTR 设 min_rnr=1。
- 驱动 URC 异常位置按环大小回绕（驱动源码 idx+1 不取模，按正确行为建模）。
- doorbell 所在 BAR 取 DEVICE_MEMORY（BAR0，对应驱动 `pf->hw_addr`）；MAILBOX/MSI-X 只分配，寄存器与中断
  未建模（EQ 轮询）。
- dpu_common 无 RDMA 专用队列能力，binding 的 CQ/SRQ/EQ 深度上界取其 VIO qpair 与 MSI-X 数。

构建：所有编译 `tests/rdma_unit_test_pkg.sv` 的 suite 都需要 `DPU_COMMON_ROOT`（`dpu_common_preflight`）。

## 第四阶段：去旧层、dpu 系统层与 pcie_work（2026-10-06，v35–v39）

| 提交 | 内容 |
| --- | --- |
| 77f3a03 | 删除 `src/core`、老 model/codec 层、字段归属门禁与 30 个老层测试；CMQ golden（51 条）改由 `rdma_drv_cmq::compose_fields` 生成并比对 `cmq_requests.hex`；测试 mock 改为 `rdma_mock_host_mem` |
| b5f1883 | 按驱动源码补 QP 状态：modify 到 RESET 不支持（驱动映射为 ERR，复用即销毁重建）；RTS→SQD 发 doorbell 后等 AEQE 0x2E，状态不符 0x2C/0x2F；SQD/ERR 下不取新 SQE，RESET/INIT/ERR 接收端丢包；新 `rdma_drv_qp_lifecycle_test`（SQD、doorbell 状态不符、复位后丢包、销毁重建与编号复用） |
| c90ab2a | `rdma_dpu_system`：由 dpu_common 快照为每个 Function 建内存、设备、BAR、驱动；`probe`（host_id、VF_ID = global Function ID）；按快照求 Function/PF（含其 VF）/Host/设备范围，`flr` 与 `recover`；全部单元测试、tb 与 multifunc 改用它 |
| abcf720 | `rdma_pcie_work_pkg`：快照 → pcie_topology（每 Host 一条 RC↔EP 链）→ `pcie_dpu_cfg_adapter` 投影 → `pcie_tl_env`；驱动 BAR 写成为 RC 上的 MemWr（BAR0 随机基址 + 偏移），EP 经快照解码送设备，MAILBOX BAR 拒绝 |
| 26d800d | 设备对主机内存的全部访问经 `rdma_dev_dma` 的 task；DMA 链与寄存器写改为 task；CQ/EQ PI 与 URC 计数在 DMA 前占位 |
| 0f1fd94 | `rdma_pcie_dma`：设备 DMA 在所属 Host 的 EP 上发 MemRd/MemWr（requester ID = Function BDF，按 MRRS 512/MPS 256 切分不跨 4KB），RC 以绑定到该 Root 的 Host host_mem 应答；EP 收到的 MemWr 排队由工作进程分派（RC→EP 进程还要送回 DMA 的 CplD）；测试每 Host 一个真实 host_mem，检查 DMA TLP 发出/送达数、各 Function BDF、经 PCIe 写入的数据 |

分工：dpu_common 生成 Host/PF/VF 与随机 BAR 并冻结快照；pcie_work 按快照建拓扑、承载 TLP；RDMA 驱动与
设备模型产生 MMIO 与 DMA 数据。全局 Function 控制（probe、FLR、恢复范围）由 `rdma_dpu_system` 按快照完成。

假设：PCIe 路径无 IOMMU，设备 DMA 地址即 Host 内存地址（host_mem adapter 用恒等 IOVA）；不同 Host 的
Function 可有相同 BDF（各自 PCIe 域）。

## 第五阶段：与 Linux Soft-RoCE 互打（2026-10-07，v40）

互打前两端都是本仓库模型（编码与解码同一套理解），协议理解错误互相抵消。改为在仿真机（53，内核 5.15）上
用 TAP 网卡接一个真实 rdma_rxe：

```
仿真（VCS）：rdma_drv → rdma_dev ─ rdma_rxe_link（DPI-C）─ TAP rtap0 ─ rdma_rxe（rxe_rtap0）─ rxe_peer（libibverbs）
                                    net_packet 编解码                                    ↑ 测试经管道逐行驱动
```

| 步骤 | 内容 |
| --- | --- |
| P0 线上格式 | `tools/rxe/roce_frame.py`（RoCEv2 帧与 ICRC 参考实现，同 rxe 算法）、`rxe_icrc_check.py`（Python 经 TAP 扮演对端，13/13：我方帧被 rxe 执行、错误 ICRC 被丢弃、rxe 帧 ICRC 校验通过；验证完成后已移除，线上格式由 net_packet 负责） |
| net_packet 修正 | ICRC 原放在扩展头之后且为异或占位 → 负载与 pad 之后的 4B 尾部，按 IBTA A17 计算；负载补 4B pad；BTH 第 4–11 字节与 DETH 第二字字段位置错（QPN 20 在线上为 0x1480）→ 按规范；新测试用 5 个 rxe 实际帧逐字段与逐字节比对（4dc2e08、fe37a59，已合入 GitHub net_packet 的 main：b8a4c14，远端只保留 main） |
| 设备修正 | 请求方 RC/URC SEND/WRITE 末包置 AckReq（rxe 只对 AckReq 包回 ACK）；QPC 写入后加载起始 PSN（RTR：EPSN_REQ，RTR→RTS：RC_TPE_CUR_SQ_PSN，原先两端都从 0 开始）；ACK 按 AETH 类型位 [7:5]=000 判定，回 ACK 信用填 0x1F |
| P1 互打 | `src/adapters/rxe`（DPI-C：TAP 收发、rxe_peer 子进程）、`tests/integration/rdma_rxe_test.sv`：仿真→rxe SEND（1/3 包）、SEND_IMM、WRITE、WRITE_IMM、READ、FETCH_ADD、CMP_SWAP，rxe→仿真 SEND、SEND_IMM、WRITE、READ、FETCH_ADD，两端完成、立即数与内存一致，双向各 17 帧无丢弃；去掉 AckReq 的变异使测试失败 |
| P2 故障场景 | `tests/integration/rdma_rxe_fault_test.sv`（链路可注入丢帧，每组新建 QP 对）：UD 双向（GRH、src_qp）、UD 多 SGE（发送 3 SGE 收集、接收 3 SGE 散写，GRH 在首 SGE）与 Q_Key 不符静默丢弃；SRQ 两侧（仿真 SRQ 消费 rxe SEND；rxe SRQ 消费仿真 SEND，含多包）；RNR 两方向（设备 NAK 0x21、rxe NAK 后设备按定时器重试）与重试耗尽 0xB7；丢中间包两方向（PSN 序列 NAK 后续传/重传）、丢 ACK（设备超时重发，rxe 重复请求再 ACK）、丢 READ 中间响应（只重新请求缺失部分）；错误 rkey 的 WRITE/READ 两方向（NAK 0x62）、超长 SEND 两方向。双向 26/29 帧、0 错误；去掉 RNR 定时器编码与 PSN 序列 NAK 的变异各被对应检查抓到 |

差异记录：接收缓冲放不下 SEND 时，设备回 invalid request NAK（0x61，与 mlx5 等硬件一致，rxe 按 REM_INV_REQ
接受）；rdma_rxe 5.15 自身回 remote operational error（0x63），测试按 rxe 实际行为断言。

运行：`tools/rxe/rxe_tap_setup.sh up`（sudo，一次）后 `scripts/run_vcs53.sh rxe regression`（两个测试）。仿真时间与
真实时间：链路空闲时每 100ns 仿真时间等待至多 20us 真实时间（+RXE_WAIT_US）；设备 QP 用不超时（IB timeout 0）。

耗时（53）：`make rxe TEST=regression` 约 70s：编译约 33s；每次 simv 启动约 8.5s 是 VCS license 检出（与 rxe
无关，任何测试相同）；rdma_rxe_test 用例本身约 0.2s，rdma_rxe_fault_test 约 4s（仿真时间 1.1ms，主要是 RNR
定时器与 ACK 丢失的超时等待）。

## 未做与遗留

- CEQ/AEQ 的 request/resource/context model 与 lifecycle policy 仍为平行实现；字段名不同，
  用钩子合并反而增加行数，需先统一模型基类才值得做。
- 驱动对 7 个无填充函数 opcode 提交全零 WQE，模型发信封头（有意偏离，见 CMQ 对齐文档）。
- 驱动 KEY_QUERY/CQC_QUERY 越界读 CQE 之后字节，模型只解码 64B CQE 内的内容。
- 第一阶段的包级 DAG 计划已被第二阶段的驱动形状重构取代。
- 尚无 RTL DUT：`src/dev` 设备模型充当设备，接入 DUT 后应退为预测器。
- 只有 pcie_work suite 的 DMA 走 PCIe；core/host_mem/e2e 仍用后门 DMA 端口（零仿真时间）。
- 响应方对中间包 AckReq 不单独回 ACK（末包 ACK 已覆盖，长消息下 rxe 的中间 AckReq 只是延后确认）。URC/SQD 等 xtrdma 私有行为 rxe 不支持，无法互打。
- PCIe 路径未开 FC/记分板/覆盖率；Completion 超时、UR/CA 只报为 DMA 失败，未建模设备侧错误上报。
- core 内的 data/reliability/multifunc 用直连链路，只有 e2e 经 net_packet 帧编解码；设备报文不带 IP
  地址，GRH 与 IP 头地址为 0。
- MAILBOX/MSI-X 寄存器、中断、SEND/WRITE 超时后的部分重传（响应方只对末包 ACK）未建模。
