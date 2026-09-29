# RDMA 结构重构执行交接

## 初始交接快照（历史）

用户要求立即将主线优先级切换为结构优化：停止当前修复任务，先优化代码结构，
然后运行测试并修复发现的问题。此前“等待 F2 收口再开始”的顺序已被此指令替代。

本文件由侧边会话创建，记录可直接执行的任务范围与约束。侧边会话没有停止主线程，
也没有调用或干预其子代理；因此本文件不代表暂停完成、任务已调度或代码重构已启动。
交接时只读检查发现主线仍在运行 `rdma_queue_codec_test` 的 VCS53 wrapper。

以下路径和提交只记录 2026-09-17 初始交接现场，不再代表当前执行位置：工作树为
`/home/ryan/workspace/ryan/rdma_work/.worktrees/rdma-cmq-contract-foundation`，HEAD 为
`00b8ff6`（`feature/rdma-cmq-contract-foundation`），当时存在大量未提交改动。该历史
现场及已有验证证据仍须保留。

## 当前执行状态（2026-09-29）

最新本地合并：Batch222–225 的四个提交已从 `feature/rdma-structural-batch222`
快进进入 `main`，源码基线为 `93012a3`；原工作树与已有改动保留，不推送远端。
本轮只补合并记录，生产/测试/构建输入与已完整验证的 Batch225 一致。
以下批次中的“不合并／尚未合回 main／主线为 5f8dfe9”保留为提交时的历史记录，
不再代表当前主线状态；项目级 Phase B–E 与组合验收仍未全部完成。

Batch238 基于 `e04e7c5` 沿用 `feature/rdma-structural-batch226`：CMQ recovery 的
12 个 aligned 拒绝共用一个回填/解锁出口，四类空结果早拒绝及 CONFIRM/RETRY
成功路径不变；不增加 owner/状态/API。方法 375→361 行、tokens 2,161→1,982，
生产净减 9 行。旧版/重构版 36-call 专项、core 107/90、CMQ 28/11
（PROCESS/LOGICAL）、integration 10、Host-memory 3、PCIe 1、E2E 3、Python
388/388、驱动及固定基线/静态审计全部通过；UVM 0/0/0，E2E 保留既有编译告警。
最终送测哈希一致。不合并、不推送，项目仍 active；
见 `task-rdma-batch238-cmq-recovery-exit-report.md`。

Batch237 基于 `837afbc` 沿用 `feature/rdma-structural-batch226`：CMQ 完成路径拆为
读取解码、匹配、完成提交和前缀回收；normal/late 共用 completion 构造与 token 校验。
poll 主方法 261→50 行，保留 31 public、原锁与唯一账本；生产总量净增 41 行，
本批是主流程可读性整理，不声称整体收缩。16-case 旧版/重构版专项、core 106/89、
CMQ 28/11（PROCESS/LOGICAL）、integration 10、Host-memory 3、PCIe 1、E2E 3、
Python 383/383、驱动和固定基线/静态门禁全部通过；UVM 0/0/0，E2E 保留既有
编译告警。最终源码哈希一致，证据见
`task-rdma-batch237-cmq-poll-transaction-report.md`。不合并、不推送，项目仍 active。

Batch236 基于 `5a07c57` 沿用 `feature/rdma-structural-batch226`：runtime 普通/noalloc
恢复授权共享持锁规则，保留错误优先级、shadow、一次性 confirmation、失败原状态和
各自 factory/锁交付窗口。生产净减 17 行，相关 tokens 526→312，58 public 不变。
345-call 矩阵旧版/重构版均通过；core 105/88、CMQ 28/11（PROCESS/LOGICAL）、
integration 10、Host-memory 3、PCIe 1、E2E 3、Python 377/377、驱动及等价/静态
门禁全部通过。UVM 0/0/0，E2E 保留基线编译告警，送测 hashes 一致。
不合并、不推送，见 `task-rdma-batch236-runtime-commit-gate-report.md`；
项目仍 active。

Batch235 基于 `fc8b61f` 沿用 `feature/rdma-structural-batch226`：门铃 DMA/MMIO
barrier 共用限时 worker/timer，保留阶段顺序、诊断、局部取消域与 MMIO 可见性边界；
生产净减 26 行，不新增 owner 或状态。独立 23-case 矩阵在旧实现及重构版通过；
core 104/87、CMQ 28/11（PROCESS/LOGICAL）、integration 10、Host-memory 3、PCIe 1、
E2E 3、Python 371/371、驱动及等价/静态门禁全部通过；E2E 保留基线编译告警，
最终送测 hashes 一致。
不合并、不推送，见 `task-rdma-batch235-doorbell-barrier-report.md`；项目仍 active。

Batch234 基于 `f4933f0` 沿用 `feature/rdma-structural-batch226`：backing read/readback
和 write/write_device 各共用一套字节循环，保留方向、预检、诊断、失败前缀和
device started；11 public 不变，不新增状态/owner。生产净减 16 行，相关 tokens
951→725；新增 80-case 三段矩阵和六项 Python 门禁。修订旧版基线、重构版专项、
core 103/86、CMQ 28/11（PROCESS/LOGICAL）、integration 10、Host-memory 3、PCIe 1、
E2E 3、Python 365/365、驱动及等价/静态门禁全部通过；E2E 保留基线编译告警。
送测后仅一处测试注释修订，tokens 与最终 hashes 已核对。不合并、不推送，见
`task-rdma-batch234-backing-transfer-report.md`；项目仍 active。

Batch233 基于 `e1b8ed5` 沿用 `feature/rdma-structural-batch226`：CEQ/AEQ 路由后的
结果/continuation 准备与提交合入 `consume_routed_event`，各自 decode/route/epoch
和 CQ flush partial 规则不变；保留 miss 最终状态分配失败的原 status 引用。
生产净减 46 行，27 个公开声明与 owner/类壳不变，一个 protected task 改名/改签名。
重构前/后 44-case 矩阵、core 103/86、CMQ 28/11（PROCESS/LOGICAL）、integration 10、
E2E 3、Host-memory 3、PCIe 1、Python 359/359、驱动及等价/静态门禁全部通过；E2E
保留基线编译告警，原送测与最终注释版 token 相同，最终专项及 hashes 已核对。
不合并、不推送，见 `task-rdma-batch233-event-consume-report.md`；项目仍 active。

Batch232 基于 `8e7145d` 沿用 `feature/rdma-structural-batch226`：收束 CQ resize
retry 的 17 个记录内失败出口，保留入口拒绝、发布前/后成功与全部 authority/恢复
顺序；不合并正常 resize 与 retry 的不同错误策略。既有 resize test 增加 22-case
retry 故障/嵌套矩阵与五项 Python 门禁；生产净减 19 行，17 续接展开后 token 等价，
139 声明/类壳不变。重构前基线、终版专项、core 103/86、CMQ 28/11
（PROCESS/LOGICAL）、integration 10、E2E 3、Host-memory 3、PCIe 1、Python 354/354、
驱动契约及静态/注释门禁全部通过；三项 E2E 各保留 4 条基线编译告警。
送测输入 hashes 一致。不合并、不推送，详见
`task-rdma-batch232-resize-retry-exit-report.md`；项目仍 active。

Batch231 基于 `dad8d20` 沿用 `feature/rdma-structural-batch226`：门铃 envelope/
scheduler 删除两份状态初始化和一份普通复制 helper，直接复用 rdma_status；legacy
复制保留 null、三枚举未知位/越界拒绝后再调用公共复制。创建名称、factory 窗口、
effect、deadline、锁与 I/O 顺序不变；文件 1,690→1,606 行、47→44 methods，
生产净减 84 行。44 保留方法展开后 token 等价，15 public 声明和六个类壳不变。
新增既有 scheduler test 内的 148-case 矩阵与三项 Python 门禁；最终专项、core
103/86、CMQ 28/11（PROCESS/LOGICAL）、integration 10、E2E 3、Host-memory 3、
PCIe 1、Python 349/349、驱动契约及静态/注释门禁全部通过；三项 E2E 各保留
4 条基线编译告警。最终送测输入 hashes 与当前源码一致。
不合并、不推送，见 `task-rdma-batch231-doorbell-status-report.md`；项目仍 active。

Batch230 基于 `b4d81b0` 沿用 `feature/rdma-structural-batch226`：将两个 projector
的三处原位状态 helper 合为 `rdma_status` 的两个 static automatic 值方法，调用者
直接使用 types，不留转发壳；runtime 状态构造/复制与 direct 构造复用字段实现。
runtime fallback、queue-data null、typed factory 拒绝与 legacy 枚举准入不合并。
生产净减 65 行；264 个保留方法展开后 token 等价，owner/锁/公开业务声明不变。
新增 162-case 初始化/分配矩阵及五项 Python 门禁；最终专项、core 103/86、CMQ 28/11
（PROCESS/LOGICAL）、integration 10、E2E 3、Host-memory 3、PCIe 1、Python 346/346、
驱动契约及静态/注释门禁全部通过；三项 E2E 各保留 4 条基线编译告警。
不合并、不推送，见 `task-rdma-batch230-status-values-report.md`，项目仍 active。

Batch229 基于 `cf502a5` 沿用 `feature/rdma-structural-batch226`：将 runtime 的 20 个
值快照/比较方法迁入单一无状态 projector，公开 cursor 比较保留兼容入口；不新增
owner/实例，58 个公开声明与原锁/账本不变。runtime 4,646→3,814 行、94→74 methods，
projector 884 行/21 methods，生产合计 +53 行，不冒充总代码净减。94 原方法 token
核对等价；独立深复制/24-case 工厂/重入专项、core 103/86、CMQ 28/11
（PROCESS/LOGICAL）、integration 10、E2E 3、Host-memory 3、PCIe 1、Python 341/341、
驱动契约及静态/注释门禁全部通过；E2E 保留基线编译告警。
不合并、不推送，main 保持 `083e0d7`。见
`task-rdma-batch229-runtime-projector-report.md`，项目仍 active。

Batch228 基于 `508ba49` 沿用 `feature/rdma-structural-batch226`：SQ/RQ/SRQ 提交尾段
七处恢复调用统一为一个出口；prior-write gate、五类 NO_SUBMIT、两类 AMBIGUOUS
与已提交直接返回保持原语义。无新增方法/owner/实例状态，engine 9,931→9,929 行，
净减 2 行；方法 token 828→679，139 声明/27 public 与其余 138 正文不变，展开后
token 等价。新增 53-case 矩阵与六项 Python 门禁；修订后专项、core 102/85、CMQ
28/11（PROCESS/LOGICAL）、integration 10、E2E 3、Host-memory 3、PCIe 1、Python
335/335、驱动契约及静态/注释门禁全部通过；E2E 保留基线编译告警。
不合并、不推送，main 保持 `083e0d7`。
见 `task-rdma-batch228-host-producer-exit-report.md`；项目仍 active。

Batch227 基于 `2ee9ff6` 沿用 `feature/rdma-structural-batch226`：把设备发布准备提取为
内部函数，九个准备失败取消续接统一由 I/O task 编排；普通局部值记录不新增 owner，
入口拒绝/reservation-only/完整 pending 三类取消权限不混用。生产净增 15 行，engine
9,916→9,931 行、138→139 methods，I/O task 268→121 行；全部原声明、137 个正文和
I/O 尾段不变，准备段规范化后 token 等价。新增 126-case 准备/取消/恢复矩阵和六项
Python 门禁；最终 126-case focused、core 101/84、CMQ 28/11（PROCESS/LOGICAL）、
integration 10、E2E 3、Host-memory 3、PCIe 1、Python 329/329、驱动契约与静态/注释
门禁全部通过，E2E 保留基线编译警告。不合并、不推送，main 保持 `083e0d7`；详见
`task-rdma-batch227-device-publish-prepare-report.md`，项目仍 active。

Batch226 从已合并的 `083e0d7` 建立独立 `feature/rdma-structural-batch226`：
将 CQ/CEQ/AEQ 设备发布的四类写后失败续接统一到单次循环外的恢复出口；写前 cancel、
异常未写成功、正常成功与 replay 不混用。无新增生产方法/类级状态/owner，engine
9,934→9,916 行；137 个正文、全部 138 声明/类壳不变，发布方法展开后 token 等价。
新增三队列 30-case factory/I/O/commit/admission 矩阵与六项 Python 门禁；最终 focused、
core 100/83、CMQ 28/11（PROCESS/LOGICAL）、integration 10、E2E 3、Host-memory 3、
PCIe 1、Python 323/323、驱动契约与静态检查通过，E2E 保留基线编译警告。main 保持
`083e0d7`；详见 `task-rdma-batch226-device-publish-exit-report.md`，项目仍 active。

Batch225 在 `aa2518f` 基线上将 CQ resize 的 20 个发布前失败续接收束到唯一回滚
出口，发布后仍直接返回并保留新 authority/旧资源 cleanup evidence。不新增生产
组件、方法或状态，engine 9,977→9,934 行；138 声明/类壳不变、137 正文 token 不变，
resize 展开尾段后与基线 token 一致。新增 16-case 故障矩阵及六项 Python 门禁；
排除命名块 disable 跨 engine 嵌套退出风险后，最终使用单次循环 break。最终
core 99/82、CMQ 28/11（PROCESS/LOGICAL）、integration 10、E2E 3、Host-memory 3、
PCIe 1、focused 16-case、Python 317/317、驱动契约及静态门禁均通过；E2E 保留基线
编译警告。仍不合并/推送，详见
`task-rdma-batch225-cq-resize-exit-report.md`，项目仍 active。

