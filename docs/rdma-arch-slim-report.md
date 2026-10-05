# RDMA 架构精简报告（feature/rdma-arch-slim）

日期：2026-10-05。基线：`1ea354f`（`feature/rdma-structural-batch226` 末端，Batch247）。
本分支不修改其它分支；所有仿真经 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 执行。

## 目标与取舍

此前的结构重构以单批小改动推进，每批附报告和按源码文本冻结结构的 Python 门禁，
收益递减明显。本轮改为较大粒度的合并：

- 能精简的重复代码直接合并，行为由 VCS 回归和驱动契约保证，不再用文本门禁冻结实现形状；
- 函数注释保留“功能 / 输入/输出及副作用 / 失败/边界”三段，但去掉模板套话并按实现改写；
- 不再在仓库根目录逐批生成报告，历史报告归档到 `docs/history/batch-reports/`。

## 规模变化（src）

| 指标 | 基线 1ea354f | 本分支 | 变化 |
| --- | ---: | ---: | ---: |
| 代码行 | 91,544 | 89,438 | −2,106 |
| 注释行 | 16,412 | 12,170 | −4,242 |
| 总行数 | 114,092 | 107,610 | −6,482（−5.7%） |

主要文件：`rdma_cmq_engine` 13,763→13,089；`rdma_queue_data_engine` 9,911→9,181；
`rdma_resource_manager` 7,936→7,534；`rdma_control_plane` 4,490→3,801；
`rdma_queue_runtime` 3,795→3,568；`rdma_qp_lifecycle_executor` 4,338→4,177。
Python 门禁另删除约 4.8k 行（结构冻结类）。

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

后续轮次结果见对应提交说明。注释改写由脚本逐文件校验：去除注释与空白后的代码 token
与改写前完全一致。

## 未做与遗留

- CEQ/AEQ 的 request/resource/context model 与 lifecycle policy 仍为平行实现；字段名不同，
  用钩子合并反而增加行数，需先统一模型基类才值得做。
- cmq engine 的类型化快照（按类型逐字段克隆并校验）保持原设计，以保留对异常 do_copy 子类的修复语义。
- 包级 DAG（Phase E）未开始。
