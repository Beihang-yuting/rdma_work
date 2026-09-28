<!-- 目录：项目根目录；职责：记录 Batch227 设备发布准备/取消职责分界及验证证据。 -->

# Batch227：设备发布准备与取消编排

日期：2026-09-28。基线 `2ee9ff6`，沿用工作树 `.worktrees/rdma-structural-batch226`、
分支 `feature/rdma-structural-batch226`。不合并、不推送；main 保持 `083e0d7`，用户
已有缓存保留。项目级计划仍 active，本批不等于 producer 或全项目重构完成。

## 结构与业务边界

CQ/CEQ/AEQ 的共同设备发布事务分为两个可直接阅读的阶段：

1. `prepare_device_publish()` 校验输入、预留归属，按原顺序准备 next cursor、完整
   pending、result/status、payload 和 detached image/queue；不执行取消、I/O 或提交。
2. `write_commit_device_entry()` 统一处理准备失败的取消，再执行原 write→readback→
   compare→producer commit→result 交付及 Batch226 的共同写后恢复出口。

新增 `device_publish_prepared_t` 是本次调用的普通值记录，聚合原有五个局部值与取消
上下文；不经过 factory、不保存 runtime/access、不增加实例状态或第二个资源 owner。
没有新增生产文件、业务接口或通用状态机。

取消权限保留三个层次：

- attachment/geometry/reservation 查询或归属校验拒绝：context 为空，不能取消预留。
- next/pending 准备失败：context 非空、pending 强制为空；取消失败仅保留 reservation，
  不能把残缺 pending 交给恢复状态机。
- pending 完整后的失败：context 非空、保留完整 pending；取消失败记录 `NO_SUBMIT`、
  `device_write_attempted=0`，供公开恢复接口接管。

准备函数返回 bit 表示“所有输出可进入 I/O”，不能只用 `status.ok()` 推断完成。
原来“status 成功但对象缺失也要取消”的分支不被弱化；函数成功出口不新增 status
分配，不提前冻结成员或填充 result 成功字段。写入前的 backend preflight 取消仍保留
独立边界，未开始 backend 却返回 OK 的异常恢复、两次状态复制及其 factory 回调窗口
也原样保留。不使用跨嵌套调用有风险的命名块 `disable`。

engine 9,916→9,931 行，生产代码净增 15 行；共同 I/O task 本体 268→121 行，新准备
函数 143 行。原 138 个方法声明、27 个公开业务方法不变，新增一个 protected helper，
共 139 methods。本批是职责分离，不宣称总代码收缩。

## 复审与等价核对

只读审计 `/tmp/rdma_batch227_audit.py` 固定 `2ee9ff6`，结果见同名 `.log`：

- 原 137/138 方法全文 token 不变，全部原声明不变。
- 移除新增的六字段 typedef 后，类壳 token 完全一致，无新增 mutable owner/字段。
- I/O、commit/result、两个 backend 未开始旁路和恢复尾段只去掉局部 `prepared.`
  限定后，全文 token 与基线一致，包括字符串和字段读取顺序。
- 准备阶段保留四个不取消的拒绝出口；将九个取消续接规范化，并明确核对前两个传
  null、其余传完整 pending 后，所有准备 token 与基线相同。caller 统一出口另行
  核对原 status/context/evidence 的传递和直接 return。
- `src` 与 `tests/unit` 全部 197 个 `.sv` 文件、5,304 methods 的文件头/逐方法中文
  三段契约扫描 0 diagnostics。词法扫描不是全项目人工语义/可读性最终验收。

上下文复审覆盖 engine 文件入口、owner 字段、准备/取消/接管/未接管证据、write/read/
commit/replay，fixture setup/cleanup，新增测试全文及注册上下文。其余旧方法通过
完整 token 核对沿用基线证据，不宣称重新人工验收全部旧实现。dpu_common authority、
外部依赖、codec ABI 与外部组件生命周期均未改变。

## 新增验证

`rdma_device_publish_prepare_test` 已注册 core，三种设备生产队列共 126 个独立
lifecycle fixture：每类 queue 含三个不取消入口拒绝、十三类准备故障各配正常/null/
RESOURCE_BUSY 三种取消结果。

| 业务阶段 | 注入故障 | 契约 |
| --- | --- | --- |
| 入口与归属 | null image、无效 geometry、stale cursor | 零取消、零 I/O、原 reservation 不变 |
| next/pending | next null/错误类型、pending null、pending queue/image/cursor/next clone null | 取消失败不能发布部分 pending，只保留 reservation |
| 完整 pending 后 | image alignment、result null、byte copy、result image/queue clone、late offset | 正常取消返回原错误；失败则保存完整 `NO_SUBMIT` 恢复证据 |

byte-copy 故障在 result status 的真实 factory 回调中修改源 image.length，验证没有
提前冻结源字段；offset 故障在 pending 的 route/epoch 已准备完成后的 status 回调
暂时修改 depth，并在 cancel seam 恢复，验证保留最后一次 offset 校验的时机。
这些故障只作用于隔离测试 fixture，不修改生产或外部依赖的 authority。

每个 case 检查故障实际命中、取消次数、零 backend I/O、result、status、occupancy、
reservation 与 pending 的阶段/authority/诊断。完整且格式有效的 pending 经公开
retry 验证仅一次 write/read/commit；入口拒绝、reservation-only 和 malformed image
经显式 abort/detach 清理；所有 case 最后检查零 live allocations。