Batch224 在 `bbbdc4f` 基线上统一 CQ/event/replay 的 consumer doorbell evidence 和
CI commit 步骤，不改变 caller 的 admission、shadow/WQE 或恢复幂等选择，不新增生产
文件/对象/账本。engine 10,000→9,977 行，原 136 个方法声明不变；133 个正文 token
不变，三个 caller 展开公共步骤后与基线 token 一致。新增 45-case 故障矩阵及六项
Python 门禁；最终 core 98/81、CMQ 28/11（PROCESS/LOGICAL）、integration 10、E2E 3、
Host-memory 3、PCIe 1、focused 45-case、Python 311/311、驱动契约及静态门禁均通过，
E2E 保留已记录的基线编译警告。仍不合并/推送，main 保持
`5f8dfe9`；详见 `task-rdma-batch224-consumer-commit-steps-report.md`，项目仍 active。

Batch223 在 `1a1322c` 基线上继续：25 个 queue-data 值投影/身份谓词集中迁入
`rdma_queue_data_projector`，engine 从 10,872 行/161 methods 降到 10,000 行/136 methods。
新组件 889 行，两生产文件合计 +17 行，属于职责收缩而非总代码净减。全部 161 方法
token（限定/两处改名/static 除外）与 27 个公开业务声明核对一致；新增独立值边界
与六项 Python 结构门禁；最终 core 97/80、CMQ 28/11（PROCESS/LOGICAL）、
integration 10、E2E 3、Host-memory 3、PCIe 1、focused snapshot、Python 305/305、
驱动契约及静态门禁均通过，E2E 保留已记录的基线编译警告。
本地主线仍为 `5f8dfe9`，继续使用上一批工作树/分支，不合并或推送；详见
`task-rdma-batch223-queue-data-projector-report.md`，项目计划仍 active。

已按用户要求先完成本地合并：`main` 为 `5f8dfe9`，覆盖 Batch160–221；主线原有
reset 改动单独保存在 `bec0f8f`，最终源码/测试/构建输入与已验证 Batch221 快照一致。
后续 Batch222 改在 `.worktrees/rdma-structural-batch222`、分支
`feature/rdma-structural-batch222` 继续，不推送远端，旧工作树和历史记录保留。
本批复用 queue-data 既有状态字段 helper，生产净减 24 行，不新增生产组件；新增
完整字段、null/自复制、工厂次数/顺序和无虚拟回调测试。最终 core 97/80、CMQ 28/11
（PROCESS/LOGICAL）、integration 10、E2E 3、Host-memory 3、PCIe 1、Python 299/299、
驱动契约与静态门禁全部通过；E2E 每项既有 4 个编译警告单列。本批尚未合回 main。
详见 `task-rdma-batch222-queue-status-transfer-report.md`，项目仍 active。

Batch221 继续从大文件职责入手：47 个快照投影/身份比较方法集中迁入无状态
`rdma_resource_projector`，manager 减少 2,214 行，剩余 7,936 行/139 methods。
公开 API、唯一账本 owner、authority/clone 回调和 commit 门禁保持原位；两文件合计
净增 3 行，不将职责分离称为总代码量下降。最终 core 97/80（PROCESS/LOGICAL）、
integration 10、CMQ 28/11、E2E 3、Host-memory 3、PCIe 1、Python 299/299、驱动契约
和静态门禁全部通过；证据与既有编译警告见 `task-rdma-batch221-resource-projector-report.md`。
该批不关闭项目级 Phase B/D/E、跨 owner 原子性和最终可读性验收，计划仍 active。

历史起点：Batch159 曾合并到主线 `94ba894`（`refactor: consolidate CMQ transport envelope decode`）。
当时 Phase 2 工作树为
`/home/ryan/workspace/ryan/rdma_work/.worktrees/rdma-cmq-structural-phase2-batch160`，分支为
`feature/rdma-cmq-structural-phase2-batch160`，以 `94ba894` 为基线；该树 Batch160–221
已在本轮分组提交并合入上述主线，不再是当前开发位置。计划保持 `active`，不得把
focused GREEN 解释为整份重构完成。

Batch217 在同一未提交工作树继续：restore/mark-error 统一双账本提交，单资源和 Function
teardown 统一整批释放 commit，lookup 不再隐式写 registry；补充 completion 重入与
四种 restore commit 冲突测试，并修复非零 MR reservation 的 lkey index 初值。
本批 core 97/80（PROCESS/LOGICAL）、integration 10、CMQ 28/11、三项 E2E、
Host-memory/PCIe adapter、驱动契约、Python 293/293 和静态门禁已通过；结果与未关闭项
记录在 `task-rdma-batch217-resource-release-atomicity-report.md`，不复用旧批次 GREEN。

Batch218 继续将 9 个普通生命周期入口纳入统一强制 epoch/source 提交契约，删除
helper 默认关闭 snapshot 的分支；QP exact-old recovery 保留原错误优先级。
新增逐真实 clone/authority/completion 窗口注入测试，最终回归结果记录在
`task-rdma-batch218-registry-snapshot-contract-report.md`，计划仍 active。
本批 core 97/80、integration 10、CMQ 28/11、E2E 3、Host-memory 3、PCIe 1、
驱动契约、Python 293/293 和静态门禁均已通过；源码指纹及保留的早期失败见报告。

Batch219 统一普通对象/Function 的 allocator 补偿，旧预留失败只回收自己的 local ID，
不破坏窗口内成功分配的 cursor/serial/binding；epoch 在消费完成时冻结，覆盖返回
status 的 factory 重入。五种交错场景、耗尽/代际/幂等边界和两个真实 factory 重入
已在最终 focused 通过；core 97/80（PROCESS/LOGICAL）、integration 10、CMQ 28/11、
E2E 3、Host-memory 3、PCIe 1、Python 293/293、驱动契约和静态门禁全部通过。
记录见 `task-rdma-batch219-allocator-compensation-report.md`；registration/admission
原子性、大文件收缩和包 DAG 仍未关闭，计划继续 active。

Batch220 继续把 admission 前的 epoch 冻结、锁外 binding 准备和最终 ID/serial 消费
纳入同一公共提交路径，不新增 owner/账本/锁；过期或饱和 epoch 拒绝新的 reservation。
4 个 fixture、131 个 factory 窗口及额外 guard/epoch/generation 故障的最终 focused 已
通过；core 97/80（PROCESS/LOGICAL）、integration 10、CMQ 28/11、E2E 3、Host-memory 3、
PCIe 1、Python 293/293、驱动契约及静态门禁全部通过。
记录见 `task-rdma-batch220-allocator-admission-commit-report.md`，大文件职责
收缩、跨 owner 组合验收和包 DAG 仍保持 active。

## 批次进展记录（更新至 2026-09-24）

- Batch100 已关闭本项目 RC raw `INLINE_SGB` 的固定 512B/32-chunk 容量拒绝 guard；这不等于
  广义 Phase 1C F2 收口，`sge_num` canonical-authority/whole-plan 工作仍暂停。
- Batch101 已关闭跨 context reset 的 prepare/validate/commit 半提交窗口；Batch102 完成
  QP/queue transient dynamic-array alias 审计（GREEN audit-only），保留 manager 的
  authority-aware projector 边界，未引入 executor deep-clone 或外部依赖改动。
- Batch104 在当前源码边界完成 parent/core gate：CMQ 28/28 process、11/11 logical，core
  95/95 process、78/78 logical，严格 UVM warning/error/fatal 均为 0/0/0；Batch103 focused
  reset/codec follow-up 同样保持 GREEN。完整日志与 SHA 由 structural-refactor evidence 索引。
- Batch105/106 已完成当前 reset 事务边界的 focused 收口：candidate detached value-graph
  seal 拒绝跨 context hostile mutation；coordinator registration baseline/incarnation、
  duplicate UID/global-ID、PF/Host/Device 及 router-local Host epoch capacity 均在提交前
  预检，Function epoch map 采用 detached staging；env-local reset guard 拒绝同步重入。
  最新 focused 日志必须与当前源码指纹一并冻结，不能复用早期源码边界的旧 hash。
- Batch107 修复并覆盖 reset 后旧 registration snapshot 的幂等快路径缺口：coordinator
  先解析 current incarnation，只有 `applied_resets == 0` 才接受完全相同的旧 snapshot；
  reset 后旧值返回 `RDMA_SC_STALE_GENERATION`，current incarnation 才能刷新 baseline。
  当前源码已刷新 integration regression（8/8）、CMQ gate（28/28 process、11/11 logical）
  与 core regression（95/95 process、78/78 logical），严格 UVM warning/error/fatal 均为
  0/0/0；完整指纹见 `evidence/batch107.*`。
- Batch108 对 coordinator↔env↔router 的跨环境 ownership、同步 callback 重入、direct
  context reset、detach/rebind 和 active-mapping 生命周期做了只读审计；结论与下一批所需
  的一对一/aggregate、lease/token、detach/close 契约记录在
  `task-cmq-batch108-coordinator-ownership-audit.md`，未在缺少架构选择时擅自改 API。
- Batch109 采用严格一对一 ownership：coordinator lease/token、reset transaction、
  bilateral router attach/detach、一次性 attach capability、device-env `close()` 和
  detached candidate provenance seal 已落地；leased coordinator 下 tokenless direct
  registration/reset/context mutation/router rebind fail-closed，standalone/no-lease
  context 保留兼容 reset 语义。focused 与 integration regression（10/10）已在当前
  源码边界通过，并刷新 CMQ gate（28/28 process、11/11 logical）与 core regression
  （95/95 process、78/78 logical）；详见 `task-cmq-batch109-coordinator-ownership-and-close-report.md`。
- Batch110 在 coordinator 的四个公开 `request_*` reset wrapper 外安装同步
  `m_reset_operation_active` publication guard，并把 implementation 与 guard 清理拆开；
  同一 SystemVerilog 调用栈的 callback 嵌套现在 fail-closed 返回
  `RDMA_SC_RESOURCE_BUSY`，implementation 的 null status 统一转为 `INVALID_STATE`。
  guard 明确不是跨线程/跨进程抢占式锁。生命周期 fixture 同步修正 router attach 后再注入
  local epoch 的顺序，并按 legacy 空 Function scope 的既有 Device reset 语义校正断言。
  修复后 focused 6 项、integration 10/10、CMQ 28/28 process+11/11 logical、core
  95/95 process+78/78 logical 均为 GREEN，严格 UVM warning/error/fatal 全部 0/0/0；
  证据见 `evidence/batch110.*` 与 `task-cmq-batch110-reset-publication-guard-report.md`。
- Batch111 继续封闭 publication window 内未经过统一 lease validator 的同步 mutation：
  `acquire_lease()`、`begin_reset()`、`end_reset()`、legacy router attach 和已绑定 router
  的 direct configure/epoch callback 均回到同一 `reject_mutation_during_reset_operation()`
  guard；Host epoch capacity/advance 改用 coordinator-issued 一次性 opaque capability，
  legacy callback 不能再伪造 `allow_active=1`。当前 worktree 的 focused coordinator/lifecycle、
  integration 10/10、CMQ 28/28 process+11/11 logical、core 95/95 process+78/78 logical
  与 Python 292 均通过，严格 UVM warning/error/fatal 为 0/0/0；全目录 scanner 覆盖
  185 个 `.sv`、2 个 `.svh`，共 5,387 个 function/task、0 diagnostics，style/diff、manifest、
  queue/profile/Phase-1A auxiliary gates 也通过。不能引用错误 worktree 的旧 core 失败日志。
  Host-router tokenless dataplane `allocate/write/read/release/release_opaque` 未纳入本批同步
  guard，仍保留为更深 reset-admission/lifecycle OPEN。详见
  `task-cmq-batch111-reset-mutation-guard-report.md` 与 `evidence/batch111.*`。
- Batch112 将 Host-router tokenless dataplane 纳入 reset admission：绑定 coordinator 时
  `allocate/write/read` 在 publication-only 或 active transaction 窗口内 fail-closed，
  manager call count、router ledger 和 read output 保持无副作用；外部 manager 返回后
  若同步开启 reset，`allocate()` 以 opaque release 回滚 backing；`release/release_opaque`
  保留 cleanup/drain 语义；Host reset 后 fresh Function incarnation 的 dataplane 恢复
  路径已覆盖。当前 focused host-router/coordinator、integration 10/10、Python 292 与
  changed-SV style/diff 均 GREEN，严格 UVM warning/error/fatal 为 0/0/0；详见
  `task-cmq-batch112-tokenless-dataplane-admission-report.md`。本批仍不把同步 admission
  误称为跨线程原子锁。
- Batch113 在 queue-data 的 SQ external-SGB writer 前增加 detached image authority
  gate：写入前重新派生 canonical payload mode/count，检查压紧 descriptor 数量，并
  用同一已编码 SQE image 的 signature 验证待写 512-byte SGB；本批 fixture 覆盖
  count、mode 和 descriptor length 的 post-encode mutation，均在首次 Host-memory
  write 前拒绝。
  focused `rdma_queue_data_engine_post_test`、SQE codec 三套测试和静态门禁保持 GREEN；
  该批只关闭 SGB payload writer seam，不代表广义 Phase 1C F2 收口。详见
  `task-cmq-batch113-sgb-writer-authority-report.md`。
- Batch114 修复 Batch113 暴露的 UD transport-aware effective mode 缺口：共享
  `derive_payload_authority()` 现在把 UD 非零 inline/1–2 SGE 统一映射到驱动使用的
  `INLINE_SGB`/`SGE_SGB`，而 zero-byte inline 与 RC direct-SGE 保持原语义；真实 UD
  probe 的 1B inline、1-SGE、2-SGE writer 以及三套 SQE/queue codec focused 均 GREEN。
  该批关闭 mode 对齐 seam，但完整公开 post/replay 矩阵和广义 F2 仍开放。详见
  `task-cmq-batch114-ud-sgb-effective-mode-report.md`。
- Batch115 将 `rdma_queue_data_engine::post_recv()` 的 RQ/SRQ target-resolution
  从 posting pipeline 提取为只读 `resolve_receive_target()` helper：completion-QP
  选择、QP link 查找、SRQ 完整 handle-incarnation 比较和 RQ/SRQ attachment lookup
  现在集中在一个 canonical target 阶段；owner、route/epoch、reserve、write、doorbell
  和 commit 顺序保持不变。当前 post/recovery focused 与公开 UD 正向/恢复探针均
  GREEN；该批不声称已完成 SRQ 全量 lifecycle 矩阵、广义 F2 或整份结构重构。详见
  `task-cmq-batch115-receive-target-resolution-report.md`。
- Batch116 将 `replay_pending()` 的 host-producer recovery 分支提取为受保护的
  `replay_host_producer_pending()` task：SQ external-SGB route/model、SGB/WQE
  write/readback、producer doorbell、recovery commit 与 completion 现在位于单一
  producer 阶段；device-producer 与 consumer recovery 仍由主 task 管理，避免 DMA
  方向、completion release 和 evidence 混用。提取同时把 helper 内的 null status
  转为 `RECOVERY_REQUIRED` 的 fail-closed 结果，保留 `NO_SUBMIT`/`AMBIGUOUS`/
  `SUCCESS` evidence 顺序、冻结 cursor 和 pending 生命周期。当前 recovery/post
  focused 均 GREEN；本批不声称已完成完整 SRQ/跨队列生命周期、广义 F2 或整份结构
  重构。详见 `task-cmq-batch116-host-producer-recovery-report.md`。
- Batch117 将 `recover_queue()` 的 claimed attachment 定位抽为只读
  `find_claimed_recovery_attachment()`：完整 queue incarnation 比较、null/runtime
  门禁和 `RECOVERY_REQUIRED` 状态筛选集中在独立查询阶段；unclaimed handoff 仍先于
  查询，matching 多 runtime 继续 fail-closed 为 `INVALID_STATE`，无命中仍交给
  reservation-only 分支。helper 不查询 pending/reservation，不执行 detach、Host-memory
  I/O、MMIO 或 runtime mutation。当前 device-publish/recovery/post focused 均 GREEN；
  本批不声称已完成 SRQ/跨队列 lifecycle、广义 F2 或整份结构重构。详见
  `task-cmq-batch117-claimed-recovery-scan-report.md`。
- Batch118 将 `recover_queue()` 的 reservation-only 候选扫描抽为只读
  `collect_reservation_only_candidates()`：它按 `attachments` 的既有 foreach 顺序，
  以完整 queue incarnation 收集 non-null candidate/runtime 的借用引用；不查询
  reservation/pending，不修改 runtime、ledger、索引、cursor 或生命周期。caller 仍
  保留 reservation query 的 null/status 映射、action 判断、detach 顺序和首错优先级，
  因而本批只关闭结构 seam，不改变 reservation-only 多匹配或 hostile action 契约。
  当前 device-publish/recovery/post focused、style/diff、queue/profile、manifest/keyword
  与 Python 门禁均 GREEN；全目录中文 method/comment scanner 仍沿用 Batch111 历史证据，
  待后续源码边界复审时刷新；计划继续保持 `active`。详见
  `task-cmq-batch118-reservation-candidate-scan-report.md`。
- Batch119 在 `recover_queue()` 的控制面与 reservation/retry 交界处补齐 recovery
  action contract：非法 action 和未确认 retry 在 unclaimed admission、reservation
  query 与 runtime handoff 之前 fail-closed；reservation-only 路径先完成全部 matching
  candidate 的 reservation query，再按 cardinality 判定，多个有效 snapshot 返回
  `RDMA_SC_INVALID_STATE` 且不提前 detach；retry 先取得 `query_pending()` 快照，再
  记录 runtime confirmation，避免 query 失败遗留一次性授权。device-publish fixture
  覆盖未确认 retry 的 evidence/admission 保序和多 reservation ambiguity；三套 VCS53
  focused、changed-SV style/diff、queue/profile、manifest/keyword、Phase-1A 与 Python
  门禁均 GREEN，queue-data engine 与 device-publish test 的逐文件复审分别为 137/122
  个 method、0 diagnostics。计划继续保持 `active`；完整 SRQ/跨队列并发、device/consumer
  recovery 全阶段、query/recover 原子并发与全目录后续生命周期审计仍开放。详见
  `task-cmq-batch119-recovery-action-contract-report.md`。
- Batch120 将 `replay_pending()` 的 device-producer 分支抽为受保护的
  `replay_device_producer_pending()` task：reservation、route/epoch、完整 queue
  incarnation、DEVICE_WRITE、write-attempt marker、readback、recovery commit 与
  completion 现在位于单一 device-DMA 阶段；host-producer 与 consumer 分支继续由
  caller 按 evidence 类型选择，既有错误证据和 cursor 生命周期不变。三套 queue-data
  VCS53 focused、changed-SV style/diff、queue/profile 门禁均 GREEN；当前 source/test
  逐文件 method/comment 复审为 138/122 个 method、0 diagnostics。计划继续保持
  `active`；consumer recovery、跨队列并发、SRQ 全生命周期和全目录后续审计仍开放。
  详见 `task-cmq-batch120-device-producer-recovery-report.md`。
- Batch121 将 `replay_pending()` 的 consumer 分支抽为受保护的
  `replay_consumer_pending()` task：CQ route/QP/SRQ identity、CQC shadow 或 consumer
  doorbell、CQ consumer commit、CQ→WQ release gate 与 completion 现在位于单一
  consumer recovery 阶段；caller 只保留 attachment/pending 校验、`pending_next_cursor()`
  和阶段分派，原语句顺序与 failure evidence 不变。三套 queue-data VCS53 focused、
  changed-SV style/diff、queue/profile、manifest/keyword、Phase-1A 与 Python 292 门禁
  均 GREEN；queue-data engine/device-publish test 逐文件 method/comment 复审为
  139/122 个 method、0 diagnostics，全目录 scanner 为 185 个 `.sv`、2 个 `.svh`、
  5,405 个 method、0 diagnostics。计划继续保持 `active`；跨队列并发、SRQ 全生命周期、
  device/consumer 组合 recovery 与全目录后续 ownership 审计仍开放。详见
  `task-cmq-batch121-consumer-recovery-report.md`。
- Batch122 将 `lookup_local_resource()` 的 registry 遍历抽为只读
  `scan_local_resource_matches()`：Function UID/object/generation、kind/local-id、
  released/stale 状态与 multiple-live cardinality 现在集中在无 status/factory 副作用的
  扫描阶段；caller 只有确认唯一 live candidate 后才执行 detached projection，避免歧义
  路径发布半成品快照。resource-manager、AEQE route、queue recovery/post focused VCS53、
  changed-SV style/diff、queue/profile、manifest/keyword 与 Phase-1A 门禁 GREEN；全目录
  scanner 为 185 个 `.sv`、2 个 `.svh`、5,406 个 method、0 diagnostics。计划继续保持
  `active`；manager-level 并发、duplicate-live fixture、跨 incarnation lifecycle、
  consumer/device 组合 recovery 与全目录 ownership 审计仍开放。详见
  `task-cmq-batch122-local-resource-match-scan-report.md`。
- Batch123 将 `replay_consumer_pending()` 的只读 authority preflight 提取为受保护的
  `validate_consumer_recovery_authority()`：集中 pending evidence shape、route/epoch、CQ
  completion target、routed QP identity、SQ/RQ/SRQ route、WQ attachment 与 release-range
  校验；仅返回借用的 `link`/`wqe_attachment`/status，不写 pending、cursor、ledger、
  Host-memory、MMIO 或 scheduler，也不取得生命周期所有权。`replay_consumer_pending()`
  仍负责 null gate、调用 helper、shadow/doorbell、CQ consumer commit、CQ→WQ release 与
  completion，`pending_next_cursor()` 仍由 `replay_pending()` 在分派前统一执行。三套
  queue-data VCS53 focused、style/diff、queue/profile、manifest/keyword、Phase-1A 与
  Python 门禁均 GREEN；全目录 scanner 为 185 个 `.sv`、2 个 `.svh`、5,407 个 method
  （`.sv` 5,405、`.svh` 2）、0 diagnostics，queue-data engine/device-publish test 逐文件
  复审为 140/122 个 method。计划继续保持 `active`；engine-level 全局锁、CEQ/AEQ
  malformed retry、SRQ/跨队列 lifecycle、device+consumer 组合和最终 ownership 审计仍开放。
  详见 `task-cmq-batch123-consumer-authority-report.md`。
- Batch124 将 `replay_consumer_pending()` recovery-only 的 CQ→WQ release 阶段提取为
  受保护的 `release_consumer_pending_wqe()` task：`begin_consumer_release_noalloc()`、
  frozen completion index/wrap 的 `release_cq_wqe()`、null-status 归一化、
  `finish_consumer_release_noalloc()` 与失败 recovery evidence 现在由同一 seam 收束；
  caller 继续负责 consumer authority、shadow/doorbell、CQ commit 与最终 completion，
  poll 路径不被强行统一，保持其 live-CQE/cq-shadow 契约。三套 queue-data VCS53
  focused、style/diff、queue/profile、manifest/keyword、Phase-1A、Python 与全目录
  中文契约 scanner 均 GREEN；当前全目录为 185 个 `.sv`、2 个 `.svh`、5,408 个
  method、0 diagnostics，queue-data engine/device-publish test 逐文件 method 复审为
  141/122。计划继续保持 `active`；全局锁、poll/recovery 全阶段组合、CEQ/AEQ malformed
  retry、SRQ/跨队列 lifecycle、device+consumer 组合和最终 ownership 审计仍开放。详见
  `task-cmq-batch124-consumer-release-report.md`。
- Batch125 将 `poll_cqe_once` 首次 runtime mutation 之前的候选准备阶段提取为受保护的
  `stage_cq_poll_candidate()`：WQ route/release snapshot、completion/result、next cursor、
  prepared pending 与 CQC shadow/legacy doorbell payload 现在集中在只做 detached staging
  的 function；caller 继续保留 `enter_recovery_prepared()`、shadow/doorbell、CQ commit、
  CQ→WQ release 和 completion。caller 额外按完整 QP/SRQ incarnation relookup WQ output，
  并对所有 staged output 做 fail-closed 校验。poll/device-publish/recovery/post 四套
  queue-data VCS53、style/diff、queue/profile、manifest/keyword、Phase-1A、Python 与
  全目录中文契约 scanner 均 GREEN；当前全目录为 185 个 `.sv`、2 个 `.svh`、5,409 个
  method、0 diagnostics，queue-data engine/device-publish test 逐文件 method 复审为
  142/122。计划继续保持 `active`；RQ/SRQ 与 UD 正向 poll、legacy descriptor 分支、
  engine-level 全局锁、poll/recovery 全阶段组合、CQ→WQ 跨队列并发和最终 ownership
  审计仍开放。详见 `task-cmq-batch125-poll-candidate-staging-report.md`。
- Batch126 将 `stage_cq_poll_candidate()` 内的 CQ completion target 解析提取为只读
  `resolve_cq_poll_wq_target()`：按冻结 CQE receive 标志和 QP link 统一选择 SQ、私有
  RQ 或共享 SRQ，集中校验完整 handle incarnation、runtime/access、entry geometry、
  kind 与 backing role；helper 不 reserve/snapshot ledger、不进入 pending、不写 Host-memory
  或 MMIO。poll caller 继续保留完整 QP/SRQ relookup 防御、`enter_recovery_prepared()`
  首个 mutation 及 shadow/doorbell→CQ commit→CQ→WQ release 顺序。当前 poll/post/
  recovery/device-publish 四项 wrapper 均已在最终源码边界通过 PROCESS/LOGICAL PASS、
  UVM 0/0/0，静态门禁与全目录 scanner 同样 GREEN；计划继续保持 `active`，
  RQ/SRQ 与 UD 正向 poll 的实际端到端矩阵、legacy descriptor 分支、engine-level 全局
  锁、poll/recovery 组合、CQ→WQ 跨队列并发和最终 ownership 审计仍开放。详见
  `task-cmq-batch126-poll-target-resolution-report.md`。
- Batch127 将 `poll_cqe_once()` 首次 `enter_recovery_prepared()` 之后的 live-CQE
  mutation/commit 阶段提取为 `commit_cq_poll_candidate()`：统一 shadow/doorbell、MMIO
  evidence、CQ consumer commit、CQ→WQ begin/release/finish、recovery completion 与
  result publish；caller 保留 occupancy/read/decode/route、detached staging 和 admission
  前 WQ identity relookup。四项 queue-data wrapper 均在最终源码边界通过 PROCESS/LOGICAL
  PASS、UVM 0/0/0，全目录中文契约 scanner 为 5,411 methods/0 diagnostics；计划继续
  保持 `active`，shadow null-status 归一化、RQ/SRQ 与 UD 正向 poll、legacy descriptor
  分支、engine-level 全局锁、poll/recovery 组合、CQ→WQ 跨队列并发和最终 ownership
  审计仍开放。详见 `task-cmq-batch127-poll-commit-candidate-report.md`。