既有 30-case 写后矩阵继续验证成功、写后四类错误、特殊 backend 返回和接管失败。
新增六项 Python 门禁守卫普通值记录、准备/副作用边界、取消权限、九类续接、bit
完成标志和矩阵注册；旧六项门禁改为分别检查准备函数和 I/O task，不删除原约束。

不对 `rdma_status::make()` 的 factory 返回 null；该基础方法仍直接解引用返回对象，
属于独立待评估边界，本批纯重构没有顺便改变它。合成 image 测试不能替代公开
CQE/CEQE/AEQE codec/route/WQE 释放或真实 DUT 验收。

首轮 126-case focused（所有 retained case 使用 abort）通过；随后补充有效完整
pending 的 retry/write/read/occupancy 断言并修正测试格式门禁。最终证据只采用此
修订后的输入；初轮日志 `rdma_batch227_prepare_initial.log` 不计最终验收。

## 验证状态

最终 focused 与完整回归全部通过，全部 wrapper 返回 0，UVM summary 均为 0/0/0。
计数、126/30-case 标记、警告、退出码及静态结果的统一核对见
`/tmp/rdma_batch227_verification_summary.log`；最终送测后未改生产、测试或构建输入。

| 验证 | 最终结果 | 日志（`/tmp/`） |
| --- | --- | --- |
| focused | 126 cases、PROCESS/LOGICAL PASS | `rdma_batch227_focused_final.log` |
| core | 101/101 PROCESS、84/84 LOGICAL、101 pristine；包含新旧 126/30-case 矩阵 | `rdma_batch227_core_final.log` |
| CMQ gate | 28/28 PROCESS、11/11 LOGICAL、28 pristine | `rdma_batch227_cmq_final.log` |
| integration | 10/10 pristine | `rdma_batch227_integration_final.log` |
| E2E 双环境 / 多 VF / 高流量 | 三项各 1 pristine | `rdma_batch227_e2e_final.log` / `rdma_batch227_e2e_multivf_final.log` / `rdma_batch227_e2e_traffic_final.log` |
| Host-memory / PCIe | 3/3、1/1 pristine | `rdma_batch227_host_mem_final.log` / `rdma_batch227_pcie_work_final.log` |
| 驱动归档 / C oracle / 字段归属 | 203 自测、definitions、oracle、字段归属通过 | `rdma_batch227_driver_contract_final.log` |
| Python | 329/329 通过 | `rdma_batch227_python.log` |
| token / 注释结构审计 | 等价、197 files / 5,304 methods / 0 diagnostics | `rdma_batch227_audit.log` |
| style / diff / lifecycle / profile / Phase-1A | 全部通过 | `rdma_batch227_style_final.log`（空）及终端记录 |

三项 E2E 各有 4 条既有编译警告：本项目 net adapter 的 2 条 FLWI、外部 net_packet
的 2 条 SV-ANDNMD；其余 VCS 回归编译警告为 0。UVM pristine 不等于编译零警告。

所有 VCS 通过项目 wrapper 在 `ubuntu@10.11.10.53` 登录 bash 运行，依赖沿用：

```text
HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem.audit.current
DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common
NET_PACKET_ROOT=/home/ubuntu/net_packet_latest
PCIE_WORK_ROOT=/home/ubuntu/workspace/pcie_work_audit.POaPmh
```

最终送测输入 SHA256（提交前再次核对一致）：

```text
6afb1b137eb9a49a9f09e625a504d35d3ee13225075313d434a76ac0a485710c  src/core/rdma_queue_data_engine.sv
9e62bf23e52f17c8c2205a621932649edd30762146eda21d19cbdef57a866b89  tests/unit/rdma_device_publish_prepare_test.sv
7c94c8d96e380333744310c635210985f2db2c626b3e72e793deb197b67a4eca  tests/unit/test_device_publish_exit_boundary.py
ec41611ee845e06e6fdcd4f6c689c01edb665c1c7c4411f521ab1c323c8f32a4  tests/unit/test_device_publish_prepare_boundary.py
42572addb895066d9202e1875db919ea58b6398d8610dd49d4d8208a3858ca08  tests/rdma_unit_test_pkg.sv
221ed87c89ca10858e491f917d8fa42f9f82f4564c46b93d38fc88a528049c34  scripts/run_queue_lifecycle_regression53.sh
```

## 尚未关闭

更完整的 host-producer/resize 业务编排、manager publication 后更新、runtime 快照与
提交分界、跨 owner 原子性、SRQ 完整生命周期、跨队列并发、legacy/external ordering/
error、Phase-1C F2、其它 epoch 饱和策略、包 DAG 与全项目可读性验收仍 OPEN。
SQD/SQE 仍明确 unsupported；不借本次结构重构隐式扩大业务能力。

下一批可审查候选是 `complete_host_producer_tail()` 的七处恢复续接：入口 gate 仅在
`prior_host_write` 时恢复，write/result/next 失败保留 `NO_SUBMIT`，doorbell/commit
失败保留原有 ambiguous 语义；已提交 result-status 异常仍不得落入未提交恢复。
可先评估统一失败出口，不新增 policy 类或第二 owner；本批未实施或验收该候选。