- Batch128 将 CEQ/AEQ poll 在 prepared pending 之后重复的 consumer commit 阶段提取为
  `commit_event_poll_candidate()`：统一 admission、consumer doorbell、MMIO evidence、
  CI commit、failure continuation、recovery completion 和 route-miss/result publish；
  两条入口仍分别负责 image decode、事件 route、CQ flush secondary owner 与 detached
  candidate 准备，CQ 专用 WQE release 不被合并。`rdma_queue_data_engine_poll_test`、
  `rdma_queue_event_route_consume_test` 与 `rdma_aeqe_route_test` 在最终源码边界均
  PROCESS/LOGICAL PASS、UVM 0/0/0，全目录中文契约 scanner 为 5,412 methods/0 diagnostics；计划继续保持 `active`，RQ/SRQ 与 UD 正向 poll、
  legacy descriptor、malformed retry、staged WQ 二次 geometry/role revalidation、
  engine-level 全局锁、poll/recovery 组合、跨队列并发和最终 ownership 审计仍开放。
  详见 `task-cmq-batch128-event-commit-candidate-report.md`。
- Batch129 将 CQ poll 的 WQ target contract 再拆成只读 selector 与共享 validator：
  `select_cq_poll_wq_target_contract()` 只依据冻结 `cqe.rq_cqe`/`link.qp_h`/`link.srq_h`
  推导 target handle、runtime kind 和 backing role，`validate_cq_poll_wq_attachment()`
  统一检查 resource kind、runtime/access、depth、`RDMA_WQE_BYTES` geometry、kind/role
  及完整 handle incarnation；`resolve_cq_poll_wq_target()` 改为 selector→lookup→validator，
  `poll_cqe_once()` 在首次 `enter_recovery_prepared()` 前重新推导冻结 target，拒绝
  `pending.completion_wq_kind` 漂移；resolver 和 poll admission 都会在 selector output
  为空或 incarnation 不一致时从冻结 link 回填 canonical handle，再按同一 contract
  validator/relookup。当前已通过 `rdma_queue_data_engine_poll_test`、
  `rdma_queue_data_engine_post_test`、`rdma_queue_data_engine_recovery_test` 的
  PROCESS/LOGICAL PASS、UVM 0/0/0；`git diff --check` 与 changed-SV style 通过，
  全量 scanner 已覆盖 185 个 `.sv`、2 个 `.svh`，共 5,416 methods（`.sv` 5,414、
  `.svh` 2），0 diagnostics；queue/profile/manifest/keyword/Phase-1A/Python 292 门禁
  均通过，`rdma_queue_data_engine_device_publish_test` 也已 PROCESS/LOGICAL PASS、
  UVM 0/0/0。selector 的
  class-handle output 在 simulator 跨 function 边界的保真性、完整 canonical-relookup
  hostile poll fixture、snapshot 后二次 alias 审计仍是明确 OPEN 边界；计划继续保持
  `active`。详见 `task-cmq-batch129-poll-wq-contract-report.md`。
- Batch130 在既有重构后的 queue-data poll 入口上补充私有 RQ 正向 receive CQE 的端到端
  测试，不修改生产代码：`make_cqe_for_outstanding_receive()` 显式构造
  `rq_cqe=1`、`RDMA_CQE_VARIANT_RQ_SRFQ`、`rqe_cpl=1` 的 CQE，
  `check_private_rq_receive_cqe_e2e()` 依次执行 `post_recv`→公开 `publish_cqe`→
  `poll_cqe`，并断言 `RDMA_WR_RECV`、QPN/WQE index+wrap、`wr_id`、单个 released
  slot、RQ/SQ/CQ occupancy、RQ/CQ producer-consumer cursor 以及第二次
  `RDMA_SC_QUEUE_EMPTY`。当前四项 queue-data focused wrapper（poll/post/recovery/
  device-publish）均 PROCESS/LOGICAL PASS、UVM warning/error/fatal `0/0/0`；全目录
  中文契约 scanner 刷新为 185 个 `.sv`、2 个 `.svh`、5,418 methods（`.sv` 5,416、
  `.svh` 2），0 diagnostics，`git diff --check` 与 changed-SV style 通过。私有 RQ
  正向路径已取得证据，但 SRQ/UD 正向 poll、legacy descriptor、hostile staged/
  recovery 组合、跨队列并发与最终 ownership 审计仍开放。详见
  `task-cmq-batch130-private-rq-cqe-poll-report.md`。
- Batch131 将 `poll_cqe_once()` admission 前的 staged WQ canonicalization 提取为只读
  `canonicalize_cq_poll_wq_attachment()`：它按冻结 CQE/link 重建 target contract，先拒绝
  `pending.completion_wq_kind` 漂移，再统一执行 attachment geometry/role/incarnation
  validator；staged alias 失败时只按同一 frozen target 做一次 canonical registry
  relookup，且不建立 pending、不写 ledger、Host-memory 或 MMIO。`poll_cqe_once()` 只保留
  staging 输出完整性检查与一次 helper 调用，首次 `enter_recovery_prepared()` 及后续
  commit 顺序不变。
  同批为 probe 增加 null、entry-size、role、runtime-depth、stale-generation detached
  alias 和 pending-kind hostile cases，确认 canonical relookup 成功或 fail-closed；poll
  测试补充 UD SEND 的公开 `post_send`→`publish_cqe`→`poll_cqe` 正向链，断言
  `RDMA_CQE_VARIANT_UD`、UD source-QPN/SMAC/VLAN overlay、SQ/CQ release 与 RQ 不变。
  当前 poll/post/recovery/device-publish 四项 queue-data wrapper 均在最终源码边界
  PROCESS/LOGICAL PASS、UVM warning/error/fatal `0/0/0`；全目录 scanner 刷新为 185 个
  `.sv`、2 个 `.svh`、5,422 methods，0 diagnostics，Python 292 与 style/diff/queue/
  profile/manifest/keyword/Phase-1A 门禁通过。该批仍不声称 SRQ 全生命周期、UD receive/
  replay、legacy descriptor、poll/recovery 全阶段组合、跨队列并发或最终 ownership 审计
  已完成；详见 `task-cmq-batch131-poll-wq-canonicalization-report.md`。
- Batch132 在不改生产路径的前提下补齐 shared-SRQ receive CQE 的公开正向证据：poll
  测试内新增独立的 SRQ/QP 创建与销毁 helper，避免借用其他测试 class 的隐含上下文；
  `post_recv(target_h=SRQ, completion_qp_h=QP)`→`publish_cqe(rq_cqe=1,srfq=1)`→
  `poll_cqe` 真实执行，并断言 `RDMA_CQE_VARIANT_RQ_SRFQ`、authoritative
  `local_srq_id` 的 `srfqn`、`srfqe_index/wrap`、`rqe_cpl`、SRQ ledger release、
  CQ cursor/occupancy 与基础私有 RQ 不变。SRQ wire ID 使用 `local_srq_id`，不把
  manager registry 的 `handle.object_id` 当作 SRFQN；QP→SRQ→fixture cleanup 在
  所有 early-disable 路径保持幂等。poll/post/recovery/device-publish 四项 focused
  wrapper 均 PROCESS/LOGICAL PASS、UVM 0/0/0；当前 scanner 为 185 个 `.sv`、2 个
  `.svh`、5,426 methods、0 diagnostics。该批只关闭 shared-SRQ receive poll 的窄
  证据 seam；在 Batch133 之前，UD receive/replay、publish variant consistency、legacy descriptor、
  poll/recovery 组合、跨队列并发与最终 ownership 审计仍开放；详见
  `task-cmq-batch132-shared-srq-cqe-poll-report.md`。
- Batch133 在重构后的 queue-data publish/poll 共用同一组 CQE variant authority gate：
  `resolve_cqe_variant_for_route()` 按冻结 `link.transport` 选择 RC/UD/RQ_SRFQ overlay，
  `validate_cqe_variant_consistency()` 在 `publish_cqe()` 的 WQE lookup 与 producer
  reservation 之前拒绝显式 variant 漂移；新增
  `validate_cqe_srfq_route_consistency()` 要求 send CQE 的 `srfq=0`，并要求 receive
  CQE 的 `srfq` 与冻结 `link.srq_h != null` 一致。`resolve_cqe_variant_for_image()`
  在 poll decode 前复用同一 topology gate，因而同一 RC-attached CQ 上交错的 RC/UD/URC
  QP 仍按 QP link transport 解码，不读取 CQ attachment transport 猜测 union。测试补齐
  RC/UD/RQ_SRFQ mismatch、private-RQ/shared-SRQ SRFQ 拓扑 hostile case 的 publish
  admission 原子性；shared-SRQ poll 测试再以受控 probe 在已提交 CQE 槽位只翻转
  SRFQ wire bit，验证 poll-side rejection 在 image decode 前不改变 occupancy/cursor，
  恢复原像后继续正向链。双环境 fixture 同时显式启用 CQC context shadow，保持公开
  poll 契约可执行。当前
  poll/post/recovery/device-publish focused 均 PROCESS/LOGICAL PASS、UVM 0/0/0；
  锁定依赖后的 transport E2E 通过核心/网络正向矩阵，并在 net_packet 层按预期拒绝
  URC READ；最终源码边界的全目录中文契约 scanner 为 185 个 `.sv`、2 个 `.svh`、
  5,431 methods、0 diagnostics，Python 292、manifest/keyword、queue/profile、
  Phase-1A、changed-SV style 与 `git diff --check` 均通过。该批只关闭
  publish/poll variant admission 的局部 seam，UD receive/replay、legacy descriptor、
  private-RQ poll hostile、poll/recovery 组合、跨队列并发、全量 malformed matrix、
  最终 ownership 审计仍开放；
  详见 `task-cmq-batch133-cqe-variant-consistency-report.md`。
- `pcie_work` 已按用户授权纳入本项目依赖锁：commit
  `1a80801e7d336ceeb492e7cdf57ba26ef27c2456`、闭包 tree SHA-256
  `8a9853c2cb618b5f73f4d2fed2167fad3a7b08bce37298cfef9ea159b1c5feb1`，75 个锁定文件均为
  `APPROVED`；`host_mem` 同时固定为 commit `365b7553fc7dac6b4ad55886a8e4869153607c28`，
  tree SHA-256 `b9cd7d686c954823bdeafcea2f02013908fed51db5a8f4d39e96e5e877f6c770`。两项
  clean-clone lock verify 均通过。53 机登录 bash 中 pcie adapter（UVM INFO 4/0/0/0）与
  SR-IOV（INFO 260/0/0/0）均 compile/elab/link/exit 通过；host_mem 三项 regression
  为 INFO 17/17/4、UVM 0/0/0 且 leak=0。详见 `docs/rdma-pcie-work-adoption-evidence.md`。
  这不代表 pcie_work 更广 error/ordering/组合矩阵已完成，也不修改外部源码；上游缺少
  root README/LICENSE/tag 的 provenance 风险继续保留。
- Batch134 在同一锁定 `pcie_work` 快照上补充供应商 TL-only error/ordering smoke：
  `pcie_tl_smoke_err_test` 为 UVM `5/0/0/0`，ordering smoke 为 `6/0/0/0`，scoreboard
  `2 requests / 1 completion / 1 matched`。该批只证明供应商本体的基础错误/顺序契约，
  未证明 RDMA adapter 的 poisoned、timeout、malformed TLP、tag-conflict、DMA/backpressure
  或 SR-IOV stress 组合。
- Batch135 在 `rdma_queue_data_engine_poll_test` 中补充公开 UD 私有 RQ 的
  Host-memory write fault → confirmed replay → receive CQE poll/release 窄闭环：未确认
  retry 返回 `RDMA_SC_INVALID_ARGUMENT`，confirmed replay 逐字节复核 pending image，
  随后断言 RQ/CQ occupancy、cursor、QPN、`wr_id` 和单槽 release；53 机最终源码边界
  compile/elab/link/PROCESS/LOGICAL 均 PASS，UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0`。
  详见 `task-cmq-batch134-pcie-work-error-ordering-report.md` 与
  `task-cmq-batch135-ud-receive-replay-report.md`。两批仍不关闭完整外部 regression、UD
  多包/多队列 replay、malformed recovery、legacy descriptor、跨队列并发和全局锁。
- Batch136 在 `rdma_queue_lifecycle_executor.sv` 中把 `rollback_created()` 的三处
  legacy `cmq.execute()` 结果归一化提取到 `execute_queue_command()`，并允许调用方传入
  阶段化 null-status/completion 诊断消息；原有 post-execute `live_binding_fence()`
  checkpoint、ambiguity 判定和失败即返回顺序保持不变。`rdma_queue_lifecycle_test` 与
  `rdma_queue_recovery_test` 均在 53 机最终源码边界 PROCESS/LOGICAL PASS、UVM
  `INFO=3/WARNING=0/ERROR=0/FATAL=0`。这是兼容 legacy consumer 的局部去重，不是
  `execute_observed()` 全量迁移；详见
  `task-cmq-batch136-legacy-rollback-execution-seam-report.md`。
- Batch137 延伸同一 seam：`create_locked()` 和 `destroy_locked()` 的三处 direct
  `cmq.execute()` 也改由 `execute_queue_command()` 统一归一化，原
  `live_binding_fence()`、ambiguity、completion 缺失和 manager progress 顺序保持不变。
  当前 executor 只在 helper 内保留一处 direct legacy call；lifecycle/recovery 两项
  53 机 focused 均 rc=0、PROCESS/LOGICAL PASS、UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0`。
  详见 `task-cmq-batch137-create-destroy-legacy-execution-seam-report.md`。这仍不等于
  control-plane、QP lifecycle 和 queue lifecycle consumer 已迁移到 `execute_observed()`；
  在该批边界 control-plane/QP 两类剩余 consumer direct call 为 11 个，需按 timeout、
  rollback 和 recovery 语义继续分批收口。
- Batch138 在 `rdma_control_plane.sv` 中新增 `execute_control_command()`，把 MR rollback、
  `deregister_mr()` 的 OCC_FLUSH/MR_DEREGISTER/TQ_FLUSH 以及 recovery hardware step
  的五处同构 legacy `cmq.execute()` 结果归一化收束到一个入口，并加入 CMQ/command
  fail-closed guard；调用方原有 timeout、ticket、generation fence、恢复记录和资源释放
  顺序保持不变。KEY_ALLOC 因成功 status 与 timeout→recovery/rollback 分支特殊暂留
  direct 路径；control-plane/QP 剩余 consumer direct call 从 11 降为 6（KEY_ALLOC 1、
  QP lifecycle 5），helper 内兼容调用不计入 consumer 数。`rdma_control_plane_cmq_engine_test`
  与 `rdma_control_plane_test` 在 53 机均 PROCESS/LOGICAL PASS、UVM `INFO=3/WARNING=0/
  ERROR=0/FATAL=0`；详见 `task-cmq-batch138-control-plane-legacy-execution-seam-report.md`。
  该批仍是 legacy normalization 去重，不是 `execute_observed()` 或 detached
  ticket/completion ownership 的迁移。
- Batch139 在 `rdma_qp_lifecycle_executor.sv` 中新增 `execute_qp_legacy_command()`，仅
  统一 QP presence/query、QPC_CREATE、QPC_MODIFY、recovery query 与 terminal rollback
  的 ticket/completion/status 初始化和一次 raw `cmq.execute()`；每个调用方原有
  pre/post generation fence、ambiguity、completion、timeout 和 recovery 分支保持原位。
  QP 文件 direct legacy dispatch 现仅剩 helper 内一处；与 queue/control-plane helper
  一样，这仍是 compatibility normalization，不是 `execute_observed()` 或 detached
  ticket/completion ownership 迁移。`rdma_qp_lifecycle_test` 与 `rdma_qp_recovery_test`
  在 53 机均 PROCESS/LOGICAL PASS、UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0`；详见
  `task-cmq-batch139-qp-legacy-execution-seam-report.md`。当前跨三个 consumer 的
  未收束 consumer direct call 仅剩 control-plane KEY_ALLOC 一处。
- Batch140 将 control-plane 的 KEY_ALLOC 也通过 `execute_control_command()` 执行，保留
  该特殊路径的原始 status identity；timeout ticket、recovery/rollback 和后续 generation
  语义不变。至此 queue lifecycle、control-plane、QP lifecycle 三个 consumer 文件均只
  在各自兼容 helper 内保留一处 legacy `cmq.execute()`，不再存在 direct consumer dispatch
  call site。`rdma_control_plane_cmq_engine_test` 与 `rdma_control_plane_test` 在 53 机均
  PROCESS/LOGICAL PASS、UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0`；详见
  `task-cmq-batch140-key-alloc-legacy-execution-seam-report.md`。这仍不是
  `execute_observed()`、detached ticket/completion ownership 或 legacy accessor 删除，
  计划继续保持 `active`。
- Batch141 在 `rdma_control_plane.sv` 中把 raw 与 detached status ownership 拆成两个
  显式 seam：`execute_control_command_raw_status()` 负责 CMQ/command fail-closed guard、
  ticket/completion 初始化、一次 legacy dispatch 和 backend raw status identity；
  `execute_control_command()` 复用 raw seam，再通过 `checked_status()` 生成 detached
  status，供 MR rollback、deregister 与 recovery hardware-step 使用。KEY_ALLOC 显式调用
  raw seam，并在原调用点保留 null-status 归一化、timeout ticket、recovery/rollback 和
  generation 检查，未改变 dispatch 次数、失败优先级或资源提交顺序。两项 control-plane
  focused 在 53 机 compile/elab/link、PROCESS/LOGICAL PASS，UVM `INFO=3/WARNING=0/
  ERROR=0/FATAL=0`；`git diff --check`、changed-SV style、profile naming、queue lifecycle
  与 Python 292 门禁通过。该批只澄清 ownership，不是 `execute_observed()` 或 detached
  ticket/completion 迁移；详见 `task-cmq-batch141-control-status-ownership-seam-report.md`。
- Batch142 在 `rdma_queue_data_engine.sv` 中提取
  `prepare_aeqe_publish_image()`，把 AEQE reservation 前的 model clone、live primary
  route authority、profile owner、registry/type check、codec encode 和完整 16-byte image
  校验集中到无 runtime 副作用的 staging seam；失败时清空 `encode_model`/`image`，不
  触碰 attachment、runtime、cursor、backing、pending、Host-memory 或 MMIO。
  `publish_aeqe_common()` 继续负责 reservation 后 epoch/polarity、cancel/recovery 和
  commit，CQE/CEQE reserve-before-encode 语义不变。四项 53 机 focused
  (`rdma_queue_data_engine_device_publish_test`、`rdma_aeqe_route_test`、
  `rdma_aeqe_f5_e2e_test`、`rdma_queue_event_route_consume_test`) 均 compile/elab/link、
  PROCESS/LOGICAL PASS，UVM INFO 分别为 220/3/115/3，WARNING/ERROR/FATAL 全为 0；
  changed-SV style、diff、profile、queue lifecycle 与 Python 292 门禁通过。该批只收束
  AEQE image staging 局部职责，malformed retry、poll/recovery 组合、SRQ lifecycle、
  legacy descriptor、跨队列并发和 registry null/type-fault 原子性仍开放；详见
  `task-cmq-batch142-aeqe-image-staging-report.md`。
- Batch143 在 `rdma_queue_data_engine.sv` 中提取
  `prepare_event_poll_continuation()`，把 CEQ/AEQ decode/route/result 之后、首次
  `enter_recovery_prepared()` 之前同构的 consumer pending、doorbell descriptor 和
  noalloc status staging 收束到一个无副作用 seam。CEQ 的 `route_found` 与 AEQ 的
  `deliver_found` 仍由各自 caller 保持，route miss 仍确认事件但丢弃 payload；helper
  不做 lookup/read/decode/route/result clone、不写 Host-memory/MMIO、不推进 CI/used，
  `commit_event_poll_candidate()` 仍是唯一 mutation/commit 边界。最终 53 机
  `rdma_queue_event_route_consume_test` 与 `rdma_aeqe_route_test` 均 PROCESS/LOGICAL
  PASS、UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0`；全目录 scanner 为 185 `.sv`、2
  `.svh`、5,437 methods、0 diagnostics，计划继续保持 `active`。详见
  `task-cmq-batch143-event-preparation-seam-report.md`。
- Batch144 在 `rdma_queue_data_engine.sv` 中提取
  `complete_host_producer_tail()`，把 `post_send()`/`post_recv()` 在 producer
  reservation、model encode 以及 SQ 专属 `write_sgb_and_verify()`（仅发送路径）之后
  重复的 WQE write/readback、next cursor、producer doorbell、`commit_producer()`、
  detached result 和 recovery pending 尾段收束到统一 task。写回/读回失败保持
  `NO_SUBMIT` pending，doorbell/commit 失败保持 `AMBIGUOUS` evidence，pending clone
  失败返回 `RESOURCE_EXHAUSTED`，recovery 返回值不覆盖首个阶段 status；helper 不取得
  queue、backing、request 或 handle 的外部生命周期所有权。该 task 接收 caller 冻结的
  attachment/queue/kind/cursor/image/request 输入，不新增 reservation、authority 或
  route/epoch admission；`post_recv()` 的显式 route/epoch 检查仍在 helper 前，
  `post_send()` 的独立 route/epoch 复核不在本批新增。最终源码 SHA 为
  `1dfe2bf1038d2fe847e801e4f5eaad837b649c00f0efd9733427b5c448af7388`；
  `rdma_queue_data_engine_post_test`、`rdma_queue_data_engine_recovery_test` 与
  `rdma_queue_data_engine_poll_test` 均 PROCESS/LOGICAL PASS、UVM `INFO=3/WARNING=0/
  ERROR=0/FATAL=0`，`rdma_queue_data_engine_device_publish_test` 同样 PASS、UVM
  `INFO=220/WARNING=0/ERROR=0/FATAL=0`；全目录 scanner 为 185 `.sv`、2 `.svh`、5,438 methods
  （`.sv` 5,436、`.svh` 2）、0 diagnostics，计划继续保持 `active`。详见
  `task-cmq-batch144-host-producer-tail-report.md`。
- Batch145 在 `rdma_queue_data_engine.sv` 中新增受保护的
  `reserve_host_producer_cursor()`，把 SQ/私有 RQ/shared SRQ 在首次 producer 副作用前
  的 `validate_attachment_route_epoch()`→`reserve_producer()` 顺序收束为一个 admission
  seam。`post_send()` 在 SQE authority 后调用，`post_recv()` 在 target/owner 检查后调用；
  stale route/epoch 或 null-status fault 时 cursor 保持 null，不创建 pending、不写 Host-memory、不发 MMIO、
  不改 ledger。post-test 新增 direct send stale-epoch fixture，确认返回
  `RDMA_SC_STALE_GENERATION` 且 SQ cursor/used/pending、Host-memory/PCIe 计数不变。
  post/recovery/poll/device-publish 四项 53 机 focused 均 PROCESS/LOGICAL PASS，UVM
  分别为 `INFO=3/3/3/220`，WARNING/ERROR/FATAL 全为 0；最终源码 SHA 为
  `dde548fb979c0dd1e694651031edc2acb469766e57d2d9f221673001016bb431`，全目录 scanner
  为 185 `.sv`、2 `.svh`、5,440 methods（`.sv` 5,438、`.svh` 2）、0 diagnostics。
  计划继续保持 `active`；reservation 后 route 变化窗口、host-producer hostile fault
  matrix、SRQ 全生命周期、legacy descriptor、跨队列并发、engine-level 全局锁和最终
  ownership 审计仍开放。详见 `task-cmq-batch145-host-producer-admission-report.md`。
- Batch148 在 `rdma_queue_data_engine.sv` 中继续收束 host-producer 的 route/epoch
  evidence 与副作用尾段：`snapshot_attachment_route_epoch()`、reservation 后窗口复核、
  `commit_host_producer_ledger()`、recovery admission/install 和
  `complete_host_producer_tail()` 现在分别承担快照、admission、ledger 调用、pending
  安装和 write/readback→next cursor→doorbell→commit→result 顺序。pending 始终覆盖为
  reservation 冻结的 route/epoch；nonfatal raw factory 与 fail-closed handle clone 不会
  让已提交事务因结果构造失败而重复 mutation。commit-failure test 与 stale-replay
  fixture 分别证明 `AMBIGUOUS` evidence/PI/CI/used 不前进，以及 reset epoch 变化后
  retry 不增加 I/O。post/recovery/poll/device-publish/hostile-failure/commit-failure
  六项 53 机 focused 均 PROCESS/LOGICAL PASS，UVM INFO `3/3/3/220/27/8`，WARNING/
  ERROR/FATAL 全 0；最终源码 SHA 为
  `ca11b30a716b7672b8a648457475dc45cd122f33107b879e0c40738bddb1b509`，全目录 scanner
  为 185 `.sv`、2 `.svh`、5,460 methods（`.sv` 5,458、`.svh` 2）、0 diagnostics。
  计划继续保持 `active`；reservation 后并发、admission/enter-recovery failure matrix、
  SRQ 全生命周期、跨队列并发、legacy descriptor、外部 PCIe error/ordering、全局锁和
  最终 ownership 审计仍开放。详见
  `task-cmq-batch148-host-producer-commit-route-report.md`。
- Batch149 在 `recover_queue()` 的 reservation-only 分支新增受保护的
  `resolve_reservation_only_recovery()`：该 helper 统一收集完整 queue incarnation 的
  candidate、逐个查询 reservation、完成多匹配 cardinality 判定，并只允许唯一
  reservation 走公开 abort/detach；没有 image 的 retry 仍返回 `RECOVERY_REQUIRED`，
  query/detach/null-status 失败不删除任何 evidence。unclaimed admission 失败分支
  保留独立的 ACTIVE state 与 pending cursor 对齐门禁，避免把两种 recovery evidence
  混成一个过宽的 cancel seam。`rdma_queue_data_engine_device_publish_test`（含
  multiple-reservation、锁忙和最终 reconfigure）与 `rdma_queue_data_engine_recovery_test`
  均在 53 机最终源码边界 PROCESS/LOGICAL PASS，UVM `INFO=220/3`、WARNING/ERROR/FATAL
  全为 0；源码 SHA 为
  `adf49cd8f64b94fc7f0426637df9869688e76333401f08727ce353f9b679c322`，全目录 scanner
  为 185 `.sv`、2 `.svh`、5,461 methods（`.sv` 5,459、`.svh` 2）、0 diagnostics。
  计划继续保持 `active`；跨队列并发、SRQ 全生命周期、legacy descriptor、外部
  PCIe error/ordering、engine-level 全局锁、全目录 ownership 与 integration aggregate
  仍开放。详见 `task-cmq-batch149-reservation-only-recovery-seam-report.md`。
- Batch150 在 `src/codec/rdma/rdma_cmq_codecs.sv` 收束两个 CMQ consumer 之间重复的
  `context_key()`/`is_context_opcode()`：新增 package-scope
  `rdma_cmq_context_codec_key()` 与 `rdma_cmq_is_context_opcode()`，原 protected
  方法保留为兼容转发；六个 context opcode 映射与 unknown fail-closed 行为逐值不变。
  同批删除 `rdma_cmq_codec_test.sv` 中无调用的旧 context-key fixture，并同步 frozen ABI
  manifest 摘要。codec、context-body、context-CMQ focused 和 CMQ gate 均在 53 机登录
  bash 通过；CMQ gate 为 PROCESS 28/28、LOGICAL 11/11、UVM pristine 28/28，严格
  warning/error/fatal 均为 0。最终 codec/test/manifest SHA 分别为
  `07fd199219f2ec8ce57e90a8e863cb259d3e02da8543970c7e3bc41c17ac3ac7`、
  `5f6c14ce8fa0b34c8d89a38ed5f9d88bd1c782120021f4e8e5b74dd958b9103d`、
  `cac560ed8225ae163fa1641fa2a9b470fc0828d6184411eef21abeeddf634caa`；全目录 scanner
  为 185 `.sv`、2 `.svh`、5,462 methods（`.sv` 5,460、`.svh` 2）、0 diagnostics。
  本批只消除两个 consumer helper 的重复，不把 registration 表宣称为同一全局数据源；
  计划继续保持 `active`。详见 `task-cmq-batch150-context-helper-shrink-report.md`。
- Batch151 在 `src/model/rdma_authority_validation.sv` 收束 CQ/EQ/RQ/SQ facade
  重复的 live-authority admission：统一 configured/delegate/binding 缺失、Function
  UID/generation/reset epoch 漂移、ACTIVE 状态和 `validate()` null/failure 的拒绝顺序；
  四个 facade 的 protected `validate_live_authority()` 保留为薄转发，未改变
  authority 快照或 runtime/ledger 所有权。SQ/RQ/CQ/EQ focused 均在 53 机登录 bash
  通过，UVM warning/error/fatal 为 0/0/0；helper 加入后全目录 scanner 为 188 文件
  （186 `.sv`、2 `.svh`）、5,463 methods、0 diagnostics。详见
  `task-cmq-batch151-authority-validation-helper-report.md`。
- Batch152 在 `src/core/rdma_queue_facade_configuration.sv` 收束 SQ/RQ/EQ 三个
  `configure()` 的重复依赖一致性、binding 校验和 ACTIVE admission；one-shot
  `configured` 门禁、delegate/authority/timeout 快照写入仍留在各 facade，CQ 的 URC
  专属配置路径不被泛化。`rdma_sq_engine_test`、`rdma_rq_engine_test` 和
  `rdma_eq_engine_test` 在 53 机最终源码边界均 PROCESS/LOGICAL PASS，UVM
  `INFO=3/WARNING=0/ERROR=0/FATAL=0`；全目录 scanner 刷新为 189 文件（187 `.sv`、
  2 `.svh`）、5,464 methods（`.sv` 5,462、`.svh` 2）、0 diagnostics。计划继续保持
  `active`。详见 `task-cmq-batch152-facade-configuration-shrink-report.md`。
- Batch153 将 CQ 普通 `configure()` 接入同一
  `rdma_validate_queue_facade_configuration()`，收束第四个 facade 的依赖非空、
  shared-engine 五引用一致性、binding validation 和 ACTIVE admission；CQ 的
  `configure_shared()`、URC completion-QP/shadow 约束、`configured` 与
  `shared_configured` 门禁以及 authority/delegate/timeout 快照仍由 CQ 自己负责。
  `rdma_cq_engine_test`、`rdma_cq_engine_resize_test` 和
  `rdma_cq_shadow_flush_test` 在 53 机登录 bash 均 PROCESS/LOGICAL PASS，UVM
  `INFO=3/WARNING=0/ERROR=0/FATAL=0`；全目录 scanner 仍为 189 文件（187 `.sv`、
  2 `.svh`）、5,464 methods（`.sv` 5,462、`.svh` 2）、0 diagnostics。计划继续保持
  `active`。详见 `task-cmq-batch153-cq-configuration-admission-report.md`。
- Batch154 在 `src/core/rdma_queue_data_engine.sv` 新增受保护的
  `poll_event_with_timeout()`，收束 CEQ/AEQ public poll wrapper 重复的 deadline、
  `QUEUE_EMPTY` 重试、null-status 归一化和 timeout 返回；`poll_ceqe_once()`/
  `poll_aeqe_once()` 的 decode、route、pending、doorbell、commit、recovery 和
  detached-result 逻辑仍各自保留，virtual `poll_ceqe()`/`poll_aeqe()` 入口不变。
  `rdma_queue_data_engine_poll_test`、`rdma_queue_event_route_consume_test` 和
  `rdma_aeqe_route_test` 以及覆盖非零 timeout 的 `rdma_eq_engine_test` 在 53 机登录 bash 均 PROCESS/LOGICAL PASS，UVM
  `INFO=3/WARNING=0/ERROR=0/FATAL=0`；全目录 scanner 更新为 189 文件（187 `.sv`、
  2 `.svh`）、5,465 methods（`.sv` 5,463、`.svh` 2）、0 diagnostics。计划继续保持
  `active`。详见 `task-cmq-batch154-event-poll-timeout-shrink-report.md`。
- Batch155 在 `src/core/rdma_eq_engine.sv` 新增受保护、非 virtual 的
  `validate_operation_authority()` 与 `normalize_delegate_status()`，只收束五个 EQ
  facade public task 重复的配置/Function authority admission 和 delegate null-status
  envelope；CEQ/AEQ consumer、legacy producer 与 secondary-authority producer 仍显式
  调用各自 typed delegate，route、timeout、runtime/backing/cursor、MMIO、recovery 和
  CQ-flush secondary authority 均未合并。生产源码由 327 行降至 272 行；EQ facade、
  queue-data poll、event-route consume 与 AEQE route 四项 53 机 focused 均 PROCESS/
  LOGICAL PASS，UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0`。全目录 scanner 更新为 189
  文件（187 `.sv`、2 `.svh`）、5,467 methods（`.sv` 5,465、`.svh` 2）、0
  diagnostics；计划继续保持 `active`。详见
  `task-cmq-batch155-eq-facade-operation-envelope-report.md`。
- Batch156 在 `src/core/rdma_cq_engine.sv` 新增受保护、非 virtual 的
  `validate_operation_authority()` 与 `normalize_delegate_status()`，收束
  `poll_cqe()`、`publish_cqe()`、`resize()` 的配置/Function authority 与 delegate
  null-status 外壳；三条 typed virtual seam 仍显式独立，shared-only/inout/replay 契约
  不同的 `flush_shadow()` 未并入。生产源码 500→498 行，非注释非空行 373→344；三项
  CQ VCS53 均 wrapper rc=0、PROCESS/LOGICAL PASS、UVM
  `INFO=3/WARNING=0/ERROR=0/FATAL=0` 且 pristine。全目录 scanner 为 189 文件（187
  `.sv`、2 `.svh`）、5,469 methods（`.sv` 5,467、`.svh` 2）、0 diagnostics；计划继续
  保持 `active`。详见 `task-cmq-batch156-cq-facade-operation-envelope-report.md`。
- Batch157 在 `src/core/rdma_cq_engine.sv` 删除可变 `shadow_flush_result`，以 raw UVM
  factory helper 和手工 value clone 收束 shared handle、首次 shadow snapshot 与 replay
  的非致命失败路径；普通 `configure()+configure_shared()` 拒绝跨 Function
  UID/generation，并在补齐 shared shadow 前复用 live binding admission。queue-data
  engine 的 URC evidence candidate 同样改用 raw factory/cast，避免错误动态类型触发
  typed-factory fatal。首次 flush 在 URC evidence 前分别 staging caller/cache detached
  snapshot；replay 从 cache 重建独立 snapshot/status，不重复 evidence 或计数，并在
  factory 失败时保持 caller/cache/count/evidence 原子不变。`rdma_cq_shadow_flush_test`
  新增 null/错误类型 override、配置/首刷（含 evidence candidate）/replay 重试及
  projected 21-bit local CQ ID fixture；`rdma_cq_engine_test` 覆盖跨 UID/generation
  拒绝与 ordinary live reset gate。CQ engine、resize、shadow-flush 三项 VCS53 均 wrapper rc=0、PROCESS/
  LOGICAL PASS、UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` 且 pristine；全目录 scanner
  实测为 189 文件（187 `.sv`、2 `.svh`）、5,483 methods（`.sv` 5,481、`.svh` 2）、
  0 diagnostics。`configure_shared()`-only 没有 live reset binding 的限制仍 OPEN，计划
  继续保持 `active`。详见 `task-cmq-batch157-cq-shadow-replay-atomicity-report.md`。
- Batch158 在 `src/core/rdma_queue_data_engine.sv` 新增受保护的
  `reserve_device_publish_checked()` 与 `check_device_publish_polarity()`，收束
  `publish_cqe()`、`publish_ceqe()` 和 `publish_aeqe_common()` 的重复 device-producer
  reservation、null-status 和 expected-polarity admission。CQE/CEQE 保持
  authority→reservation→polarity→codec；AEQE 保持 image staging→reservation→
  route/epoch recheck→polarity→commit，`write_commit_device_entry()` 的 recovery、
  backing/MMIO/ledger 所有权不变。四项 device-publish/AEQE focused 在 53 机均
  PROCESS/LOGICAL PASS，UVM INFO `220/3/3/115`，WARNING/ERROR/FATAL 全为 0；静态
  gates 与 Python 292/292 通过，全目录 scanner 为 5,485 methods（`.sv` 5,483、
  `.svh` 2）、0 diagnostics。计划继续保持 `active`；跨队列并发、SRQ lifecycle、
  legacy descriptor、外部 ordering/error、engine-level 全局锁、完整 parent/core gate
  与最终 ownership 审计仍开放。详见
  `task-cmq-batch158-device-publish-admission-report.md`。
- Batch159 在 `src/core/rdma_cmq_engine.sv` 新增共享的
  `decode_transport_envelope()`，把 observed/recovery transport 返回值统一降级为
  detached operation status、observation code/message 与 raw submission effect；合法
  status/effect 保留，malformed status/effect 分别 fail-closed，recovery effect 文案
  覆盖与 observed combined 文案保持。observer arm、effect fold、分类、journal/CAS
  mutation 仍由 caller 执行。`rdma_cmq_engine_test` 在 53 机 18/18 PROCESS、1/1
  LOGICAL PASS，18 个 UVM report 的 WARNING/ERROR/FATAL 均为 0；Python 292/292 与
  全目录 5,488 methods/0 diagnostics scanner 通过。计划继续保持 `active`；malformed
  recovery 组合矩阵、并发/global lock、SRQ lifecycle、legacy descriptor、外部
  ordering/error、完整 CMQ/core gate、typed URC factory、ownership 与 Phase-1C F2
  仍开放。详见 `task-cmq-batch159-transport-envelope-decode-report.md`。
- Batch104 之前的静态复审已通过：Python 292、CMQ manifest 22、SV keyword guard 3、
  `git diff --check`、changed-SV style，以及覆盖 5,286 个 function/task 的历史全目录中文契约/文件头
  scanner 均 GREEN；Batch110 按当时工作树边界重新扫描 185 个 `.sv`、2 个 `.svh`，共 5,382
  个 function/task、0 diagnostics，且 Python/manifest/keyword/queue/profile/Phase-1A
  辅助门禁均通过；Batch111 在 capability 改动后重扫为 5,387 个 function/task、0 diagnostics，
  摘要见 `evidence/batch111.*`，历史完整摘要仍位于 `evidence/final-static.meta`。
  Batch142 自身边界为 5,436 methods，Batch143 helper 后为 5,437 methods；Batch144
  当前边界为 5,438 methods（`.sv` 5,436、`.svh` 2）；Batch145 新增 admission helper
  与 stale-epoch fixture 后为 5,440 methods；Batch148 当前最终源码边界重扫为 185 个
  `.sv`、2 个 `.svh`，5,460 methods（`.sv` 5,458、`.svh` 2）；Batch149 新增
  reservation-only recovery helper 后重扫为 5,461 methods（`.sv` 5,459、`.svh` 2）；Batch150
  context helper 收缩与 dead fixture 删除后重扫为 5,462 methods（`.sv` 5,460、`.svh` 2）、
  Batch151 authority helper 与 Batch152 facade configuration helper 后重扫为 5,464 methods
  （`.sv` 5,462、`.svh` 2）；Batch154 event poll timeout helper 后为 5,465 methods，
  Batch155 EQ facade operation envelope helper 后为 5,467 methods，Batch156 CQ facade
  operation envelope helper 后为 5,469 methods（`.sv` 5,467、`.svh` 2）；Batch157
  CQ shadow replay/factory atomicity helper 与测试后为 5,483 methods（`.sv`
  5,481、`.svh` 2）；Batch158 device-publish admission helper 后为 5,485 methods
  （`.sv` 5,483、`.svh` 2）；Batch159 transport envelope decoder 与 recovery probe 后
  当前边界为 5,488 methods（`.sv` 5,486、`.svh` 2）、0 diagnostics；扫描继续复用
  `sanitize_source`、`method_ranges`、`check_method_comments` 和 `check_file_header`，覆盖
  `src/`、`tests/`、`sim/`，不把历史计数冒充当前证据。Batch160 transaction-model/kernel
  文件与 polled journal commit seam 后当前边界为 191 个文件（189 `.sv`、2 `.svh`）、
  5,496 methods、0 diagnostics；完整 CMQ gate 已追加复跑并通过。

计划状态：`active`。Batch109/110 已关闭当前严格一对一 ownership/close/candidate seam
和同步 publication callback 重入 seam；Batch111 关闭 legacy Host epoch capability bypass；
Batch112 关闭同步 tokenless dataplane reset-admission seam；Batch113 关闭 SQ SGB
writer 的局部 image/payload authority seam；Batch114 关闭 UD transport-aware effective
mode 对齐 seam；Batch115–133 继续关闭 queue-data 的局部 target/replay/recovery 扫描
结构 seam，但 Batch119 关闭 recovery action/cardinality/query 顺序的局部契约、Batch120
关闭 device-producer replay 的局部职责 seam、Batch121 关闭 consumer replay 的局部职责
seam、Batch122 关闭 local-resource match/projection 的局部职责 seam、Batch123 关闭
consumer recovery authority preflight 的局部职责 seam、Batch124 关闭 consumer
recovery CQ→WQ release 的局部职责 seam、Batch125 关闭 CQ poll candidate staging 的
局部职责 seam、Batch126 关闭 CQ poll SQ/RQ/SRQ completion target 解析的局部职责 seam、
Batch127 关闭 live CQ poll mutation/commit 的局部职责 seam、Batch128 关闭 CEQ/AEQ
consumer commit 的局部职责 seam、Batch129 关闭 CQ poll WQ target selector/validator
的局部职责 seam、Batch130 关闭私有 RQ receive CQE 正向 poll 的测试覆盖 seam、Batch131
关闭 staged WQ canonicalization 的 admission seam并补充 UD SEND 正向 poll 证据、Batch132
关闭 shared-SRQ receive CQE 正向 poll 的测试覆盖 seam、Batch133 关闭 CQE
variant/SRFQ topology consistency 的 publish/poll admission seam、Batch134 的供应商
TL-only error/ordering smoke、Batch135 的 UD receive/replay 窄闭环、Batch136 的
rollback legacy execution 去重 seam、Batch137 的 create/destroy legacy execution
归一化、Batch138 的 control-plane legacy execution seam、Batch139 的 QP legacy
  execution seam、Batch140 的 KEY_ALLOC 收口、Batch141 的 raw/detached status ownership
  拆分、Batch142 的 AEQE reservation 前 image staging、Batch143 的 CEQ/AEQ prepared
  consumer staging、Batch144 的 SQ/RQ/SRQ host-producer completion tail、Batch145 的
  host-producer route/epoch admission、Batch148 的 host-producer commit/recovery route
  和 Batch149 的 reservation-only recovery seam、Batch150 的 CMQ context helper 重复收缩、
  Batch151/152/153 的 facade authority/configuration admission 收缩、Batch154 的 CEQ/AEQ
  timeout wrapper 收缩、Batch155 的 EQ facade operation envelope 收缩、Batch156 的 CQ
  facade operation envelope 收缩、Batch157 的 CQ shadow canonical replay/factory
  atomicity 收口、Batch158 的 device-publish reservation/polarity admission 收缩和
  Batch159 的 shared transport envelope decode 收缩；完整公开
  post/replay 矩阵、广义 F2、coordinator 的全局并发/更深
生命周期语义、manager 外部调用窗口补偿、全目录后续生命周期审计和外部锁仍未关闭，
  不得标记为 `complete`。

- Batch160（Phase 2）开始真正的 CMQ 物理职责拆分：新增
  `src/core/rdma_cmq_engine_transaction_models.sv`，迁出 slot record、预分配发布值、reset
  candidate、MMIO arm observer 以及 submit/recovery/expiry/cancel staging 类型；engine 继续
  独占 runtime/journal/fence/lock 和所有可变状态。`rdma_core_pkg.sv` 按依赖顺序 include 新文件，
  UVM factory 注册、observer callback 和字段布局均未改变。engine 从 14,270 行降至当前 13,785
  行；新增 transaction-model 502 行、transaction-kernel 237 行。ring geometry 纯校验移入
  kernel，expiry/generation-cancel 的同形 staging 合并为一个 terminal-transition stage，
  不复制账本、不引入第二 owner；随后把正常 CQE 与 late completion 重复的 retained
  journal transition staging/commit 收束为 `commit_polled_journal_transition_locked()`，
  completion/diagnostic、FIFO、token 和 slot 终态仍由 caller 分支负责；随后将
  completion/timeout/late/reset 共用的 journal predecessor 表提取为
  `rdma_cmq_transition_predecessor_valid()` 纯值函数，保留 engine 的 journal/slot/reset
  authority；observed/wait/reconcile 的四处终态 phase 枚举统一为
  `rdma_cmq_completion_phase_has_terminal_evidence()`，caller 继续负责 completion handle
  与 authority 校验。CMQ engine models focused test 在 VCS53 编译并通过，静态 comment/style、
  CMQ manifest（23/23）和 keyword gates 均通过。完整 CMQ gate 在 VCS53 登录 bash 环境
  追加完成 11/11 logical、18/18 engine process，严格 UVM warning/error/fatal 为 0/0/0，
  字段变异证据 PASS；全目录复审覆盖 191 个文件、5,496 个 function/task，hard diagnostics=0。
  纯值层与 journal ownership 的后续拆分仍开放。

- Batch161 将 QP 状态迁移矩阵抽为无状态 `rdma_qp_transition_decide()`，保留 executor 的
  QPC/CMQ/outstanding/resource owner；Batch162 又在 resource manager 内以
  `snapshot_activity_blockers()` 统一读取 live dependents 与 `outstanding_ids`，让
  quiesce、QP/facade finalize 和 reservation release 共用只读 blocker seam，而不复制
  mutable ledger。QP transition、resource manager、queue lifecycle、QP recovery 和
  control-plane focused VCS53 均 PROCESS/LOGICAL PASS，UVM warning/error/fatal 为 0/0/0；
  当前全目录复审为 192 个
  文件（190 `.sv`、2 `.svh`）、5,499 methods、0 diagnostics。QP 的 SQD/SQE drain/flush、
  跨资源 destroy dependency、跨队列并发、reset 统一验收、manager 外部调用窗口补偿和
  最终 ownership 审计仍保持 OPEN，计划继续为 `active`。

- Batch163 新增 `rdma_resource_identity_candidate` detached transaction value，把
  `reserve_identity()` 的 owner/handle/local-id/serial/free-list/binding-registration 回滚
  证据集中起来；PD/MR/CQ/QP/SRQ/CMQ/CEQ/AEQ 的 `create_*` 入口复用
  `reserve→construct→register→publish` 与 `rollback_identity_candidate()`。allocator 数组、
  registry、publication 和 Function 专用 incarnation 路径仍由 `rdma_resource_manager` 唯一
  拥有，`create_function()` 未被泛化。resource-manager、queue lifecycle、QP lifecycle、QP
  recovery 和 control-plane 五项 VCS53 focused 均 PROCESS/LOGICAL PASS，UVM 0/0/0；Python
  293/293、changed-SV style、diff、queue/profile/Phase-1A 通过。当前源码为 193 文件（191
  `.sv`、2 `.svh`）、5,504 个 function/task（`.sv` 5,502、`.svh` 2）、新增 5 个中文契约方法；allocator 并发、跨 incarnation destroy、
  queue runtime snapshot、reset 统一验收和最终 ownership 审计继续 OPEN，计划保持 `active`。
  详见 `task-rdma-batch163-resource-allocator-transaction-report.md`。

- Batch164 新增 `src/core/rdma_queue_runtime_transaction_models.sv`，将 runtime 专用枚举、
  cursor snapshot、pending recovery evidence 和 host slot ledger 从
  `rdma_queue_runtime.sv` 移到 detached value-model 层；runtime 仍唯一拥有 attachment、
  lock、PI/CI、occupancy、reservation、ledger、pending publication 与 route/epoch mutation。
  既有 do_copy 兼容语义和 non-fatal clone 边界保持不变，未改变 pending recovery、shadow/
  MMIO evidence、slot completion、cursor wrap 或 reset-epoch 验证。runtime、queue-data
  post/poll/recovery 四项 VCS53 focused 均 PROCESS/LOGICAL PASS，UVM 0/0/0；Python
  293/293、changed-SV style、diff、queue/profile/Phase-1A 通过。当前源码为 194 文件（192
  `.sv`、2 `.svh`）、5,502 methods、0 diagnostics。跨队列/跨线程并发、SRQ lifecycle、
  reset 统一验收、外部 ordering/error、manager 外部调用窗口补偿和最终 ownership 审计继续
OPEN，计划保持 `active`。详见 `task-rdma-batch164-runtime-value-models-report.md`。

- Batch165 处理 Batch163 保留的 Function 专用 allocator 路径：新增
  `rdma_function_identity_candidate`，保存 detached owner、handle、trusted binding、owner key、
  local ID、free-list 来源和首次 registration 标记；`create_function()` 复用专用
  `reserve_function_identity_candidate()`/`rollback_function_identity_candidate()` 骨架，
  但保留 duplicate incarnation、older generation、released tombstone 和 binding projection
  顺序。resource-manager focused VCS53 PROCESS/LOGICAL PASS，UVM 0/0/0；changed-SV style、
  diff 和全目录 scanner 为 194 个源码文件、5,507 methods、0 diagnostics。allocator/registry
  并发、跨 incarnation destroy dependency、queue runtime snapshot、reset 统一验收、manager
  外部调用窗口补偿和最终 ownership 审计继续 OPEN，计划保持 `active`。详见
  `task-rdma-batch165-function-identity-candidate-report.md`。

## CMQ Phase 2 驱动业务对齐决策（2026-09-23）

对照冻结的 `rdma-driver-0.1.34` CMQ 业务锚点（`xtrdma_sc_cmq_post_sq`、
`xtrdma_sc_cmq_next_cqe_valid`、`xtrdma_get_cqe_common_info`）和本项目 C oracle，
后续拆分以业务流程而不是驱动源码结构为准：

- 公共能力统一承载 SQ/CQ ring cursor、index/wrap/polarity、slot/token 生命周期、
  journal locator、completion/timeout/late 状态和 reset epoch 隔离。
- profile 只负责 SQE/CQE/doorbell 字段编码解码；不得把 opcode、端序、owner/wrap 位域
  再复制到 transaction core。
- observed submit、recovery retry、generation cancel 和 reset 作为 policy/admission，
  共享 `admit → stage → external I/O → commit` 骨架；它们不能各自拥有 ring/journal。
- 保留项目相对驱动的必要增强：batch 单 doorbell、32 项全部 outstanding、software
  command ID、retained journal、observed/recovery evidence 和 UVM hostile-fault seam。
  这些增强不改变驱动可观察的 SQE/CQE、doorbell、completion 和 reset 业务顺序。
- 不复制驱动的 C 结构、锁粒度或软件数组；CMQ engine 继续是 runtime/journal/fence 的
  唯一 owner，公共能力通过显式 plan/value 输入输出工作。

因此，下一阶段不得新增 `submit_transaction`、`recovery_transaction`、
`reset_transaction` 三套平行实现；应先建立一个精简 transaction kernel，再由三个 policy
适配器提供差异化 admission 和 commit 规则。当前 Batch160 的 686 行 transaction-model/
kernel 物理迁移保留为准备性边界，尚不代表最终公共能力已经完成。

## 0. 主线接管与冻结

1. 主线收到切换指令后暂停原修复任务及其后续调度；让正在写文件的执行者在安全
   边界停止，记录被中断的测试，不能把不完整日志认作通过。
2. 确认没有并发源码写入后，保存完整工作树快照、HEAD、tracked/untracked 清单、
   文件哈希和已有测试证据。基线必须包含现有未提交修复，不能仅从 HEAD 重建。
3. 将原任务标为“用户要求暂停”，保留未完成项和恢复入口；不得标为已经完成。
4. 后续仅修改本项目。不得修改外部依赖，不执行 reset、clean、merge 或 push；
   提交按既有授权处理。本文件本身不扩大提交权限。

## 1. 重构目标与范围

目标是降低阅读和修改业务的复杂度，保持合法请求、非法输入及故障路径的契约。
行数只是观察指标；职责是否清晰、状态是否集中、重复逻辑是否减少才是验收依据。

第一轮只读盘点如下，规模包含注释并可能随主线修改变化：

| 业务 | 观察 | 重构方向 |
| --- | --- | --- |
| CMQ engine | 约 14400 行；批量提交 task 1240 行，恢复 task 1000 行 | 提取快照/校验职责，再拆提交、完成、恢复与复位阶段 |
| Queue-data engine | 约 8900 行；发送、接收、事件、CQ resize 与恢复混合 | attachment/路由、发送接收、完成事件、resize、恢复分别负责 |
| Resource manager | 约 8400 行；大量类型投影、比较与生命周期逻辑交织 | 提取类型化快照和纯校验，再整理身份分配、登记与依赖 |
| Queue codecs | 约 5500 行；模型和五类编解码集中 | 按 SQE/RQE/CQE/CEQE/AEQE 分文件，共用字节与签名基础层 |
| Queue runtime | 约 5000 行；快照处理与状态转换交织 | 先提取复制/比较和纯校验，保留唯一运行状态所有者 |
| Control plane / lifecycle | 存在 600–800 行恢复 task | 提取 MR 生命周期，按准备、执行、提交、补偿组织恢复 |
| CMQ tests | 约 24500 行 | 分离 fixture 与业务场景，保持既有逻辑覆盖和进程隔离 |

按 CMQ、queue-data、resource manager、其余候选业务逐批推进。小型 facade、
allocator、adapter 先评估职责及依赖；没有实际复杂度收益的部分保留原结构。

## 2. CMQ 首批实现边界

先建立当前公开 API、protected/virtual 测试扩展点、状态字段和锁边界清单。
现有 transport/port 继续承担原职责。具体实施顺序：

1. 提取无 engine 状态写入的类型化快照、值比较与结构校验。调用输入、输出、
   错误优先级以及 factory/subtype/deep-copy 契约应保持可追踪。
2. 将批量提交整理为 admission、candidate staging、journal 安装、transport 调用、
   结果分类和提交几个明确阶段。阶段之间用有明确生命周期的局部上下文传递结果。
3. 将恢复、完成/超时和复位分别整理为可读的阶段流程，保留既有提交点及失败证据。
4. 在状态迁移依赖明确后，再决定哪些职责需要独立对象。避免让多个组件直接写同一
   账本，或通过一个通用 owner 句柄任意访问全部 engine 内部状态。
5. 按业务分离测试 fixture 和场景，保留原测试入口及覆盖清单。

每一步形成可单独审查的改动。新增文件使用 `.sv`，按原 package 依赖顺序纳入。
若需要临时保留兼容转发，注明它对应的现有入口及移除条件，避免永久叠加无意义层次。

## 3. 行为不变量

- wire 坐标、端序、mask、signature 和 canonical/raw authority 边界保持一致。
- status、空输出、失败优先级及调用方输入不可变契约保持一致。
- Host-memory、MMIO、发布/回读的先后顺序与失败副作用保持一致。
- lock、reset epoch、generation、预分配提交及单次提交条件保持一致。
- cursor、credit、slot、journal、fence 与 recovery 的所有者和生命周期保持明确；
  不通过复制可变账本实现职责拆分。
- 保留 UVM factory override、null-status、hostile clone、别名隔离等已有故障契约。
- `dpu_common` 继续提供唯一全局身份 authority；外部后端仍由外部环境管理生命周期。

## 4. 验证与 bug 修复

全部 VCS 仿真在 `ubuntu@10.11.10.53` 的登录 bash 环境通过现有入口执行：

```bash
SSHPASS=123 scripts/run_vcs53.sh core <test>
```

冻结基线时核对已有证据是否与源码哈希一致；缺少可信基线的受影响测试需补跑。
若基线已失败，将其记录为已知问题，不能把失败基线描述为重构等价证明。

CMQ 每批至少覆盖 engine logical gate、port、codec/profile 及受影响控制面/生命周期
消费者。既有 CMQ 门禁包含 18 个独立进程和 68 个 fixture；保留其实际清单与隔离契约。
其他业务分别运行对应 codec、queue-data、runtime、resource/lifecycle 测试。

关键场景同时核对重构前后的字节镜像、状态、I/O 序列、游标和恢复结果。发现故障后
先区分重构回归与基线缺陷，增加独立契约断言，再进行最小修复和受影响回归。
实际代码或依赖变化后更新验证，不无依据地重复已通过的同源码测试。

保留 wrapper rc、PROCESS/LOGICAL 结论、严格 UVM warning/error/fatal 计数、
源码哈希、完整日志和校验值。验收 GREEN 要求 rc 0、PROCESS/LOGICAL PASS、UVM 0/0/0。

## 5. 可读性与交付

遵守仓库 AGENTS.md：文件头说明目录职责、依赖和生命周期；每个 function/task
逐一提供准确的中文“功能 / 输入输出及副作用 / 失败边界”说明。注释结合真实业务，
删除失真模板，保留合理空行。完成前按要求复审涉及目录的完整代码，而非只看 diff。

每批报告拆出的职责、状态归属、重复逻辑的实际减少、最长流程变化、验证结果及
遗留问题。跨业务改动拆成可审查的小批次，最终交付覆盖矩阵和尚需恢复的原修复任务。

### Batch190 当前状态（2026-09-24）

Phase-1C F2 新增 SQ `sge_num`/payload-length authority 子批：
`rdma_sge_authority::derive_send()` 已被 RC/UD codec 与 SQ-SGB writer 共同使用，
focused SQ authority/codec 验证通过。该子批不改变 mode、signature、Host-memory I/O
或错误优先级；RQ typed/raw authority、SRQ lifecycle、并发、legacy descriptor、外部
ordering/error/backpressure、manager 调用窗口和最终 ownership 仍 OPEN，计划保持 `active`。

### Batch191 当前状态（2026-09-24）

Queue-data CQ consumer release 子批已完成：live poll 与 recovery retry 共用
`execute_consumer_wqe_release()`，统一 CQ→WQ gate、routed WQ release、finish 和失败
evidence；runtime/ledger/外部 backing owner 未移动。runtime、queue-data poll、queue-data
recovery focused 在 VCS53 通过，Python 293/293、style/diff gate 通过。该子批不关闭
SRQ lifecycle、跨 queue/engine 并发、legacy descriptor、外部 ordering/error/backpressure、
Phase-1C F2 whole-plan 或最终 ownership 审计，计划继续保持 `active`。

### Batch192 当前状态（2026-09-25）

Resource manager 普通资源 publication 子批已完成：新增受保护
`publish_identity_candidate()`，统一 PD/MR/CQ/QP/SRQ/CMQ/CEQ/AEQ 的 identity candidate
校验、`register_resource()`、失败回滚与成功清除；Function 创建继续保留独立的
generation/tombstone candidate 路径。该 helper 不复制 allocator/registry/lock，也不接管
外部 adapter 生命周期。resource-manager、queue-lifecycle、QP-lifecycle 和 control-plane
focused 在 VCS53 均 PROCESS/LOGICAL PASS，UVM warning/error/fatal 为 0/0/0；Python
293/293、changed-SV style 与 `git diff --check` 通过。项目级计划仍保持 `active`，剩余
并发、SRQ 全生命周期、legacy descriptor、外部 ordering/error、Phase-1C F2 whole-plan
和最终 ownership 审计不因本批关闭而提前宣称完成。详见
`task-rdma-batch192-resource-publish-seam-report.md`。

### Batch195 当前状态（2026-09-25）

Queue progress detached candidate 子批已完成：新增 `rdma_queue_progress_candidate`，统一
携带 queue progress 的 key、authoritative resource snapshot、可选 ERROR recovery snapshot
和 `has_recovery`；`queue_progress_snapshots()` 的拒绝分支清除半成品，
`commit_queue_progress()` 在统一校验后一次性发布两份账本。flush、cleanup、context 三个
入口保留原 role cardinality、authority、SRFQ flush 前置、错误优先级和 publication 顺序，
manager 仍是 registry/recovery ledger 的唯一 owner。resource-manager、queue-lifecycle、
QP-lifecycle、control-plane focused VCS53 均 PROCESS/LOGICAL PASS，UVM warning/error/fatal
均为 0/0/0；详见 `task-rdma-batch195-queue-progress-candidate-report.md`。

本批不关闭 registry 并发、manager 外部调用窗口、SRQ 全生命周期、跨 queue/engine 并发、
Phase-1C F2 whole-plan 或最终 ownership 审计，项目计划继续保持 `active`。

### Batch199 当前状态（2026-09-25）

Resource publication projection 子批已完成：`stage_resource_publication()` 在第一次外部
clone/factory projection 前捕获 `publication_epoch`，完成 registry/published/owner/handle
四类 detached projection 后检查 epoch；若 manager 在 projection 窗口发生 mutation，stage
清除 candidate 并返回 `RDMA_SC_INVALID_STATE`。commit 的 stale epoch、canonical key/identity
与 duplicate incarnation gate 保持不变；普通及 Function identity candidate 也锁存 reserve
后 epoch，publication 前发现 stale reservation 时先回滚 allocator/binding，再拒绝发布；
Function 路径通过 `publish_function_identity_candidate()` 统一 freshness、authoritative 完整性、
registry publication 与失败回滚，manager 仍是 publication ledger 的唯一 owner。

`rdma_resource_manager_test` 增加 epoch observation，并保留 concurrent create、hostile
key/owner、duplicate commit 与 clear 后二次提交矩阵；resource-manager、control-plane、
QP-lifecycle、queue-lifecycle focused VCS53 均 PROCESS/LOGICAL PASS，UVM warning/error/fatal
均为 0/0/0，Python 293/293、changed-SV style、diff、queue/profile/Phase-1A 门禁通过。详见
`task-rdma-batch199-publication-epoch-gate-report.md`。

本批不关闭 allocator/registry 跨线程或跨进程互斥、manager 更广泛外部调用窗口补偿、SRQ
全生命周期、跨 queue/engine 并发、SQD/SQE drain/flush、legacy descriptor、外部
ordering/error/backpressure、Phase-1C F2 whole-plan 或最终 ownership 审计；计划继续保持
`active`。

### Batch200 当前状态（2026-09-25）

Allocator 静态决策子批已完成：新增 `rdma_resource_allocator_policy.sv`，把资源 kind
合法集合和 PD/MR/CQ/QP/SRQ/CEQ/AEQ local-ID 宽度映射提取为无状态纯值 policy；manager
兼容 wrapper 继续保留，free-list、serial、binding、registry、generation 和 publication
epoch 仍只有 manager 一个 mutable owner。测试补充未知 kind 与 FUNCTION/CMQ fallback
矩阵。本批不关闭并发、manager 外部调用窗口、SRQ lifecycle、legacy descriptor、外部
ordering/error/backpressure、Phase-1C F2 或最终 ownership 审计，计划继续 `active`。详见
`task-rdma-batch200-resource-allocator-policy-report.md`。

### Batch201 当前状态（2026-09-25）

SRQ preflight 纯值判定子批已完成：新增 `rdma_srq_preflight_value_policy.sv`，统一
SGB threshold、Function capability/encoded limit 和 borrowed SRQ backing role 集合；
`rdma_srq_lifecycle_policy::preflight()` 继续保留 authority、PD dependency、backing
clone、ring layout 与 publication owner。`rdma_queue_lifecycle_test` 及 dpu_common
integration focused 在 VCS53 PROCESS/LOGICAL PASS，UVM warning/error/fatal 为 `0/0/0`；
Python 293/293、style、queue/profile/Phase-1A、diff 门禁通过。SRQ 完整 lifecycle、并发、
legacy descriptor、外部 ordering/error、Phase-1C F2 和最终 ownership 审计仍 OPEN，计划
保持 `active`。详见 `task-rdma-batch201-srq-preflight-value-policy-report.md`。

### Batch202 当前状态（2026-09-25）

Borrowed ring 单角色校验已完成收缩：新增 `rdma_queue_borrowed_role_policy`，CQ、CEQ、
AEQ preflight 共享同一 detached pure-value helper；`rdma_queue_lifecycle_policy` 不再
保留重复的 `backing_role_count()`。空 spec、合法/错误 role 和 null slice 矩阵已加入
`rdma_queue_lifecycle_test`，queue-lifecycle 与 dpu_common integration focused、Python
293/293、style、queue/profile/Phase-1A 和 diff 门禁均通过。该批不改变 authority、
dependency、ring layout、backing clone、CMQ 或 publication owner。

allocator/registry 并发、manager 外部调用窗口、SRQ 全生命周期、跨 queue/engine 原子性、
SQD/SQE drain/flush、legacy descriptor、外部 ordering/error/backpressure、Phase-1C F2
whole-plan 和最终 ownership 审计仍 OPEN，历史结构重构计划继续保持 `active`。详见
`task-rdma-batch202-borrowed-role-policy-report.md`。

### Batch203 当前状态（2026-09-25）

Queue progress 的 flush target 与 backing ref role-cardinality 扫描已完成收缩：新增
`rdma_queue_role_cardinality_policy`，resource manager 的两个旧 helper 保留为兼容
wrapper 并只转发纯值策略。`rdma_resource_manager_test` 的 null/empty/single/duplicate
矩阵和 resource-manager focused VCS53、Python、style、queue/profile/Phase-1A、diff
门禁均通过；registry/recovery/allocator ownership 与 commit 顺序未改变。

随后 core regression 达到 `97/97 PROCESS`、`80/80 LOGICAL`，dpu_common integration
regression 达到 `10/10` pristine，所有 UVM warning/error/fatal 均为 `0/0/0`。

SRQ 全生命周期、并发、跨 queue/engine 原子性、SQD/SQE drain/flush、legacy descriptor、
外部 ordering/error/backpressure、Phase-1C F2 和最终 ownership 审计仍 OPEN，计划继续
保持 `active`。详见 `task-rdma-batch203-role-cardinality-policy-report.md`。

### Batch204 当前状态（2026-09-25）

Resource manager 的 detached publication、QP progress、queue progress 最终 commit seam
已增加统一 `mutation_guard`；busy 时返回 `RDMA_SC_RESOURCE_BUSY` 且 candidate/registry/
recovery 不变，成功/失败均释放 token。focused contention、core `97/97 PROCESS` +
`80/80 LOGICAL`、dpu_common integration `10/10`、Python/manifest/style/queue/profile/
Phase-1A/diff 门禁全部通过。该 guard 不进入外部 projection 或 allocator reservation。

完整 registry/allocator 并发、SRQ lifecycle、跨 queue/engine 原子性、SQD/SQE drain/flush、
legacy descriptor、外部 ordering/error/backpressure、Phase-1C F2 和最终 ownership 审计仍
OPEN，计划继续保持 `active`。详见
`task-rdma-batch204-publication-mutation-guard-report.md`。
