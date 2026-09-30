# RDMA 项目级结构重构计划

日期：2026-09-24。基线工作树：`feature/rdma-cmq-structural-phase2-batch160`。

2026-09-28 本地合并：Batch160–221 已进入 `main` 的 `5f8dfe9`；主线原有 reset
改动保存在 `bec0f8f`。本轮再将 `feature/rdma-structural-batch222` 的 Batch222–225
四个提交快进合入 `main`，源码基线为 `93012a3`；未推送远端。
原工作树/分支、已有缓存均保留。本轮除合并记录外不修改生产、测试或构建输入，
沿用 Batch225 与当前源码一致的 VCS53 完整验证证据；不把快进合并称为重新运行仿真。
合并后 Python 317/317、changed-SV style、lifecycle/profile/Phase-1A 和 diff 门禁通过；
Python 日志为 `/tmp/rdma_batch225_main_merge_python.log`，style 日志为空。
下文各批“未合回 main／不合并”均为当时的历史状态，以本段最新合并记录为准。

## 决策

当前业务逻辑已经相对清楚，但实现把值模型、authority admission、外部 I/O、事务
staging、可变账本和 facade policy 压在同一批大文件中。继续只做局部 helper 会降低
单个函数的重复，却不能解决跨组件理解成本。因此采用“项目级目标架构 + 小批迁移”的
方式，保留现有业务语义和单一 owner 约束；不进行一次性重写，也不先拆成大量空壳类。

现有 `docs/superpowers/plans/2026-09-17-rdma-structural-refactor.md` 继续记录历史
批次和 CMQ 证据，本文件记录后续跨组件目标和迁移顺序。两个计划均保持 `active`，
任何 focused GREEN 都不能解释为整项重构完成。

## 目标分层

当前 Batch242：基于 `9d069b9`，wait 的 32 处结束解锁合为一个出口；准入与轮询
两层 break 都通向最终解锁，中途 put/delay/get、重验和 FIFO 消费策略不变。
方法 358→331 行、tokens 1,742→1,539，生产净减 19 行；213 声明/字段不变，
不新增 owner/API。旧版/重构版/最终注释版 31 场景、65 调用专项、core 111/94、
CMQ 28/11（PROCESS/LOGICAL）、integration 10、Host-memory 3、PCIe 1、E2E 3、
Python 405/405、驱动及静态对照全部通过；UVM 0/0/0，E2E 保留既有编译告警。
初次送测与最终注释版代码 token 相同，最终输入哈希一致。见
`task-rdma-batch242-cmq-wait-delivery-report.md`；不合并、不推送，计划仍 active。

前批 Batch241：基于 `4c5b76a`，reconcile 的十处解锁/返回合为一个锁出口，
Host-visible/current pending 共用状态快照；保留 retained-first、live-only
expire/poll/reread、终态独立快照及 FIFO 不消费。入口 146→140 行，projector
91→88 行，相关 tokens 1,081→988，生产净减 6 行；不新增方法、字段、owner/API。
修订旧版/重构版 25 场景、63 查询专项、core 110/93、CMQ 28/11
（PROCESS/LOGICAL）、integration 10、Host-memory 3、PCIe 1、E2E 3、Python
401/401、驱动及静态对照门禁全部通过；UVM 0/0/0，E2E 保留既有编译告警，
最终送测哈希一致。详见
`task-rdma-batch241-cmq-reconcile-delivery-report.md`；不合并、不推送，计划仍 active。

前批 Batch240：基于 `43b40b5`，execute 的五段快照/失败回退共用一个锁内出口；
生命周期分支只选 observation 策略，armed pending 仍在锁外 wait，之后重新定位
retained authority。方法 219→180 行、tokens 1,036→851，生产净减 36 行；
213 方法声明与字段不变，没有新增 helper/owner/公开 API。修订旧版与重构版
24-case 专项、core 109/92、CMQ 28/11（PROCESS/LOGICAL）、integration 10、
Host-memory 3、PCIe 1、E2E 3、Python 397/397、驱动及静态对照门禁全部通过；
UVM 0/0/0，E2E 保留既有编译告警，最终送测哈希一致。详见
`task-rdma-batch240-cmq-execute-observation-report.md`；不合并、不推送，计划仍 active。

前批 Batch239：基于 `1d577d3`，同类 protected RETRY 阶段承接 attempt 提交、
transport 与证据交付；公共 recovery 361→227 行，不新增组件/owner/锁/公开 API，
保留真实 arm、历史累计值和首次 submit 不同的策略。生产净增 30 行，tokens
1,982→2,024，明确是主流程可读性整理。修订旧版/重构版 96-case 专项、core
108/91、CMQ 28/11（PROCESS/LOGICAL）、integration 10、Host-memory 3、PCIe 1、
E2E 3、Python 393/393、驱动和静态/等价门禁全部通过；UVM 0/0/0，E2E 保留既有
编译告警，最终送测哈希一致。详见
`task-rdma-batch239-cmq-recovery-publish-report.md`；不合并、不推送，计划仍 active。

前批 Batch238：基于 `e04e7c5`，CMQ recovery 12 处 aligned 拒绝收为一个出口，
保留早拒绝空结果、owner 两层退出、首错、成功 CAS/transport/effect 顺序及原锁；
212 声明/实例字段不变，仅增加调用期旗标。方法 375→361 行、tokens 2,161→1,982，
生产净减 9 行。旧版/重构版 36-call 专项、core 107/90、CMQ 28/11
（PROCESS/LOGICAL）、integration 10、Host-memory 3、PCIe 1、E2E 3、Python
388/388、驱动、静态/等价门禁全部通过；UVM 0/0/0，E2E 保留既有编译告警，
最终输入哈希一致。详见
`task-rdma-batch238-cmq-recovery-exit-report.md`；不合并、不推送，计划仍 active。

前批 Batch237：基于 `837afbc`，CMQ 完成 drain 按读取/匹配/提交/回收组织，
poll 主方法 261→50 行；normal/late 共用 completion 构造、journal 调用和 token
规则，保留原错误优先级、回调顺序及 partial drain。仅新增调用期四字段 struct
和两个 engine 内阶段，不新增 owner/锁/公开 API。生产净增 41 行，相关方法 tokens
1,636→1,693，明确不把主方法变短称为整体代码收缩。16-case 基线对照、core
106/89、CMQ 28/11（PROCESS/LOGICAL）、integration 10、Host-memory 3、PCIe 1、
E2E 3、Python 383/383、驱动、静态/等价门禁全部通过；UVM 0/0/0，E2E 保留既有
编译告警，最终输入哈希一致；见
`task-rdma-batch237-cmq-poll-transaction-report.md`。不合并、不推送，计划仍 active。

前批 Batch236：基于 `5a07c57` 沿用 `feature/rdma-structural-batch226`，runtime 两个
恢复提交授权入口共用一份持锁证据校验/授权消费规则；锁、factory 回调和 noalloc
状态交付各守原边界。生产 3,814→3,797 行，相关 tokens 526→312；58 public 与
实例字段不变，新增一个同类 protected 方法，不新增组件。独立 345-call 双入口/
证据/shadow/重复授权/锁/factory 矩阵在旧版与重构版均通过；core 105/88、CMQ 28/11
（PROCESS/LOGICAL）、integration 10、Host-memory 3、PCIe 1、E2E 3、Python 377/377、
驱动及等价/目录门禁全部通过。UVM 0/0/0，E2E 各保留 4 条基线编译告警，最终
送测 hashes 一致。见
`task-rdma-batch236-runtime-commit-gate-report.md`；不合并、不推送，项目仍 active。

前批 Batch235：基于 `fc8b61f` 沿用 `feature/rdma-structural-batch226`，两个 doorbell
barrier 限时 task 合为一个，不合并真正的 MMIO 写入、effect 或 Function lock。
生产 1,606→1,580 行，44→43 methods；两份 barrier 的 tokens 270→167，公开接口
不变。新增独立 23-case 策略/故障/总预算/并发取消矩阵与六项 Python 门禁；旧版
基线、重构版专项、core 104/87、CMQ 28/11（PROCESS/LOGICAL）、integration 10、
Host-memory 3、PCIe 1、E2E 3、Python 371/371、驱动及等价/静态审计全部通过。
E2E 各保留 4 条基线编译告警，最终送测 hashes 一致。详见
`task-rdma-batch235-doorbell-barrier-report.md`；不合并、不推送，项目仍 active。

前批 Batch234：基于 `f4933f0` 沿用 `feature/rdma-structural-batch226`，将 backing
四入口的重复搬运收为一个写循环和一个读循环。各入口保留原 DMA 方向、预检/null
策略、诊断和 device backend-started 语义；不新增 owner/字段。生产 619→603 行，
搬运相关 tokens 951→725，11 个公开声明不变，增加两个 protected helper。
新增 80-case queue/QP 三段故障矩阵与六项 Python 门禁；修订旧版基线、重构版专项、
core 103/86、CMQ 28/11（PROCESS/LOGICAL）、integration 10、Host-memory 3、PCIe 1、
E2E 3、Python 365/365、驱动及等价/静态门禁全部通过。E2E 各保留 4 条基线编译
告警；送测后仅修订一处测试注释，tokens 与最终 hashes 已核对。详见
`task-rdma-batch234-backing-transfer-report.md`；不合并、不推送，项目仍 active。

前批 Batch233：基于 `e1b8ed5` 沿用 `feature/rdma-structural-batch226`，把 CEQ/AEQ
路由后的 result/continuation 准备收进原提交入口，改名 `consume_routed_event`。
decode、owner、route、AEQ epoch 与 CQ flush partial 判定仍留在各自 caller；不新增
生产组件/owner/状态。生产净减 46 行，两个 poll_once 从 93/109→50/68 行；27 个公开
声明不变，一个 protected task 改名/改签名。共同准备展开与原提交尾段 token 等价。
重构前/后 44-case 矩阵、core 103/86、CMQ 28/11（PROCESS/LOGICAL）、integration 10、
E2E 3、Host-memory 3、PCIe 1、Python 359/359、驱动及静态门禁全部通过；E2E 保留
基线编译告警，原送测输入与最终注释修订版 token 相同，最终专项及 hashes 已核对。
不合并、不推送，见 `task-rdma-batch233-event-consume-report.md`；项目仍 active。

前批 Batch232：基于 `8e7145d` 沿用 `feature/rdma-structural-batch226`，把 CQ resize
retry 的 17 份失败诊断保存/解锁/返回续接合为一个出口。入口拒绝、两阶段成功、
authority 校验、恢复进度及 factory 时机保持原规则；不引入方法/状态/owner。
生产文件 9,929→9,910 行，净减 19 行；retry 方法 243→221 行，139 声明/类壳不变。
扩展既有 resize test 的 22-case retry 矩阵与五项 Python 门禁；重构前基线、终版
专项、core 103/86、CMQ 28/11（PROCESS/LOGICAL）、integration 10、E2E 3、Host-memory
3、PCIe 1、Python 354/354、驱动契约及静态/注释门禁全部通过。三项 E2E 各保留
4 条基线编译告警，送测输入 hashes 一致。
不合并、不推送，见 `task-rdma-batch232-resize-retry-exit-report.md`，项目仍 active。

前批 Batch231：基于 `dad8d20` 沿用 `feature/rdma-structural-batch226`，让门铃
envelope/scheduler 复用 rdma_status 字段实现，删除三个重复 helper；legacy 的枚举
准入仍留在 envelope，不变成通用字段 helper 的额外校验。生产净减 84 行，
文件 1,690→1,606 行、47→44 methods；44 保留方法 token 等价，15 个公开声明及
六个类壳不变。新增 148-case 原始诊断/legacy 编码/factory 矩阵与三项 Python 门禁，
最终专项、core 103/86、CMQ 28/11（PROCESS/LOGICAL）、integration 10、E2E 3、
Host-memory 3、PCIe 1、Python 349/349、驱动契约及静态/注释门禁全部通过；
三项 E2E 各保留 4 条基线编译告警，送测输入 hashes 一致。
不合并、不推送，main 保持 `083e0d7`；详见
`task-rdma-batch231-doorbell-status-report.md`，项目仍 active。

前批 Batch230：基于 `b4d81b0` 沿用 `feature/rdma-structural-batch226`，将 runtime/
queue-data 的重复状态字段操作归入 `rdma_status`，移除三个旧 helper，新增两个
static automatic 值方法；不新增组件/owner/转发壳，生产净减 65 行。runtime fallback、
queue-data null、typed-create 与 legacy 枚举检查仍分别保留；264 个保留方法展开后
token 等价，runtime/engine 的公开业务声明与类壳不变。新增 162-case 状态矩阵、
五项 Python 门禁；最终专项、core 103/86、CMQ 28/11（PROCESS/LOGICAL）、integration
10、E2E 3、Host-memory 3、PCIe 1、Python 346/346、驱动契约及静态/注释门禁全部
通过；三项 E2E 各保留 4 条基线编译告警。不合并、不推送，main 保持
`083e0d7`。详见 `task-rdma-batch230-status-values-report.md`，项目仍 active。

前批 Batch229：基于 `cf502a5` 沿用 `feature/rdma-structural-batch226`，把 runtime
深复制/值比较/状态构造集中迁入无状态 projector，原 owner 保留锁、authority、游标/
credit/reservation/recovery admission 与提交。20 个 protected 方法迁出，公开 cursor
比较入口保留，58 个公开声明不变；94 原方法 token 等价。runtime 4,646→3,814 行、
94→74 methods，新 projector 884 行/21 methods，生产合计 +53 行，属于职责收缩。
独立深复制/24-case 工厂/嵌套复制专项、core 103/86、CMQ 28/11（PROCESS/LOGICAL）、
integration 10、E2E 3、Host-memory 3、PCIe 1、Python 341/341、驱动契约与静态/注释
门禁全部通过；E2E 保留基线编译告警。
不合并、不推送，main 保持 `083e0d7`。详见
`task-rdma-batch229-runtime-projector-report.md`，项目仍 active。

前批 Batch228：基于 `508ba49` 沿用 `feature/rdma-structural-batch226`，统一 SQ/RQ/SRQ
提交尾段七处恢复调用；入口 prior-write、NO_SUBMIT/AMBIGUOUS 和已提交出口仍各自
保留原规则。只增加两个调用局部值，不增加 owner/方法/实例状态；engine 9,931→9,929
行、方法 token 828→679，属于恢复调用去重而非大规模代码收缩。139 声明、27 public
及其余 138 正文不变，七类续接展开后 token 等价。新增 53-case 矩阵与六项 Python
门禁；修订后专项、core 102/85、CMQ 28/11（PROCESS/LOGICAL）、integration 10、
E2E 3、Host-memory 3、PCIe 1、Python 335/335、驱动契约与静态/注释门禁全部通过；
E2E 保留基线编译告警。
不合并、不推送，main 保持 `083e0d7`。详见
`task-rdma-batch228-host-producer-exit-report.md`，项目仍 active。

前批 Batch227：基于 `2ee9ff6` 沿用 `feature/rdma-structural-batch226`，将设备发布
准备提取到内部函数，九个准备失败取消续接交由原 task 统一编排。普通局部值记录
不新增 owner/实例状态；入口拒绝、reservation-only、完整 pending 的权限分界和原
factory/字段读取时机不变。生产净增 15 行，engine 9,916→9,931 行、138→139 methods；
I/O task 268→121 行，不冒充总代码收缩。全部原声明、137 个正文、I/O 尾段不变，
准备段规范化后 token 等价。新增 126-case 矩阵与六项 Python 门禁；最终 focused、
core 101/84、CMQ 28/11（PROCESS/LOGICAL）、integration 10、E2E 3、Host-memory 3、
PCIe 1、Python 329/329、驱动契约与静态/注释门禁通过；E2E 保留基线编译警告。
不合并、不推送，main 保持 `083e0d7`。见
`task-rdma-batch227-device-publish-prepare-report.md`，项目仍 active。

前批 Batch226：基于已合并的 `083e0d7`，在独立 `feature/rdma-structural-batch226`
收束 CQ/CEQ/AEQ 设备发布的四类写后失败出口。写前取消、异常未写成功、正常成功和
replay 保留各自边界；两次状态复制及其 factory 窗口不变。无新增生产方法/类级状态/owner，
engine 9,934→9,916 行；137 个正文、全部 138 声明及类壳 token 不变，发布方法展开
共同尾段后等价。最终 30-case focused、core 100/83、CMQ 28/11（PROCESS/LOGICAL）、
integration 10、E2E 3、Host-memory 3、PCIe 1、Python 323/323、驱动契约及静态门禁
均通过；E2E 保留基线编译警告。不合并、不推送，main 保持 `083e0d7`。详见
`task-rdma-batch226-device-publish-exit-report.md`，项目仍 active。

前批 Batch225：CQ resize 的 20 个发布前失败续接统一到一个 rollback 出口；发布后
清理故障仍直接保留新 authority 和 recovery record。不新增方法/状态/owner，engine
9,977→9,934 行，138 methods 与 27 个公开声明不变；137 个正文 token 不变，resize
展开尾段后与基线 token 一致。新增 16-case 故障矩阵与六项 Python 门禁；额外发现并
排除了命名块 disable 的跨 engine 嵌套退出风险，最终使用单次循环 break。最终
core 99/82、CMQ 28/11（PROCESS/LOGICAL）、integration 10、E2E 3、Host-memory 3、
PCIe 1、focused 16-case、Python 317/317、驱动契约及静态门禁均通过；E2E 保留基线
编译警告。详见
`task-rdma-batch225-cq-resize-exit-report.md`，项目仍 active。

前批 Batch224：CQ/event live poll 与 consumer replay 共用 doorbell evidence/CI commit
两个步骤；原业务 admission、shadow/WQE 分支与恢复跳步仍由 caller 决定。不新增生产
文件或 mutable owner，engine 10,000→9,977 行、136→138 methods，生产净减 23 行。
全部原声明不变，133 个方法 token 不变，三个 caller 展开公共步骤后与基线 token 一致。
新增 45-case 独立故障矩阵与六项 Python 门禁；最终 core 98/81、CMQ 28/11
（PROCESS/LOGICAL）、integration 10、E2E 3、Host-memory 3、PCIe 1、focused 45-case、
Python 311/311、驱动契约及静态门禁均通过，E2E 保留已记录的基线编译警告。
详见 `task-rdma-batch224-consumer-commit-steps-report.md`，项目计划仍 active。

前批 Batch223：从 queue-data engine 集中迁出 25 个值投影/身份谓词，形成无状态
`rdma_queue_data_projector`；engine 10,872→10,000 行、161→136 methods，两个生产
文件合计 +17 行，不冒充总代码净减。全部原方法 token 与 27 个公开业务声明核对
一致，owner/I/O/commit 顺序保留；最终 core 97/80、CMQ 28/11（PROCESS/LOGICAL）、
integration 10、E2E 3、Host-memory 3、PCIe 1、独立值测试、Python 305/305、驱动契约
及静态门禁均通过，E2E 保留已记录的基线编译警告。
详见 `task-rdma-batch223-queue-data-projector-report.md`，项目计划仍 active。

前批 Batch222 在合并主线之后继续：复用 queue-data 既有无分配字段 helper，移除
状态初始化/复制的两段重复赋值；engine 10,896→10,872 行，161 methods 与公开声明
不变，不新增生产组件。新增 null、自复制、全部字段及 factory/hook 边界测试；最终
core 97/80、CMQ 28/11（PROCESS/LOGICAL）、integration 10、E2E 3、Host-memory 3、
PCIe 1、Python 299/299、驱动契约与静态门禁全部通过，E2E 既有警告单列。
本批尚未合回 main，见 `task-rdma-batch222-queue-status-transfer-report.md`。

前批 Batch221（2026-09-28）：将 47 个 detached projection/identity 方法集中
提取到无状态 `rdma_resource_projector`，manager 从 10,150 行/186 methods 降到
7,936 行/139 methods；两文件合计净增 3 行，属于职责收缩而非总代码量下降。
公开 API、mutable owner、回调顺序及 commit 门禁保持不变；最终 core 97/80
（PROCESS/LOGICAL）、integration 10、CMQ 28/11、E2E 3、Host-memory 3、PCIe 1、
Python 299/299、驱动契约与静态门禁全部通过，E2E 既有编译警告单列。详见
`task-rdma-batch221-resource-projector-report.md`，项目仍 active。

前批 Batch220：Batch218/219 的完整验证证据独立保留。该批把
allocator 首次 binding 登记和 ID/serial 消费收束到同一 guard commit，入口冻结
admission epoch，外部投影先准备、校验后才写入；已饱和 epoch 不再接纳新 reservation。
四个 fixture 共 131 个真实 status factory 窗口及 12 次额外故障的最终 focused 已通过；
core 97/80（PROCESS/LOGICAL）、integration 10、CMQ 28/11、E2E 3、Host-memory 3、
PCIe adapter 1、Python 293/293、驱动契约和静态门禁全部通过。
记录见 `task-rdma-batch220-allocator-admission-commit-report.md`。
manager 大文件职责收缩、Phase B/D 的组合验收及 Phase E 包 DAG 仍未完成，
不能将公共 helper 或安全门禁落地等同于项目结构和可读性已验收。

```text
L0 types/value       enum、plain value、handle/cursor/route/epoch 快照
L1 authority         dpu_common 冻结快照、Function/BDF/BAR/route/reset admission
L2 codec/profile     SQE/RQE/CQE/CEQE/AEQE/doorbell/CMQ wire encode/decode
L3 transaction       queue/CMQ/resource 的 plan → stage → external I/O → commit 候选
L4 engine policy     SQ/RQ/CQ/EQ/CMQ 业务分支和 caller-visible 顺序
L5 mutable owner     runtime、journal、resource registry、reset lease 的唯一账本 owner
L6 integration       router、reset coordinator、host/PCIe/net adapter 非拥有边界
```

约束：L0/L1/L2 不读取 L4/L5 可变状态；L3 只保存 detached candidate，不创建第二
账本或第二把锁；L4 决定 admission、重试、超时和错误映射；L5 才能提交 mutation；
L6 只协调外部生命周期并在边界验证完整 route、authority 和 reset epoch。

## 当前复杂度证据与优先级

| 优先级 | 组件 | 当前规模 | 目标 | 首个可迁移职责 |
| --- | --- | ---: | --- | --- |
| P0 | `rdma_queue_data_engine.sv` | 9,864 行/139 methods | 继续收束统一 transaction seam | 值 projector、consumer 步骤、event 路由后事务、resize 回滚/retry 出口、设备发布准备/取消/写后出口和 host-producer 失败出口已分层；继续完整业务编排与组合边界 |
| P1 | `rdma_resource_manager.sv` | 7,936 行/139 methods | 继续收束 allocator、registry、rollback transaction | projector 已分离；继续检查 publication 后更新，不改变 resource owner |
| P1 | `rdma_queue_runtime.sv` | 3,797 行/75 methods | runtime snapshot/predicate 与 mutation owner 分界 | 深复制/值比较已迁入 projector，双入口恢复授权规则已同源；继续 snapshot/commit 业务组合与重复状态处理 |
| P2 | `rdma_queue_lifecycle_policy.sv` + queue/QP executors | 2,118 / 2,819 / 4,338 行 | policy、执行副作用、状态迁移表分离 | operation envelope 与 transition candidate |
| P2 | `rdma_reset_coordinator.sv` | 2,127 行/55 methods | 只保留全局 reset lease/epoch 协调 | reset evidence/candidate，禁止复制 queue/CMQ ledger |
| P3 | `rdma_doorbell_scheduler.sv` | 1,580 行/43 methods | descriptor/polarity/cursor 纯值层 | 通用状态字段已复用 types，barrier 限时能力已共用；detached doorbell plan 待推进 |

SQ/RQ/CQ/EQ facade 当前已经较薄，不单独继续拆分；它们应成为 L4 policy adapter，
公共复杂度回收到 queue-data/runtime transaction 层。Host-memory、PCIe、网络和
dpu_common 外部对象继续由外部环境拥有，本项目只维护显式 adapter/router。

上表 queue-data/manager/runtime 已分别按 Batch233/221/236 源码重测，doorbell 按 Batch235，
其余维持 Batch218；
独立 queue-data projector 为 831 行/23 methods，resource projector 为 2,217 行/47 methods，
runtime projector 为 830 行/20 methods；公共 rdma_status 为 280 行/10 methods。
Batch234 backing access 为 603 行；access 类 24 methods，另含 span 构造函数，
读写字节循环共享，DMA 方向和后端失败策略仍由明确的公开入口决定。
Batch230 将无分配状态字段操作归入 types，不改变三个业务 owner 的规模和生命周期职责。
后续在统一 owner/提交契约稳定后仍须收敛重复校验，
不以删注释、压缩行或新增大量单函数文件代替可读性改进。

Batch221 按 Batch220 的候选闭包完成逐项复审与集中提取：33 个 projector 加支撑方法
共 47 个，valid_kind 复用 allocator policy。无状态不等于纯函数，mapping authority、
slot token/CQC clone、factory 和 identity 回调均保留；不能把 manager commit/可变 owner
迁入 projector，不能以词法无 ledger 访问替代回调重入验证。

## 分阶段迁移

### Phase A：冻结边界与可观测行为

1. 为每个组件登记唯一 mutable owner、输入快照、外部调用窗口和 commit 点。
2. 保留现有 public API，补齐 queue/resource/reset 的 focused characterization gate。
3. 为每一批固定源码 method scanner、ownership、style、manifest、字段变异和 VCS53
   回归结果；不在此阶段改变业务顺序。

### Phase B：Queue Data Engine

1. 新增 queue transaction models：attachment、cursor、route/epoch、poll/post/publish
   candidate；engine 继续拥有 attachment/runtime/ledger。
2. 新增 queue transaction kernel：ring geometry、cursor advance、target contract 和
   detached key/predicate；SQ/RQ/CQ/CEQ/AEQ 只提供 policy/admission 差异。
3. 统一 `admit → stage → external I/O → commit` 的 producer、consumer、event 和
   resize/recovery 骨架；保留 CQ→WQ release、SRQ、UD、legacy descriptor 的业务分支。
4. 只有所有 caller 迁移并通过组合矩阵后，才删除 engine 内兼容 wrapper。

### Phase C：Resource Manager 与 Runtime

1. 从 resource manager 迁出 allocator/factory 的 detached plan 和 rollback candidate，
   manager 继续作为 resource registry 与 publication owner。
2. 从 queue runtime 迁出 immutable runtime snapshot、occupancy/cursor predicates，
   runtime mutation 仍由单一 owner 提交。
3. 任何跨 Function、generation、BDF/BAR 或 topology 的 authority 继续回到
   `dpu_common` 冻结快照，不在 transaction kernel 中重新推导。

### Phase D：Lifecycle、Reset 与 Control Plane

1. 把 lifecycle/QP/control-plane 的重复 operation envelope 收束为统一的 detached
   request/result/status 结构；各 executor 保留自己的业务 policy。
2. reset coordinator 只管理 lease、epoch、quiesce/release/commit 顺序；queue、CMQ、
   resource owner 通过 candidate 接入，不把账本复制到 coordinator。
3. 完成 legacy `last_*`/compatibility seam 的 characterization 后再逐项删除，不能
   在架构拆分同时改变错误码和可观察 completion 顺序。

### Phase E：包与目录模块化

只有 Phase B–D 的 owner 和依赖稳定后，才把当前单一 `rdma_core_pkg` 拆成依赖 DAG：

```text
rdma_types_pkg
  → rdma_value_pkg / rdma_authority_pkg
  → rdma_codec_pkg / rdma_adapter_pkg
  → rdma_transaction_pkg
  → rdma_engine_pkg
  → rdma_integration_pkg
```

每次只移动一个 include cluster，并保留临时 compatibility package；禁止通过 `import`
循环或前置声明掩盖真实 ownership。包拆分不是第一步，避免把当前复杂度转移成编译
依赖复杂度。

## 每批验收标准

- 业务顺序、错误码、timeout/late/reset 结果和外部 adapter 生命周期不变。
- 一个 mutable state domain 只有一个 owner；新 helper 不持有第二份 ledger、lock 或
  隐式全局缓存。
- 相关 focused VCS53、CMQ/core/queue/resource/reset 组合回归通过，UVM
  warning/error/fatal 均为 0/0/0。
- `git diff --check`、changed-SV style、中文 function/file contract、ownership、
  Phase-1A、profile、keyword、external dependency lock 全部通过。
- 覆盖矩阵、批次报告和 scanner 计数同步更新；未完成的跨线程并发、SRQ lifecycle、
  外部 ordering/error 和 Phase-1C F2 明确保持 OPEN。

## 明确不做

- 不把 SQ/RQ/CQ/EQ/CMQ 合成一个万能 engine 或万能 transaction owner。
- 不复制 dpu_common 的 Host/PF/VF/BDF/BAR/topology authority。
- 不修改外部依赖仓库，不把外部对象生命周期转移到本项目。
- 不在没有 characterization gate 的情况下删除 legacy facade、compatibility accessor
  或 reset/recovery seam。

## Batch191：CQ consumer release transaction seam（已完成本批，计划仍 active）

`rdma_queue_data_engine` 的 live CQ poll 与 consumer recovery retry 现在共享
`execute_consumer_wqe_release()`：它只接收已冻结的 pending/CQE/target 值，统一执行
CQ release gate、routed WQ release、gate finish 与 failure evidence 记录。runtime 仍是
唯一 mutable owner，caller 仍负责 shadow/doorbell 和 recovery 阶段，不把 queue、lock、
ledger 或外部 backing 生命周期下放到 helper。`release_consumer_pending_wqe()` 保留为
兼容入口并委托公共 task。

VCS53 的 runtime、queue-data poll、queue-data recovery focused 均 PROCESS/LOGICAL PASS，
UVM warning/error/fatal 为 0/0/0；Python 293/293、changed-SV style、diff gate 通过。
这只关闭一个重复事务 seam；SRQ 完整生命周期、跨 queue/engine 并发、legacy descriptor、
外部 ordering/error/backpressure、Phase-1C F2 whole-plan、manager 外部调用窗口和最终
ownership 审计仍保持 OPEN。

## Batch161：QP lifecycle transition policy（已完成本批，计划仍 active）

本批按 Phase D 的最小迁移边界，把 QP 状态迁移决策从执行副作用中抽离：新增
`src/core/rdma_qp_transition_policy.sv`，集中描述业界 verbs 主干
`RESET→INIT→RTR→RTS`、`ERROR/RESET` 回退以及本项目仍未实现的 `SQD/SQE` capability
gate。policy 是无状态纯值函数，只返回 semantic-only、full-modify 或 invalid decision，
不读取 QP/resource/CMQ 可变账本，也不拥有任何外部 adapter。

`rdma_qp_lifecycle_executor.sv` 仅调用 policy 并把 decision 映射回既有
`state_only/full_modify` 分支；outstanding WQE 拒绝、QPC staging/query、CMQ 提交、
generation fence、错误优先级和 resource manager commit 顺序均保持在 executor。当前
`SQD/SQE` 继续返回 `RDMA_SC_UNSUPPORTED_OPCODE`，不在本批提前引入 drain/flush 语义。

验收证据：`rdma_qp_lifecycle_test` 新增合法主干、ERROR/RESET、非法迁移和 SQD/SQE
capability gate 断言；QP lifecycle/recovery 与 control-plane 两项及其 CMQ 组合在
VCS53 登录 bash 中均 PROCESS/LOGICAL PASS，UVM warning/error/fatal 为 0/0/0。Python
293/293、changed-SV style、diff、manifest/keyword、queue/profile、Phase-1A、外部依赖
锁和全目录中文契约扫描（192 文件、5,498 methods、0 hard diagnostics）均通过。

后续按计划继续处理 QP drain/flush 与 destroy dependency、跨队列并发、reset 统一验收，
并从 Batch163 的 allocator candidate 继续推进 resource/runtime transaction seam；本计划
不能因本批 GREEN 而标记完成。

## Batch162：resource lifecycle blocker snapshot（已完成本批，计划仍 active）

本批按 Phase C 的最小安全边界收束资源生命周期 admission 的重复只读判定。新增
`rdma_resource_manager::snapshot_activity_blockers()`，由 resource manager 继续唯一读取
registry、依赖拓扑和 `outstanding_ids`，只输出 detached 的 `has_live_dependents` 与
`has_outstanding_operations` 两个 blocker bit；它不维护第二份账本、不取得外部对象所有权，
也不替 QP policy 推导 destroy 语义。`begin_quiesce()`、`finalize_qp_release()`、
`finalize_release()` 和 `release_reserved()` 复用该 snapshot，但保留各自原有的状态门禁、
错误文案/优先级、recovery 检查与 `force_release_key()` 提交点。

验收证据：`rdma_resource_manager_test`、`rdma_queue_lifecycle_test`、
`rdma_qp_lifecycle_test`、`rdma_qp_recovery_test` 和 `rdma_control_plane_test` 在 VCS53
登录 bash 中均 PROCESS/LOGICAL PASS，UVM warning/error/fatal 为 0/0/0；全目录中文契约
scanner 覆盖 192 文件（190 `.sv`、2 `.svh`）、5,499 methods、0 hard diagnostics，
changed-SV style 与 `git diff --check` 通过。依赖优先、outstanding busy、QP destroy 早拒绝、
QP recovery finalize 和 reservation busy 的既有行为未改变。

本批仍不宣称关闭 QP/SRQ 跨资源 destroy dependency 的完整组合、跨队列并发、reset 统一
验收、manager 外部调用窗口补偿或最终 ownership 审计；计划状态继续保持 `active`。

## Batch163：resource allocator/factory transaction seam（已完成本批，计划仍 active）

本批按 Phase C 的最小迁移边界新增 `rdma_resource_identity_candidate` detached value，
集中保存一次 identity 预留的 `owner`、`handle`、`local_id`、`prior_serial`、free-list
来源和首次 binding registration 标记。`reserve_identity_candidate()` 复用 manager 原有
`reserve_identity()`，`rollback_identity_candidate()` 复用原有
`rollback_identity_reservation()`；因此 allocator 数组、binding registration、registry
和 publication 仍只有 `rdma_resource_manager` 一个 mutable owner。

PD/MR/CQ/QP/SRQ/CMQ/CEQ/AEQ 的 `create_*` 入口现在共享
`reserve→construct→register→publish` 的 candidate 骨架，字段投影、依赖校验、错误优先级、
QP sequence 更新和 Function 专用 incarnation 路径保持不变。candidate 的 `valid()`/`clear()`
只处理 transient 值，不访问 outstanding/recovery/reset 账本，也不接管外部 adapter；
`create_function()` 继续保留专用路径，避免把 Function tombstone 语义误并入普通对象工厂。

验收证据：`rdma_resource_manager_test`、`rdma_queue_lifecycle_test`、
`rdma_qp_lifecycle_test`、`rdma_qp_recovery_test`、`rdma_control_plane_test` 均在 VCS53
登录 bash 中 PROCESS/LOGICAL PASS，UVM warning/error/fatal 为 0/0/0；Python 293/293、
changed-SV style、`git diff --check`、queue lifecycle、profile 和 Phase-1A 门禁通过。
当前源码为 193 个文件（191 `.sv`、2 `.svh`）、5,504 个 function/task（`.sv` 5,502、
`.svh` 2）、0 diagnostics；新增 5 个带中文三段契约的方法。本批
只收束 allocator/factory 的重复事务边界，不关闭 allocator 并发、跨 incarnation destroy、
QP/SRQ 组合生命周期、queue runtime snapshot、reset 统一验收或最终 ownership 审计，计划
继续保持 `active`。详见 `task-rdma-batch163-resource-allocator-transaction-report.md`。

## Batch164：queue runtime detached value models（已完成本批，计划仍 active）

本批按 Phase C 的下一最小迁移边界新增
`src/core/rdma_queue_runtime_transaction_models.sv`，集中定义 runtime 专用枚举、
`rdma_queue_cursor_snapshot`、`rdma_queue_pending_operation` 和
`rdma_queue_slot_ledger_entry`。`rdma_queue_runtime.sv` 继续独占 attachment、锁、PI/CI、
occupancy、reservation、slot/pending publication、recovery gate 和 route/epoch mutation；
新文件只保存 detached transaction value，不读取或复制 mutable ledger，也不接管外部
Host-memory/PCIe/adapter 生命周期。

本批保持既有 do_copy 兼容语义和 runtime non-fatal clone 边界，未改变 pending recovery、
consumer shadow/MMIO evidence、slot completion、cursor wrap 或 reset-epoch 验证。VCS53
登录 bash 的 runtime、queue-data post/poll/recovery focused 均 PROCESS/LOGICAL PASS，
UVM warning/error/fatal 为 0/0/0；Python 293/293、changed-SV style、diff 和全目录契约
scanner（194 个源码文件、5,502 methods、0 diagnostics）通过。详见
`task-rdma-batch164-runtime-value-models-report.md`。

本批仍不关闭跨队列/跨线程并发、SRQ 全生命周期、reset 统一验收、外部 ordering/error、
manager 外部调用窗口补偿和最终 ownership 审计；计划状态继续保持 `active`。

## Batch165：Function identity candidate seam（已完成本批，计划仍 active）

本批处理 Batch163 保留的 Function 专用 allocator 路径：新增
`rdma_function_identity_candidate`，保存 detached owner、handle、trusted binding、owner key、
local ID、free-list 来源和首次 registration 标记；`rdma_resource_manager` 新增专用
`reserve_function_identity_candidate()`/`rollback_function_identity_candidate()`，而
`create_function()` 采用 reserve→construct→register/publish→clear 的可读骨架。

Function 的 generation/high-water、duplicate incarnation、older generation 和 released
tombstone admission 仍按原顺序执行，普通 resource candidate 仍拒绝 FUNCTION kind；candidate
不复制 registry、generation ledger、outstanding/recovery 或 reset authority。resource-manager
focused VCS53 PROCESS/LOGICAL PASS，UVM 0/0/0；changed-SV style、diff 和全目录 scanner
（194 个源码文件、5,507 methods、0 diagnostics）通过。详见
`task-rdma-batch165-function-identity-candidate-report.md`。

本批仍不关闭 allocator/registry 并发、跨 incarnation destroy dependency、QP/SRQ 组合生命
周期、queue runtime snapshot、reset 统一验收、manager 外部调用窗口补偿和最终 ownership
审计；计划继续保持 `active`。

## Batch166：lifecycle result seed（已完成本批，计划仍 active）

本批按 Phase D 的最小迁移边界新增 `src/model/rdma_lifecycle_transaction_models.sv`，以
`rdma_lifecycle_result_seed` 统一 control-plane、queue lifecycle 和 QP lifecycle executor
重复的 detached 结果初始化：transaction id、业务域、未完成 status、初始资源状态和
recovery 标志。seed 不读取或复制 mutable ledger，不保存 manager/CMQ/外部 adapter 引用；
各 executor 仍保留自己的 admission、CMQ 顺序、policy、recovery 和 resource commit owner。

`rdma_queue_lifecycle_executor::make_result()`、`rdma_control_plane::make_result()` 以及
QP create/modify/destroy/recover 共用该 seed，transaction id 为 0 的原有入口 guard、错误
优先级和 status clone 语义不变。`rdma_control_plane_test`、`rdma_queue_lifecycle_test`、
`rdma_qp_lifecycle_test` 在 VCS53 登录 bash 中均 PROCESS/LOGICAL PASS，UVM
warning/error/fatal 为 0/0/0；详见 `task-rdma-batch166-lifecycle-result-seed-report.md`。

本批仍不关闭 reset evidence/candidate、QP/SRQ 跨资源 destroy dependency、跨队列/跨线程
并发、SQD/SQE drain/flush、外部 ordering/error、manager 外部调用窗口补偿或最终 ownership
审计，计划继续保持 `active`。


## Batch167：reset epoch candidate（已完成本批，计划仍 active）

本批把 reset coordinator 的 Function epoch staged map 收束为
`src/model/rdma_reset_transaction_models.sv` 中的 `rdma_reset_epoch_candidate`。candidate
只拥有 detached map、`valid` 标志和 capture/validate/clear 生命周期；它不复制
lease、authority、router、resource、recovery 或外部 adapter 所有权。

`prepare_function_epoch_commit()` 统一 candidate capture、Function scope 预检、epoch
递增和最终 validate；VF/PF/Host/Device reset implementation 仍只在所有 scope 检查通过后
由 coordinator 一次性提交 `m_function_epochs`，reset policy、quiesce/release 顺序和
publication owner 没有下放。测试补充 source alias 隔离、unknown/空 map、clear 后拒绝和
现有 reset scope 行为断言。

验收证据：在 `ubuntu@10.11.10.53` 登录 bash 中，以锁定的
`DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common` 运行
`rdma_reset_coordinator_test`、`rdma_reset_coordinator_pf_root_scope_test` 和
`rdma_reset_coordinator_lifecycle_test`，三项均 PROCESS/LOGICAL PASS，UVM
warning/error/fatal 为 0/0/0。详见 `task-rdma-batch167-reset-epoch-candidate-report.md`。

本批仍不关闭跨线程/跨进程 coordinator 并发、QP/SRQ 跨资源 destroy dependency、SQD/SQE
drain/flush、外部 ordering/error、manager 外部调用窗口补偿和最终 ownership 审计；项目级
计划继续保持 `active`。

## Batch168：resource activity blocker detached snapshot（已完成本批，计划仍 active）

本批在 `src/core/rdma_resource_transaction_models.sv` 新增
`rdma_resource_activity_blocker_snapshot`，将 resource manager 多个 quiesce/finalize/
release 入口重复的 `has_live_dependents` 与 `has_outstanding_operations` 收束为一次只读
扫描结果，并附带依赖/在途数量。`snapshot_activity_blockers()` 仍唯一读取 manager
registry 与 `outstanding_ids`；caller 继续按依赖优先顺序映射既有错误码、文案和状态迁移，
没有复制 ledger、lock、recovery 或 reset authority。

resource-manager probe 的 dependency fixture 验证 PD 的三个直接 dependent 和零 outstanding；
`rdma_resource_manager_test`、`rdma_queue_lifecycle_test`、`rdma_qp_lifecycle_test`、
`rdma_control_plane_test` 在 VCS53 均 PROCESS/LOGICAL PASS，UVM warning/error/fatal 为
0/0/0。当前全目录中文契约 scanner 为 196 个源码文件、5,518 个 function/task、0 hard
diagnostics。详见 `task-rdma-batch168-activity-blocker-snapshot-report.md`。

本批仍不关闭 QP/SRQ 更广泛 destroy dependency 组合、跨线程/跨队列并发、SQD/SQE drain/flush、
外部 ordering/error、manager 外部调用窗口补偿和最终 ownership 审计；项目级计划继续保持
`active`。

## Batch169：queue-data detached result models（已完成本批，计划仍 active）

本批新增 `src/core/rdma_queue_data_transaction_models.sv`，把
`rdma_queue_post_result`、`rdma_queue_device_publish_result`、`rdma_queue_completion_result`
和 `rdma_queue_event_result` 从 11K 行 queue-data engine 的实现入口移出。新文件只保存
调用方可观察的 detached handle/image/status/slot 值；不复制 runtime ledger、registry、
mapping、manager 或外部 adapter 所有权。`rdma_core_pkg` 以稳定顺序 include 新模型，engine
继续独占 attachment、poll/post/recovery 和 runtime mutation。

poll、post、recovery、device-publish 和 event-route 五项 VCS53 focused 均
PROCESS/LOGICAL PASS，UVM warning/error/fatal 均为 0/0/0（device-publish 保留既有
informational factory override）。详见 `task-rdma-batch169-queue-data-result-models-report.md`。

本批仍不关闭 queue-data 全量 parent/core regression、跨队列并发、SRQ 全生命周期、legacy
descriptor、外部 ordering/error、engine-level 全局锁和最终 ownership 审计；项目级计划继续
保持 `active`。

## Batch170：queue-data attachment models（已完成本批，计划仍 active）

本批继续从 queue-data engine 顶层移出 `rdma_queue_data_attachment`、
`rdma_queue_data_qp_link` 和 `rdma_cq_resize_recovery`，放入
`src/core/rdma_queue_data_transaction_models.sv`。`rdma_core_pkg` 保持 backing-access
先定义、transaction models 后定义的顺序；engine 现在只保留 attachment/link/recovery
索引的编排和 runtime/backing mutation。

模型字段和默认状态不变，仍不拥有 manager、Host-memory、PCIe、mapping 或 runtime ledger。
当前源码边界的 poll、CQ、EQ focused 均 PROCESS/LOGICAL PASS，UVM warning/error/fatal 为
0/0/0；Batch169 的 post/recovery/device-publish/event focused 作为交叉消费者证据继续有效。
随后刷新 current-boundary parent regressions：CMQ gate 28/28 process、11/11 logical，
core regression 97/97 process、80/80 logical，全部 UVM pristine；integration regression
10/10 scenarios 也在锁定 dpu_common 依赖下 pristine。
详见 `task-rdma-batch170-queue-data-attachment-models-report.md`。

本批仍不关闭 queue-data current-boundary parent/core regression、跨队列并发、SRQ lifecycle、
legacy descriptor、外部 ordering/error、engine-level 全局锁和最终 ownership 审计；项目级
计划继续保持 `active`。

## Batch171：QP/SRQ 组合依赖 blocker snapshot（已完成本批，计划仍 active）

本批继续收束 `rdma_resource_manager` 的 destroy dependency admission。扩展
`rdma_resource_activity_blocker_snapshot`，在已有总 dependent/outstanding 计数之外记录
QP/SRQ 分类、非 QP dependent 以及 dependent 自身 outstanding；`snapshot_activity_blockers()`
仍是唯一读取 registry 和 `resource.outstanding_ids` 的入口，不复制 registry、lock、
recovery 或外部资源所有权。`begin_cq_resize()` 复用该 detached snapshot，保留“空闲 QP
仍引用 CQ 可以 resize”的业务语义，同时对非 QP dependent 或有 manager-visible work 的
QP 原子拒绝。

`rdma_resource_manager_test` 的 hostile dependency fixture 新增 PD→SRQ→QP 组合断言，验证
PD 同时统计 QP/SRQ/其它 dependent，SRQ 仅由 QP 引用；resource-manager VCS53 focused
PROCESS/LOGICAL PASS，UVM warning/error/fatal 为 0/0/0，changed-SV style 与 diff-check
通过。详见 `task-rdma-batch171-dependency-combination-snapshot-report.md`。

本批仍不关闭跨队列/跨线程并发、SRQ 全生命周期、SQD/SQE drain/flush、legacy descriptor、
外部 ordering/error、manager 外部调用窗口补偿和最终 ownership 审计；项目级计划继续保持
`active`。

## Batch172：CEQ/AEQ 共用解码与 malformed retry seam（已完成本批，计划仍 active）

本批把 `rdma_queue_data_engine.sv` 中 CEQE/AEQE 重复的 codec registry lookup、decode
以及 null-status 归一化收束到只读 `decode_event_image()` task。helper 只返回 detached
`rdma_hw_model` 与 `rdma_status`，不读写 runtime ledger、cursor、pending、Host-memory/MMIO
或外部资源；CEQ/AEQ caller 仍分别保留 owner、route、CQ-flush、pending、doorbell 和
consumer commit policy。malformed decode 在首次 mutation 前直接返回，之后由调用方在
修复 raw image 后显式 retry，禁止把 codec error 当成 route miss ack。

`rdma_queue_event_route_consume_test` 新增 CEQ/AEQ reserved-bit hostile fixture：第一次
poll 必须返回 `RDMA_SC_CODEC_ERROR` 且 CI/occupancy/pending/MMIO 不变；恢复原始 16-byte
image 后第二次 poll 才能返回 detached event，并恰好增加一次 consumer doorbell、清空
occupancy。最终源码边界 focused VCS53 PROCESS/LOGICAL PASS，UVM warning/error/fatal 为
0/0/0；changed-SV style 与 `git diff --check` 通过。详见
`task-rdma-batch172-event-decode-retry-report.md`。

本批仍不关闭跨队列/跨线程并发、SRQ 全生命周期、SQD/SQE drain/flush、legacy descriptor、
外部 ordering/error、manager 外部调用窗口补偿、完整 parent/core 回归和最终 ownership
审计；计划继续保持 `active`。

## Batch173：CEQ/AEQ consumer doorbell recovery exactly-once（已完成本批，计划仍 active）

本批补齐 Batch172 之后仍开放的 event consumer doorbell recovery 组合证据。测试新增
`check_event_doorbell_failure_recovery()`，在真实 CEQ/AEQ topology 上通过既有
`rdma_queue_data_engine_ordering_fault` seam 注入一次确定性 `NO_SUBMIT` doorbell failure，
验证首次 poll 保留完整 pending、未经 caller confirmation 的 retry 返回
`RDMA_SC_INVALID_ARGUMENT`，确认后的 `recover_queue()` 只重放同一 doorbell 并完成 CI/
occupancy commit，随后重复 retry 返回 `RDMA_SC_INVALID_STATE` 且不再产生 MMIO。CEQ/AEQ
各自的 route、result delivery 和 owner 仍留在 caller，测试不复制 runtime ledger、lock
或外部资源所有权。

`rdma_queue_event_route_consume_test` 在 VCS53 登录 bash 中 PROCESS/LOGICAL PASS，UVM
warning/error/fatal 为 0/0/0；changed-SV style 与 `git diff --check` 通过。详见
`task-rdma-batch173-event-doorbell-recovery-report.md`。

本批仍不关闭 AMBIGUOUS doorbell 的不可重放策略、跨队列/跨线程并发、SRQ 全生命周期、
SQD/SQE drain/flush、legacy descriptor、外部 ordering/error、manager 外部调用窗口补偿、
完整 parent/core/integration 汇总、Phase-1C F2 whole-plan canonical authority 和最终
ownership 审计；计划继续保持 `active`。

## Batch184：runtime lock contention characterization（已完成本批，计划仍 active）

本批只在 `rdma_queue_runtime_test.sv` 增加 test-only lock probe 和 fork 矩阵，证明生产
runtime 的唯一 semaphore 在另一线程持有期间让 `query_occupancy()` 返回
`RDMA_SC_RESOURCE_BUSY`，释放后查询恢复且 occupancy 不变。生产 runtime 未新增第二把锁、
账本或外部引用；详见 `task-rdma-batch184-runtime-lock-contention-report.md`。

该证据不关闭跨 queue/engine 全局并发审计、SRQ 全生命周期、SQD/SQE drain/flush、外部
ordering/error/backpressure、manager 外部调用窗口、Phase-1C F2 或最终 ownership 审计，
计划继续保持 `active`。

## Batch174：SQ/RQ canonical SGE authority seam（已完成本批，计划仍 active）

本批新增 `src/codec/rdma/rdma_sge_authority.sv`，把 SQ 非零 SGE 统计和 RQ typed
SGE 数量/总长度计算收束为只读 authority helper。`rdma_hw_sqe_model::derive_payload_authority()`
与 `rdma_hw_rqe_model::derive_typed_sge_authority()` 只消费 detached 数值结果；
null/保留位/数量/长度失败仍由原 model shape、width 和 provenance gate 保持原错误
优先级，helper 不访问 runtime、manager、Host-memory、PCIe 或外部 mapping。

`rdma_queue_codec_test` 新增合法零长度过滤、null 和 reserved-bit 原子失败断言；
VCS53 focused PROCESS/LOGICAL PASS，UVM warning/error/fatal 为 0/0/0，changed-SV
style 与 `git diff --check` 通过。详见 `task-rdma-batch174-sge-authority-report.md`。

本批仍不关闭 inline/SGE/atomic/UD/URC whole-plan authority 组合、跨队列/跨线程并发、
SRQ 全生命周期、SQD/SQE drain/flush、legacy descriptor、外部 ordering/error、manager
外部调用窗口补偿、完整 parent/core/integration 汇总和最终 ownership 审计；项目级计划
继续保持 `active`。

## Batch175：runtime MMIO evidence transition policy（已完成本批，计划仍 active）

本批在 `src/core/rdma_queue_runtime_transaction_models.sv` 新增无状态
`rdma_queue_mmio_transition_policy::decide()`，统一普通 status 与 noalloc scheduler
路径的 MMIO evidence 状态迁移表。`project_mmio_evidence_locked()` 和
`record_recovery_failure_noalloc()` 只调用该 detached decision；runtime 仍独占
lock、pending、retry confirmation、兼容 marker 和 failure-status 的可变发布。
原有 `NO_SUBMIT` confirmation、`SUCCESS` exactly-once、device `NOT_APPLICABLE` 前置
写入和 consumer `AMBIGUOUS` 不可重放语义均保持不变。

`rdma_queue_runtime_test` 在 53 机当前源码边界 PROCESS/LOGICAL PASS，UVM
warning/error/fatal 为 0/0/0；changed-SV style 与 `git diff --check` 通过。详见
`task-rdma-batch175-mmio-transition-policy-report.md`。

本批仍不关闭 AMBIGUOUS 的全方向组合、跨队列/跨线程并发、SRQ 全生命周期、SQD/SQE
drain/flush、legacy descriptor、外部 ordering/error、manager 外部调用窗口补偿、
完整 parent/core/integration 汇总和最终 ownership 审计；项目级计划继续保持 `active`。

## Batch176：recovery failure-status publication helper（已完成本批，计划仍 active）

本批在 `rdma_queue_runtime.sv` 新增锁内 `copy_recovery_failure_status_locked()`，统一
普通与 noalloc recovery 入口复制 backend failure status 的字段集合。两个 caller 仍
分别保留 lock、MMIO evidence admission、status-slot 和 gate 语义；helper 不创建对象、
不接管外部资源，也不修改 confirmation/cursor。`rdma_queue_runtime_test` 在 VCS53
PROCESS/LOGICAL PASS，UVM warning/error/fatal 为 0/0/0；changed-SV style 与
`git diff --check` 通过。详见 `task-rdma-batch176-recovery-failure-status-report.md`。

本批仍不关闭 SRQ lifecycle、跨队列/跨线程并发、SQD/SQE drain/flush、legacy descriptor、
外部 ordering/error、manager 调用窗口、AMBIGUOUS 全方向组合、完整 parent/core/
integration regression 和最终 ownership 审计；计划继续保持 `active`。

## Batch200：resource allocator pure-value policy

本批新增 `rdma_resource_allocator_policy`，将 allocator 使用的 kind 合法集合与硬件
local-ID 宽度映射从 manager 中提取为无状态纯值函数；manager 仅保留兼容转发 wrapper，
继续独占 free-list、serial、binding、registry 和 publication epoch。测试覆盖各资源宽度、
不可分配 kind fallback 与未知枚举 fail-closed。该批不改变业务顺序，项目计划继续保持
`active`，剩余并发、SRQ 组合生命周期、legacy descriptor、外部 ordering/error/backpressure、
Phase-1C F2 whole-plan 和最终 ownership 审计仍需后续批次处理。

## Batch201：SRQ preflight pure-value policy

本批把 SRQ create preflight 中不依赖 manager 或外部 adapter 的值判定迁移到
`rdma_srq_preflight_value_policy`：`requires_sgb()` 统一 SGB 阈值，`validate_limits()`
统一 Function capability/encoded limit 边界，`validate_borrowed_backing()` 统一
SRQ_RING/SRFQ_RING/SRQ_SGB 角色合法性和 required-role cardinality。生命周期 policy
继续唯一协调 request/Function authority、PD dependency、backing clone、ring planner 和
preflight publication；新 policy 不拥有 queue/resource ledger、lock、mapping 或外部
对象生命周期。错误码、诊断文本和检查顺序保持不变。

`rdma_queue_lifecycle_test` 的纯值矩阵及公开 SRQ preflight 场景在 VCS53 PROCESS/LOGICAL
PASS，UVM warning/error/fatal 为 `0/0/0`；dpu_common integration focused 同样通过，
Python `293/293`、style、queue/profile/Phase-1A 和 diff 门禁通过。报告见
`task-rdma-batch201-srq-preflight-value-policy-report.md`。SRQ 完整组合生命周期、并发、
legacy descriptor、外部 ordering/error/backpressure、Phase-1C F2 和最终 ownership 审计
仍保持 OPEN，计划继续 `active`。

## Batch202：borrowed ring single-role policy

本批把 CQ/CEQ/AEQ borrowed backing 的单一 ring-role admission 提取为
`src/core/rdma_queue_borrowed_role_policy.sv`。policy 只处理 detached spec 的 null、
空集合、null slice 和 role 一致性；lifecycle policy 继续拥有 Function/PD/vector
authority、ring geometry、backing clone、CMQ 和 publication。重复的
`backing_role_count()` 已删除，focused VCS53、dpu_common integration、Python、style、
queue/profile/Phase-1A 与 diff 门禁均通过。

本批仍不关闭 allocator/registry 跨线程或跨进程互斥、manager 外部调用窗口、SRQ 全
生命周期、跨 queue/engine 全局原子性、SQD/SQE drain/flush、legacy descriptor、外部
ordering/error/backpressure、Phase-1C F2 whole-plan 或最终 ownership 审计；项目计划
继续保持 `active`。详见 `task-rdma-batch202-borrowed-role-policy-report.md`。

## Batch203：queue role cardinality policy

本批将 resource manager 中 flush target 与 backing ref 的重复 role 扫描下沉到
`src/core/rdma_queue_role_cardinality_policy.sv`。policy 只消费 detached plan，保留
缺失/重复 role 的 count/index 语义；manager 继续唯一拥有 progress snapshot、recovery
authority、registry/allocator mutation 和 commit 顺序。focused resource-manager VCS53、
Python、style、queue/profile/Phase-1A 与 diff 门禁均通过。

随后 core regression 达到 `97/97 PROCESS`、`80/80 LOGICAL`，dpu_common integration
regression 达到 `10/10` pristine，所有 UVM warning/error/fatal 均为 `0/0/0`。

本批不关闭 allocator/registry 跨线程或跨进程互斥、manager 外部调用窗口、SRQ 全生命
周期、跨 queue/engine 全局原子性、SQD/SQE drain/flush、legacy descriptor、外部
ordering/error/backpressure、Phase-1C F2 whole-plan 或最终 ownership 审计；项目计划
继续保持 `active`。详见 `task-rdma-batch203-role-cardinality-policy-report.md`。

## Batch204：publication mutation guard

本批在 resource manager 的三个 detached final commit seam 上增加同一把
`mutation_guard`，仅保护无外部调用的 registry/recovery/epoch 写入窗口；projection、
allocator reservation、recovery admission 和外部对象生命周期保持原 owner。忙时
`RDMA_SC_RESOURCE_BUSY` fail-closed，测试验证 candidate/账本原子不变。resource-manager
focused、core `97/97 PROCESS` + `80/80 LOGICAL`、dpu_common integration `10/10`、Python
和静态门禁均通过。

本批不关闭完整 registry/allocator 跨线程/跨进程互斥、SRQ 全生命周期、跨 queue/engine
全局原子性、SQD/SQE drain/flush、legacy descriptor、外部 ordering/error/backpressure、
Phase-1C F2 whole-plan 或最终 ownership 审计；项目计划继续保持 `active`。详见
`task-rdma-batch204-publication-mutation-guard-report.md`。

## Batch205：queue destroy flush transaction seam（本批完成，计划仍 active）

本批继续推进 Phase D 的最小迁移边界，处理 queue lifecycle executor 内最明显的重复
事务骨架。`destroy_locked()` 原先分别在 delete-before-flush 与 flush-before-delete 两条
分支中重复构造 flush descriptor、调用一次 legacy CMQ、执行 live binding fence、分类
AMBIGUOUS，并把 role progress 写回 resource manager。新增受保护 task
`execute_destroy_flush_step()` 后，两条分支只保留顺序控制和 caller-owned 的
`ambiguous_op`、`hardware_absent`、completed-step、cleanup/finalize/recovery 决策。

新 task 只接收已经通过 recipe/cardinality 校验的 detached `rdma_queue_flush_target` 和
queue handle，不保存 plan、registry、recovery ledger、锁或外部 backing；completion status
失败但 execute status 仍为 OK 的历史语义也原样保留。SRQ 的 pre-delete flush、CQ/CEQ/AEQ
的 post-delete flush、CMQ ticket/completion 和 manager progress ownership 没有移动。

VCS53 `rdma_queue_lifecycle_test` PROCESS/LOGICAL PASS，UVM warning/error/fatal 为
`0/0/0`；changed-SV style、queue lifecycle checker 和 `git diff --check` 通过。详见
`task-rdma-batch205-destroy-flush-transaction-seam-report.md`。

本批只关闭 queue destroy OCC flush 的重复事务 seam，不关闭 SRQ 完整
create/post/recovery/destroy 组合、allocator/registry 并发、跨 queue/engine 全局原子性、
SQD/SQE drain/flush、legacy descriptor、PCIe ordering/error/backpressure、manager 外部
调用窗口、Phase-1C F2 whole-plan 或最终 ownership 审计；项目级计划继续保持 `active`。

## Batch206：queue recovery OCC flush transaction seam（本批完成，计划仍 active）

本批继续推进 Phase D 的最小迁移边界，收束 `recover_locked()` 中 SRQ pre-delete barrier
和 post-delete retry 的重复事务骨架。新增受保护 task `execute_recovery_flush_step()`，
统一 detached target 的 descriptor 构造、单次 `execute_queue_command()`、generation fence
和 `manager.record_queue_flush_complete()`；task 额外返回 `execute_failed` 与
`progress_failed`，使 caller 能继续区分 descriptor、CMQ/fence 和 manager progress 的
历史诊断路径。

`recover_locked()` 仍独占 ambiguous ticket/role、hardware presence、
`queue_plan.flush_complete`、`recovery_complete_step()`、持久化和下一状态机阶段；helper
不读取或复制 recovery/registry ledger，不改变 target 的 completion 标志。pre-delete
和 post-delete 两条循环的 retry 顺序、错误文案、`RDMA_QUEUE_AMBIG_OCC_FLUSH` 证据及
SRQ barrier 语义保持不变。

VCS53 `rdma_queue_lifecycle_test` 与 `rdma_queue_recovery_test` 均 PROCESS/LOGICAL PASS，
UVM warning/error/fatal 为 `0/0/0`；changed-SV style、queue lifecycle checker 和
`git diff --check` 通过。详见 `task-rdma-batch206-recovery-flush-transaction-seam-report.md`。

本批只关闭 queue recovery OCC flush 的重复事务 seam，不关闭 SRQ 完整
create/post/recovery/destroy 组合、allocator/registry 并发、跨 queue/engine 全局原子性、
SQD/SQE drain/flush、legacy descriptor、PCIe ordering/error/backpressure、manager 外部
调用窗口、Phase-1C F2 whole-plan 或最终 ownership 审计；项目级计划继续保持 `active`。

## Batch207：queue cleanup recipe policy（本批完成，计划仍 active）

本批把 `destroy_locked()` 内联的 cleanup recipe cardinality、context 一致性和 reverse
release 顺序校验提取为无状态 `rdma_queue_cleanup_recipe_policy::validate()`。policy 只
读取 detached `rdma_queue_backing_plan` 和 lifecycle policy 输出的 role/phase 队列，保留
原有 `RDMA_SC_INVALID_STATE` 文案；SRQ 的 `SRQ_SGB` 缺失例外和非 SRQ role 的严格唯一
约束均显式保留。

`destroy_locked()` 继续拥有 quiesce、CMQ flush/delete、local cleanup、manager finalize
和 recovery 账本写入，只在首次外部副作用前调用一次 policy admission。生命周期测试新增
canonical CQ plan 与 duplicate-role hostile 矩阵，证明 policy 成功和拒绝路径不会把
detached recipe 当成可变 owner。

VCS53 `rdma_queue_lifecycle_test` PROCESS/LOGICAL PASS，UVM warning/error/fatal 为
`0/0/0`；changed-SV style、queue lifecycle checker 和 `git diff --check` 通过。详见
`task-rdma-batch207-cleanup-recipe-policy-report.md`。

本批只收束 cleanup recipe 纯值 admission，不关闭 SRQ 完整 create/post/recovery/destroy
组合、allocator/registry 并发、跨 queue/engine 全局原子性、SQD/SQE drain/flush、legacy
descriptor、PCIe ordering/error/backpressure、manager 外部调用窗口、Phase-1C F2
whole-plan 或最终 ownership 审计；项目级计划继续保持 `active`。

## Batch208：CQ shadow replay authority policy（本批完成，计划仍 active）

本批明确 CQ shared-shadow replay 的 authority 与 canonical payload 边界。新增无状态
`rdma_cq_shadow_replay_policy::validate()`，统一 caller snapshot 与 cached snapshot 的
CQ kind、Function UID、generation、reset epoch 和 object ID 校验；caller mismatch 保持
`RDMA_SC_STALE_GENERATION`，cache integrity mismatch 由显式参数映射为
`RDMA_SC_INVALID_STATE`。

`rdma_cq_engine::flush_shadow()` 只把两个重复 identity gate 委托给 policy，facade 仍是
canonical `flushed_shadow`、URC evidence、flush count、detached replay clone 和 exactly-once
状态的唯一 owner。replay 继续忽略 caller 的 CI/arm/sequence 并回填 canonical cache，未
引入第二份 shadow ledger 或外部生命周期。

VCS53 `rdma_cq_shadow_flush_test`、`rdma_cq_engine_test`、`rdma_cq_engine_resize_test` 均
PROCESS/LOGICAL PASS，UVM warning/error/fatal 为 `0/0/0`；changed-SV style、queue lifecycle
checker 和 `git diff --check` 通过。详见 `task-rdma-batch208-cq-shadow-replay-policy-report.md`。

本批只收束 CQ shadow replay authority 纯值门禁，不关闭跨 queue/engine 并发、SRQ 完整
lifecycle、legacy descriptor、PCIe ordering/error/backpressure、manager 外部调用窗口、
Phase-1C F2 whole-plan 或最终 ownership 审计；项目级计划继续保持 `active`。

## Batch209：resource manager schema detached commit 原子性（本批完成，计划仍 active）

本批修正 `rdma_resource_manager` 三个 schema 复审入口的写回粒度。旧实现边遍历边把
`project_resource_value()`/`project_recovery_value()` 的结果写回 registry 或
recovery_records，后续 carrier 投影失败时可能留下部分 schema mutation。现在三个入口
均先建立 detached 全量/单条 candidate，再在外部 clone/factory 完成后获取
`mutation_guard`，检查 `publication_epoch` 与原对象引用，最后一次性提交；guard 不跨越
外部 callback，避免反向重入死锁。未知 recovery key 的幂等成功语义保持不变。

`rdma_resource_manager_test` 新增 PD-key/MR-carrier hostile fixture：后项投影失败时，前项
registry 指针保持不变，并验证未知 recovery key 仍返回 `RDMA_SC_OK`。VCS53 focused
PROCESS/LOGICAL PASS，UVM warning/error/fatal 为 `0/0/0`；Python 293/293、changed-SV
style、queue/profile/Phase-1A 与 diff gate 通过。详见
`task-rdma-batch209-schema-commit-atomicity-report.md`。

本批只关闭 schema 复审的部分写回窗口，不关闭 allocator/registry 跨线程或跨进程完整
互斥、manager 更广泛外部调用窗口、SRQ 全生命周期、跨 queue/engine 原子性、SQD/SQE
drain/flush、legacy descriptor、PCIe ordering/error/backpressure、Phase-1C F2 whole-plan
或最终 ownership 审计；项目级计划继续保持 `active`。

## Batch210：resource manager registry replacement commit guard（本批完成，计划仍 active）

本批新增 `commit_registry_replacement()`，把 stage/program/activate、CQ resize、CQ
replacement、CQ/QP programming attach 以及 QP semantic-only commit 的最终 registry 写回
统一到短 mutation-guard 窗口。helper 在写回前重新确认 key/handle identity 和 candidate
validation，只按单向参数更新 `staged_allocations`，成功后推进 `publication_epoch`；外部
projection 和 adapter/factory callback 完全在 guard 外执行。QP recovery 的 registry+
recovery 双账本事务继续保留专用路径。

`rdma_resource_manager_test` 在 VCS53 PROCESS/LOGICAL PASS，UVM warning/error/fatal
为 `0/0/0`；随后重新执行 core regression，97/97 PROCESS、全部 LOGICAL PASS，及锁定
dpu_common 快照上的 10/10 integration tests 均保持 UVM pristine。详见
`task-rdma-batch210-registry-commit-guard-report.md`。

本批只统一部分 registry replacement commit seam，不关闭 allocator/registry 跨线程或
跨进程完整互斥、manager 其它外部调用窗口、SRQ 全生命周期组合、跨 queue/engine 原子性、
SQD/SQE drain/flush、legacy descriptor、PCIe ordering/error/backpressure、Phase-1C F2
whole-plan 或最终 ownership 审计；项目级计划继续保持 `active`。

## Batch211：queue progress 双账本 OCC 提交（本批完成，计划仍 active）

本批继续收束 `rdma_resource_manager` 的 queue flush/cleanup/context recovery 路径。新增的
`rdma_queue_progress_candidate` 保存 snapshot 时的 `manager_epoch`、registry source 和
可选 recovery source（均为非拥有引用）；`queue_progress_snapshots()` 在任何 detached
projection 前冻结这些证据，`commit_queue_progress()` 在唯一 mutation guard 窗口内重新检查
epoch、registry/recovery 原始引用及两份快照的完整校验，随后同步写回两本账并推进
`publication_epoch`。因此外部 clone/factory 或并发事务完成后，旧 candidate 只能
fail-closed，不能把半新/半旧的 queue progress 覆盖回 manager。

同步更新 candidate 的构造/clear 流程和 shape 断言，未改变 flush role cardinality、cleanup
顺序、SRQ SGB 前置或 context completion authority。`rdma_resource_manager_test` 在 VCS53
PROCESS/LOGICAL PASS，UVM warning/error/fatal 为 `0/0/0`；changed-SV style、Python
contract tests 与 `git diff --check` 通过。详见
`task-rdma-batch211-queue-progress-occ-report.md`。

QP recovery 双账本的独立 progress helper、allocator/registry 跨线程或跨进程完整互斥、manager
其它外部调用窗口、SRQ 全生命周期、SQD/SQE drain/flush、legacy descriptor、PCIe
ordering/error/backpressure、Phase-1C F2 whole-plan 与最终 ownership 审计仍保持 OPEN。

## Batch212：QP recovery progress OCC 提交（本批完成，计划仍 active）

本批将 QP 专用 `qp_progress_snapshots()`/`commit_qp_progress()` 与 Batch211 的 queue
progress 提交边界对齐。snapshot 阶段现在同时冻结 `publication_epoch`、registry source
和 ERROR recovery source；commit 阶段在 mutation guard 内先复核 epoch/两份 source 引用，
再验证 detached QP/recovery 快照，最后同步发布两本账并推进 epoch。flush、owned-backing
cleanup 和 context cleanup 三个业务入口只传递这组证据，原有 predecessor、completion
authority、ambiguity 和 role 顺序保持不变。

验证：VCS53 `rdma_resource_manager_test` 与 `rdma_qp_lifecycle_test` 均 PROCESS/LOGICAL
PASS，UVM warning/error/fatal `0/0/0`；Batch211 core 97/97 PROCESS、80/80 LOGICAL 与
integration 10/10 已通过，Batch212 修改后 focused 两项仍 pristine；报告见
`task-rdma-batch212-qp-progress-occ-report.md`。

QP 其它恢复状态写回、allocator/registry 跨线程或跨进程完整互斥、manager 其它外部调用
窗口、SRQ 全生命周期、跨 queue/engine 原子性、SQD/SQE drain/flush、legacy descriptor、
PCIe ordering/error/backpressure、Phase-1C F2 whole-plan 与最终 ownership 审计仍保持 OPEN。

## Batch213：QP recovery metadata OCC helper（本批完成，计划仍 active）

本批新增 `commit_recovery_replacement()`，统一 recovery-only 的最终写回窗口。`update_qp_recovery_progress()`
和 `retain_qp_query_mapping()` 现在都在外部 projection 完成后携带原 recovery source 与
`publication_epoch`，由 helper 在 mutation guard 内执行 source/epoch/validate 三重检查，
成功后推进 epoch；projection、owned/recovery-only mapping clone 不持有 guard，原有 query
mapping authority、intent/QPC/opcode 和错误优先级保持不变。

VCS53 `rdma_qp_recovery_test` PROCESS/LOGICAL PASS，UVM warning/error/fatal `0/0/0`；
changed-SV style 与 `git diff --check` 通过。详见
`task-rdma-batch213-qp-recovery-metadata-occ-report.md`。

mark-error/programmed 的 registry+recovery 双写、allocator/registry 跨线程或跨进程完整互斥、
manager 其它外部调用窗口、SRQ 全生命周期、跨 queue/engine 原子性、SQD/SQE drain/flush、
legacy descriptor、PCIe ordering/error/backpressure、Phase-1C F2 whole-plan 与最终 ownership
审计仍保持 OPEN。

## Batch214：QP ERROR/programmed 双账本原子提交（本批完成，计划仍 active）

本批新增 `commit_resource_recovery_replacement()`，将 QP ERROR transition 和 programmed
reconciliation 的 registry/recovery/staged 写回统一到一个最终提交 seam。helper 在外部
projection 完成后复核 resource/recovery source、epoch、handle identity 与两份 validate，
再在短 mutation guard 内同步安装/清除 recovery、清理 staged 标志并推进 epoch；
`mark_qp_error()` 与 `commit_qp_programmed()` 不再分别直接写两本账，ERROR 资源不会在
recovery record 尚未发布或已被旧 candidate 覆盖时对外可见。

VCS53 `rdma_resource_manager_test`、`rdma_qp_lifecycle_test`、`rdma_qp_recovery_test`
均 PROCESS/LOGICAL PASS，UVM warning/error/fatal `0/0/0`；changed-SV style 与
`git diff --check` 通过。详见 `task-rdma-batch214-qp-error-double-ledger-report.md`。

allocator/registry 跨线程或跨进程完整互斥、manager 其它外部调用窗口、SRQ 全生命周期、
跨 queue/engine 原子性、SQD/SQE drain/flush、legacy descriptor、PCIe ordering/error/
backpressure、Phase-1C F2 whole-plan 与最终 ownership 审计仍保持 OPEN。

## Batch215：outstanding ledger registry OCC 提交（本批完成，计划仍 active）

本批扩展 `commit_registry_replacement()` 的可选 snapshot/epoch 检查，并让
`track_outstanding()`、`retire_outstanding()` 在 detached ledger projection 后携带原 registry
source 与 `publication_epoch` 进入同一 mutation guard。旧 candidate、重复 ID、未知 ID 或
外部调用窗口中的 registry 替换均 fail-closed；成功路径继续只更新 outstanding ledger，
不改变 resource/backing 所有权或业务错误优先级。

`rdma_resource_manager_test` VCS53 PROCESS/LOGICAL PASS，UVM warning/error/fatal `0/0/0`；
changed-SV style 与 `git diff --check` 通过。详见
`task-rdma-batch215-outstanding-ledger-occ-report.md`。

其它 manager 外部写回、allocator/registry 跨线程或跨进程完整互斥、SRQ 全生命周期、跨
queue/engine 原子性、SQD/SQE drain/flush、legacy descriptor、PCIe ordering/error/backpressure、
Phase-1C F2 whole-plan 与最终 ownership 审计仍保持 OPEN。

## Batch216：recovery clear OCC 提交（本批完成，计划仍 active）

本批新增 `clear_recovery_record()`，把 `clear_recovery()` 的最终删除从直接
`recovery_records.delete()` 改为 source/epoch 复核后的短 guard 提交；未知 key 继续幂等
成功，硬件 absence/release completion 的既有前置检查不变。恢复记录不会因旧句柄或并发
progress/restore 在新 epoch 上被误删，成功删除后推进 `publication_epoch`。

`rdma_resource_manager_test` VCS53 PROCESS/LOGICAL PASS，UVM warning/error/fatal `0/0/0`；
changed-SV style 与 `git diff --check` 通过。详见
`task-rdma-batch216-recovery-clear-occ-report.md`。

其它 manager 外部写回、allocator/registry 跨线程或跨进程完整互斥、SRQ 全生命周期、跨
queue/engine 原子性、SQD/SQE drain/flush、legacy descriptor、PCIe ordering/error/backpressure、
Phase-1C F2 whole-plan 与最终 ownership 审计仍保持 OPEN。

## Batch197：legacy CMQ raw dispatch 公共边界（本批完成，计划仍 active）

本批新增 `rdma_cmq_dispatch_legacy_raw()`，把控制面、queue lifecycle executor 和 QP
lifecycle executor 重复的输出清零、`cmq/command` 门禁与一次 `cmq.execute()` 收束为
一个无状态 core 适配层。helper 只负责 raw dispatch，不归一化 null status、不检查
completion、不执行 generation fence，也不分类 timeout/ambiguity；各业务 owner 的
错误优先级、恢复判定、提交顺序和资源所有权保持原实现。队列原有合并 guard 仍返回
`RDMA_SC_INVALID_ARGUMENT`，控制面/QP 的 `INVALID_STATE`/`INVALID_ARGUMENT` 文案由
caller 继续传入，避免改变可观察 ABI。

`rdma_control_plane_test` 在 VCS53 登录 bash 中 PROCESS/LOGICAL PASS，UVM
warning/error/fatal 为 `0/0/0`；changed-SV style 与 `git diff --check` 通过。详见
`task-rdma-batch197-legacy-dispatch-seam-report.md`。

本批只关闭 raw dispatch 样板重复，不关闭 legacy descriptor wire 分支、跨
queue/engine 并发、SRQ 全生命周期、SQD/SQE drain/flush、外部 ordering/error/backpressure、
manager 外部调用窗口、Phase-1C F2 whole-plan 或最终 ownership 审计；项目计划继续保持
`active`。

### Batch198 当前更新（2026-09-25）

- 新增 `src/core/rdma_cmq_ambiguity_policy.sv`，以无状态
  `rdma_cmq_ambiguity_policy::is_ambiguous()` 统一 timeout/reset、null status、缺失
  ticket/completion 和 no-submit 证明的 evidence 分类；queue/QP executor 的 caller
  wrapper 保持不变。
- queue 与 QP 的历史差异显式参数化：queue 继续允许 completion 壳配合 no-submit
  证明，QP 继续要求 completion 也为空；QP 的无 ticket/completion 纯成功保持确定，
  queue 保守地继续判为 ambiguous。新增 CMQ models 测试覆盖 null/timeout/complete/
  shell/no-submit 矩阵。
- `rdma_cmq_engine_models_test` 在 VCS53 PROCESS/LOGICAL PASS，UVM
  warning/error/fatal 为 `0/0/0`；Python 293/293、changed-SV style 和 diff gate
  均 PASS。详见 `task-rdma-batch198-cmq-ambiguity-policy-report.md`。
- 本批只收束 ambiguity 纯值分类，不关闭 registry/allocator 并发、SRQ 全生命周期、
  跨 queue/engine 并发、SQD/SQE drain/flush、legacy descriptor、外部
  ordering/error/backpressure、manager 调用窗口、Phase-1C F2 whole-plan 或最终
  ownership 审计；计划继续保持 `active`。

### Batch199 当前更新（2026-09-25）

- `rdma_resource_publication_candidate::manager_epoch` 改为在第一次外部 clone/factory
  projection 前捕获；`stage_resource_publication()` 完成 registry/published/owner/handle
  四类 detached projection 后检查 epoch，发现 manager 在 projection 窗口重入 mutation
  时清除 candidate 并返回 `RDMA_SC_INVALID_STATE`。
- 普通 `rdma_resource_identity_candidate` 与 Function identity candidate 同样保存 reserve
  完成后的 manager epoch；`publish_identity_candidate()`/`create_function()` 在构造
  authoritative resource 的窗口返回后拒绝 stale reservation，并先回滚 allocator/binding
  reservation。
- Function 路径通过 `publish_function_identity_candidate()` 统一 freshness、authoritative
  完整性、registry publication 和失败回滚，`create_function()` 只保留专用 generation/
  tombstone projection，不复制第二份 publication 骨架。
- `commit_resource_publication()` 保留 stage→commit stale epoch、canonical identity/key
  与 duplicate incarnation gate；manager 仍是 registry、incarnation owner/handle 和
  known-generation ledger 的唯一 owner。测试 probe 新增 epoch observation 与
  reserve→mutation→publish rollback，并保留 concurrent create、hostile key/owner、duplicate
  commit 矩阵。
- resource-manager、control-plane、QP-lifecycle、queue-lifecycle focused VCS53 均
  PROCESS/LOGICAL PASS，UVM warning/error/fatal 为 `0/0/0`；Python 293/293、changed-SV
  style、diff、queue/profile/Phase-1A 门禁通过。详见
  `task-rdma-batch199-publication-epoch-gate-report.md`。
- 本批只关闭 publication projection epoch consistency seam，不关闭 allocator/registry
  跨线程或跨进程互斥、manager 更广泛外部调用窗口补偿、SRQ 全生命周期、跨 queue/engine
  并发、SQD/SQE drain/flush、legacy descriptor、外部 ordering/error/backpressure、
  Phase-1C F2 whole-plan 或最终 ownership 审计；计划继续保持 `active`。

## Batch194：publication candidate identity integrity（已完成本批，计划仍 active）

本批继续推进 Phase C 的 publication seam。`rdma_resource_publication_candidate::valid()`
现在会按 manager canonical key 格式重算 registry/incarnation/generation key，并同时
核对 owner/handle kind、registry/published snapshot 的 owner/handle identity；detached
candidate 的 key 非空不再被视为足够的 authority。`commit_resource_publication()` 在写入
四份 manager-owned 账本前拒绝已存在的 registry/incarnation key，避免 stage→commit 间
的旧 candidate 覆盖同一 incarnation。

`rdma_resource_manager_test` 新增 hostile key、hostile owner 和重复 stage/commit 矩阵；
当前 resource-manager focused VCS53 PROCESS/LOGICAL PASS，UVM warning/error/fatal 为
0/0/0；Python 293/293、changed-SV style 与 `git diff --check` 通过。详见
`task-rdma-batch194-publication-candidate-integrity-report.md`。

本批仍不关闭跨线程/跨进程互斥、allocator/registry 全局并发、SRQ 全生命周期、legacy
descriptor、外部 ordering/error/backpressure、manager 外部调用窗口、Phase-1C F2
whole-plan 或最终 ownership 审计；计划继续保持 `active`。

## Batch192：resource identity publish transaction seam（已完成本批，计划仍 active）

本批继续推进 Phase C，将普通资源 `create_pd/create_mr/create_cq/create_qp/create_srq/
create_cmq/create_ceq/create_aeq` 重复的 candidate publication 尾段收束为受保护
`publish_identity_candidate()`：先校验 detached identity 与 authoritative resource，再
调用 `register_resource()`；null/失败统一执行 `rollback_identity_candidate()`，成功后清除
candidate。各 caller 继续保留字段投影、依赖 admission、output cast、QP sequence 更新与
既有错误优先级；`create_function()` 不复用该 helper，继续使用独立的 generation/tombstone
candidate。

该 helper 不拥有 registry、allocator、binding registration、lock 或外部 adapter；manager
仍是所有 mutable publication 的唯一 owner。`rdma_resource_manager_test`、
`rdma_queue_lifecycle_test`、`rdma_qp_lifecycle_test` 和 `rdma_control_plane_test` 在
VCS53 登录 bash 中均 PROCESS/LOGICAL PASS，UVM warning/error/fatal 为 `0/0/0`；Python
293/293、changed-SV style 与 `git diff --check` 通过。详见
`task-rdma-batch192-resource-publish-seam-report.md`。

本批只关闭普通 resource publication 的重复事务 seam，不关闭 allocator/registry 跨线程
并发、跨 incarnation destroy dependency、SRQ 全生命周期、SQD/SQE drain/flush、legacy
descriptor、外部 ordering/error/backpressure、manager 外部调用窗口、Phase-1C F2
whole-plan 或最终 ownership 审计；项目级计划继续保持 `active`。

## Batch193：resource publication stage/commit seam（已完成本批，计划仍 active）

本批继续推进 Phase C，将 `register_resource()` 的外部 projection 与 manager-owned
publication mutation 分离。新增 `rdma_resource_publication_candidate`，由
`stage_resource_publication()` 一次完成 registry/published/owner/handle 的 detached
projection 和稳定 key 生成；`commit_resource_publication()` 只校验 candidate 并写入
registry、incarnation owner/handle 与 known generation，不再调用 factory/clone。既有
`register_resource()` 继续作为兼容入口执行 stage→commit 并返回 detached published 快照，
`create_function()` 及普通 create caller 的错误优先级、rollback、lookup 和所有权不变。

`rdma_resource_manager_test` 增加 null stage、stage 无副作用、commit 后 lookup、clear 后
二次 commit 拒绝的矩阵；resource-manager、queue lifecycle、QP lifecycle、control-plane
四项在 VCS53 登录 bash 中均 PROCESS/LOGICAL PASS，UVM warning/error/fatal 为 `0/0/0`。
Python 293/293、changed-SV style、`git diff --check` 和中文契约 scanner 同样通过。详见
`task-rdma-batch193-resource-publication-stage-commit-report.md`。

本批只关闭 projection 与 publication mutation 的结构窗口，不关闭 allocator/registry
跨线程并发、跨 incarnation destroy dependency、SRQ 全生命周期、SQD/SQE drain/flush、
legacy descriptor、外部 ordering/error/backpressure、Phase-1C F2 whole-plan 或最终
ownership 审计；项目计划继续保持 `active`。

## Batch184：runtime lock contention characterization（已完成本批，计划仍 active）

本批只在 `rdma_queue_runtime_test.sv` 增加 test-only lock probe 和 fork contention case，
证明生产 runtime 的唯一 semaphore 在另一个线程持锁时让 `query_occupancy()` 返回
`RDMA_SC_RESOURCE_BUSY`，释放后查询恢复且 occupancy 不变；生产 runtime 未新增第二把锁、
账本或外部引用。该 characterization 不等于跨 queue/engine 的全局并发审计。

## Batch185：reset tokenless admission policy（已完成本批，计划仍 active）

本批将 `rdma_reset_coordinator::authorize_tokenless_dataplane()` 的同步 reset admission
判定提取为无状态 `rdma_reset_tokenless_admission_policy::evaluate()`。policy 只消费
publication-active、transaction-active、cleanup 意图和 operation name，返回 detached
status；coordinator 仍唯一读取 guard/transaction 标志，并保留 Function/Host/Device epoch、
owner/token、router binding、外部 manager 调用和 cleanup 语义。新增测试覆盖 idle、单一
active、combined active 与 cleanup override 五种组合，详见
`task-rdma-batch185-reset-tokenless-admission-policy-report.md`。

本批只收束同步 tokenless dataplane admission 的重复条件，不关闭跨线程/跨进程全局锁、
跨 queue/engine 并发、SRQ 生命周期、SQD/SQE drain/flush、legacy descriptor、外部
ordering/error/backpressure、manager 外部调用窗口补偿、Phase-1C F2 或最终 ownership
审计。

## Batch186：adapter status normalization policy（已完成本批，计划仍 active）

本批新增 `src/adapter/rdma_adapter_status_policy.sv`，把 Host-memory API 与 concrete
Host-memory adapter 重复的 null-status fail-closed 构造收束为无状态
`rdma_adapter_status_policy::normalize()`。base API 与 concrete wrapper 只提供组件前缀
和 operation 标签；非空 backend status 原样保留，null 统一为 `RDMA_SC_INVALID_STATE`，
不读取或复制 mapping、ledger、cursor、外部 backing 或 adapter ownership。adapter contract
unit test 增加 null 与 non-null identity matrix，host-memory integration test 的既有
diagnostic expectation 保持不变。

本批不改变 Host-memory/PCIe/network 外部资源生命周期、I/O 顺序、backpressure 或错误
映射；SRQ lifecycle、全局并发、manager 调用窗口、Phase-1C F2 和最终 ownership 审计仍
由后续批次负责。

## Batch187：SRQ destroy detached value policy（已完成本批，计划仍 active）

本批将 SRQ destroy/recovery 所需的纯值顺序提取为
`rdma_srq_destroy_value_policy()`：硬件 OCC flush 固定为 `SRFQ_PD → SRQ_PD` 的
PRE_DELETE recipe，本地释放固定为 `SRFQ_PD → SRQ_PD → 可选 SRQ_SGB → SRFQ_RING →
SRQ_RING`，并由 `include_optional_sgb` 描述 `max_sge<=2` 的无 SGB 变体。
`rdma_srq_lifecycle_policy` 只投影该 recipe，manager、QP dependency guard、CMQ
completion、borrowed backing 和 release owner 均保持原实现。`rdma_queue_lifecycle_test`
补充 canonical/no-SGB 一致性矩阵，focused VCS PROCESS/LOGICAL PASS 且 UVM 0/0/0。

本批只收束 SRQ destroy 的值规则，不关闭 shared-QP recovery 的更广组合、跨 queue/engine
并发、SQD/SQE drain/flush、外部 ordering/error/backpressure、Phase-1C F2 或最终
ownership 审计。详见 `task-cmq-batch187-srq-destroy-value-policy-report.md`。

## Batch188：URC QP backing typed factory（已完成本批，计划仍 active）

本批新增 `src/core/rdma_qp_urc_backing_policy.sv`，将 URC RSQ/RDSQ/DSQ 的 role、长度和
顺序收束为无状态 typed factory。`materialize_plan()` 继续通过原
`allocate_ref()` 逐项提交，并在每次失败时保留已经产生的引用供既有 partial-plan
rollback；factory 不读取或复制 manager、mapping、Host-memory、QP plan 或 recovery
账本。`rdma_qp_lifecycle_test` 新增 RC/UD/URC policy matrix，QP focused VCS
PROCESS/LOGICAL PASS，UVM 0/0/0。

本批只收束 URC backing 几何和执行器重复分支，不关闭 SQD/SQE drain/flush、跨 queue/engine
全局并发、legacy descriptor、外部 ordering/error/backpressure、Phase-1C F2 或最终
ownership 审计。详见 `task-rdma-batch188-urc-backing-factory-report.md`。

## Batch189：QP transition capability gate 收束（已完成本批，计划仍 active）

本批删除 `rdma_qp_lifecycle_executor::modify_locked()` 中与
`rdma_qp_transition_decide()` 重复的 SQD/SQE 条件判断：executor 先缓存 policy decision，
在 transport-specific request 校验前只消费其 unsupported capability 结果，以保持既有
错误优先级；后续直接复用 decision 完成 semantic-only/full-modify/invalid 映射。QP
outstanding、QPC staging、CMQ、generation fence 与 resource commit owner 没有移动。

QP lifecycle focused VCS PROCESS/LOGICAL PASS，UVM 0/0/0；详见
`task-rdma-batch189-qp-transition-gate-report.md`。本批不实现 SQD/SQE drain/flush，项目
计划继续保持 `active`。

## Batch190：SQ SGE canonical authority whole-plan（本批完成，计划仍 active）

本批继续推进 Phase-1C F2 的安全子边界：新增
`rdma_sge_authority::derive_send()`，统一 RC/UD SQ codec 与 SQ-SGB writer 对有效 SGE
数量和 payload 总长度的纯值计算。helper 过滤零长度项，拒绝 null、保留 bit31、超过
32 项或超过 2GiB，并在失败时保持 detached output 为零；它不保存输入引用、不创建
第二份 ledger，也不拥有 SGB/Host-memory。

RC `body_and_header()`、UD `encode_fields()` 和 queue-data
`write_sgb_and_verify()` 现在共享同一 authority，原有 mode/effective-mode、
`total_payload_len`、descriptor 压紧、signature、IOVA 和首次 Host-memory write 前
门禁保持不变。新增 SQ authority 测试覆盖 zero-length、2GiB sentinel、null 和
reserved bit31。focused VCS53 PROCESS/LOGICAL PASS，UVM warning/error/fatal 为 0/0/0；
Python 293/293、changed-SV style、diff、queue/profile/Phase-1A gates 通过。详见
`task-rdma-batch190-sge-authority-whole-plan-report.md`。

本批仍不实现 SQD/SQE drain/flush；RQ raw/typed provenance、SRQ 全生命周期、跨
queue/engine 并发、legacy descriptor、外部 ordering/error/backpressure、manager 外部
调用窗口和最终 ownership 审计继续保持 OPEN，项目计划继续 `active`。

## Batch180：queue lifecycle opcode policy（已完成本批，计划仍 active）

本批把 queue lifecycle executor 中 CQ/SRQ/CEQ/AEQ 的 create/query/delete opcode 静态映射
提取到 `src/core/rdma_queue_lifecycle_opcode_policy.sv`。policy 只返回 detached
`bit[7:0]`，对 FUNCTION、PD、MR、QP、CMQ 和未知 kind fail-closed；executor 的兼容
wrapper、SRQ pre-delete flush、CQ post-delete flush、ambiguous recovery、authority
校验和 commit 顺序保持不变。

`rdma_queue_lifecycle_models_test` 新增四类合法映射和 unsupported kind 断言；该 focused
test 在 VCS53 登录 bash 中 PROCESS/LOGICAL PASS，UVM warning/error/fatal 为 0/0/0，
changed-SV style 与 `git diff --check` 通过。详见
`task-rdma-batch180-lifecycle-opcode-policy-report.md`。

本批仍不关闭 SRQ 全生命周期与 destroy dependency、跨队列/跨线程并发、SQD/SQE
drain/flush、legacy descriptor、外部 ordering/error/backpressure、manager 外部调用窗口
补偿、AMBIGUOUS 全方向不可重放证据、Phase-1C F2 canonical authority 和最终 ownership
审计；计划继续保持 `active`。

## Batch181：MMIO evidence policy 收束与 AMBIGUOUS 全方向矩阵（已完成本批，计划仍 active）

本批把 Batch175 放在 `rdma_queue_runtime_transaction_models.sv` 中的无状态
`rdma_queue_mmio_transition_policy` 迁移到独立的
`src/core/rdma_queue_mmio_transition_policy.sv`。policy 只消费 detached 当前/目标
evidence、producer 方向、device write-attempt 和 retry confirmation，runtime 继续唯一
拥有 pending、lock、confirmation、状态投影和外部 MMIO 副作用；普通 recovery 与 noalloc
caller 的调用契约保持不变。

`rdma_queue_runtime_test` 新增 13 个直接 policy matrix case，覆盖 consumer/device
producer 的 AMBIGUOUS 终态、不可升级、NO_SUBMIT→SUCCESS/AMBIGUOUS 的一次性 confirmation、
device 写入前置条件、NOT_APPLICABLE 安装以及非法路径不消费授权。VCS53 登录 bash 中
`rdma_queue_runtime_test` 编译、PROCESS、LOGICAL PASS，UVM warning/error/fatal 为 0/0/0；
详见 `task-rdma-batch181-mmio-ambiguous-policy-report.md`。

本批仍不关闭 SRQ 全生命周期与 destroy dependency、跨队列/跨线程并发、SQD/SQE
drain/flush、legacy descriptor、外部 ordering/error/backpressure、manager 外部调用窗口
补偿、Phase-1C F2 canonical authority 和最终 ownership 审计；计划继续保持 `active`。

## Batch182：resource dependent blocker policy（已完成本批，计划仍 active）

本批新增 `src/core/rdma_resource_dependency_policy.sv`，将 resource manager activity
snapshot 中 QP/SRQ/其它 dependent 的分类和 parent release blocker 规则抽取为无状态
policy。QP 只有 outstanding 时阻塞；SRQ 与其它 dependent 即使空闲仍阻塞；未知 kind
fail-closed 为 OTHER。`rdma_resource_manager::snapshot_activity_blockers()` 继续唯一
拥有 registry 扫描、计数 snapshot、lock 和生命周期副作用。

`rdma_resource_manager_test` 新增 dependency policy matrix；VCS53 focused
PROCESS/LOGICAL PASS，UVM warning/error/fatal 为 0/0/0，详见
`task-rdma-batch182-resource-dependency-policy-report.md`。本批仍不宣称 SRQ 全生命周期
组合、跨队列/跨线程并发或最终 ownership 审计完成，计划继续保持 `active`。

## Batch183：SRQ/QP destroy admission policy（已完成本批，计划仍 active）

本批在 `rdma_resource_dependency_policy` 中新增显式 release mode 与
`blocks_release(snapshot, mode)`：严格模式保留普通 destroy/finalize 的
`live_dependents || outstanding` 规则；CQ resize 模式允许空闲 QP 继续引用 CQ，但
拒绝 SRQ/其它 dependent、带 outstanding 的 QP 以及 CQ 自身的 outstanding 操作。
`rdma_resource_manager::begin_cq_resize()` 改用该纯值 policy，registry 扫描、锁、状态
提交和外部 backing 生命周期仍由 manager 唯一拥有。

`rdma_resource_manager_test` 增加 idle QP、busy QP、idle SRQ、resource outstanding 和
strict release 组合矩阵。详见 `task-rdma-batch183-srq-destroy-admission-policy-report.md`。
本批仍不关闭 SRQ 全生命周期完整组合、跨队列/跨线程并发、SQD/SQE drain/flush、legacy
descriptor、外部 ordering/error/backpressure、manager 外部调用窗口、Phase-1C F2 或最终
ownership 审计；计划继续保持 `active`。

## Batch178：runtime/queue-data shared cursor policy（已完成本批，计划仍 active）

本批将 Batch177 的 `rdma_queue_cursor_policy` 提升为 core 公共纯值文件
`src/core/rdma_queue_cursor_policy.sv`，并在 `rdma_core_pkg.sv` 中置于 runtime/data
模型之前。`rdma_queue_data_engine.sv` 与 `rdma_queue_runtime.sv::cursor_advance()`
共同调用该 policy；runtime/engine 仍分别唯一拥有 geometry admission、cursor mutation、
reservation、slot ledger、lock 和 commit，policy 不保存可变状态或外部资源引用。
`rdma_queue_data_transaction_models.sv` 删除同名重复 class，避免两份 successor 规则。

Batch178 的 `rdma_queue_runtime_test` 与 `rdma_queue_data_engine_post_test` 在 VCS53
登录 bash 中均 PROCESS/LOGICAL PASS，UVM warning/error/fatal 为 0/0/0；修改后完整
回归为 core 97/97 PROCESS、80/80 LOGICAL、integration 10/10、UVM 107 个 pristine，
PROCESS/LOGICAL FAIL 为 0。详见 `task-rdma-batch178-shared-cursor-policy-report.md`；
计划继续保持 `active`。

本批仍不关闭 SRQ lifecycle、跨队列/跨线程并发、SQD/SQE drain/flush、legacy descriptor、
外部 ordering/error、manager 调用窗口、AMBIGUOUS 全方向组合和最终 ownership 审计。

## Batch179：CQ poll WQ target policy（已完成本批，计划仍 active）

本批将 CQ poll selector 中 send、私有 RQ、共享 SRQ 的 runtime kind/backing role 映射
提取到 `src/core/rdma_queue_wq_target_policy.sv` 的无状态
`rdma_queue_wq_target_policy::for_cqe()`，并以 detached
`rdma_queue_wq_target_contract_t` 交付给 `select_cq_poll_wq_target_contract()`。policy
只消费 CQE receive 标志和冻结 link 的 SRQ presence；QP/SRQ handle kind、完整
incarnation、attachment geometry、route/epoch、WQE ledger release 和 runtime mutation
仍由 queue-data engine/runtime 各自拥有，未复制任何 mutable owner。

`rdma_queue_data_engine_post_test` 新增 `check_wq_target_policy()`，覆盖 SQ/private-RQ/
shared-SRQ 合法映射以及 X/Z flag fail-closed。VCS53 登录 bash 的 post focused
PROCESS/LOGICAL PASS，UVM warning/error/fatal 为 0/0/0；changed-SV style 与
`git diff --check` PASS。详见 `task-rdma-batch179-wq-target-policy-report.md`。

本批仍不关闭 SRQ lifecycle、跨队列/跨线程并发、SQD/SQE drain/flush、legacy descriptor、
外部 ordering/error、manager 调用窗口、AMBIGUOUS 全方向组合、完整 parent/core/
integration regression 和最终 ownership 审计。

## Batch195：queue progress detached candidate（已完成本批，计划仍 active）

本批新增 `rdma_queue_progress_candidate`，把 queue progress 的 resource key、authoritative
resource snapshot、可选 ERROR recovery snapshot 和 `has_recovery` 组合为单一 detached 值。
`queue_progress_snapshots()` 在所有失败分支清除半成品，`commit_queue_progress()` 只在
candidate shape 与两份快照 validate 成功后一次性写回 registry/recovery_records；flush、
cleanup、context 三个入口保留既有 role cardinality、authority 比较、SRFQ flush 前置、
错误优先级和 publication 顺序。candidate 不复制 registry、recovery ledger、锁或外部
backing，manager 仍是唯一 mutable owner。

`rdma_resource_manager_test` 增加 default/partial/complete/clear shape 矩阵；resource
manager、queue lifecycle、QP lifecycle、control plane focused VCS53 均 PROCESS/LOGICAL
PASS，UVM warning/error/fatal 为 `0/0/0`，changed-SV style 与 `git diff --check` 通过。
详见 `task-rdma-batch195-queue-progress-candidate-report.md`。

本批只收束 queue progress detached 参数边界，不关闭 registry 跨线程/跨进程互斥、manager
外部调用窗口补偿、SRQ 全生命周期、跨 queue/engine 并发、Phase-1C F2 whole-plan 或最终
ownership 审计；项目计划继续保持 `active`。

## Batch196：SQ/RQ typed SGE authority 去重（已完成本批，计划仍 active）

本批在 `src/codec/rdma/rdma_sge_authority.sv` 新增无状态
`derive_typed_common()`，统一 SQE/RQE typed SGE 列表上限、null、reserved bit31、
2 GiB sentinel、累计长度和输出原子性。`derive_send()` 与 `derive_receive()` 保留
原有 API 与 `SQE`/`RQE` 诊断文案，仅委托该公共 helper；`rdma_sge_authority_test` 的
SQ/RQ 矩阵验证原有错误码和 canonical count/payload 语义不变。

VCS53 focused PROCESS/LOGICAL PASS，UVM warning/error/fatal 为 `0/0/0`；Python
293/293、changed-SV style、`git diff --check`、queue lifecycle、profile naming 和
Phase-1A approval gates 均通过，详见
`task-rdma-batch196-sge-authority-dedup-report.md`。

本批只去除重复的纯值校验实现，不关闭 registry/allocator 并发、SRQ 全生命周期、跨
queue/engine 并发、SQD/SQE drain/flush、legacy descriptor、外部 ordering/error/
backpressure、manager 外部调用窗口、Phase-1C F2 whole-plan 或最终 ownership 审计；
计划继续保持 `active`。

## Batch177：queue-data cursor policy（已完成本批，计划仍 active）

本批在 `src/core/rdma_queue_data_transaction_models.sv` 新增无状态
`rdma_queue_cursor_policy::advance()`，将 ring cursor 的末项回零、wrap 翻转和普通递增
规则收束为纯值计算。`rdma_queue_data_engine.sv` 保留原有
`advance_queue_cursor_value()` 兼容 wrapper，仅转发到 policy；engine 仍唯一负责
depth/index admission、runtime cursor mutation、reservation、pending 和 commit 顺序。
depth=0/越界 index 的原算术结果与 caller 的既有 geometry 错误优先级保持不变，policy
不读取或复制 runtime ledger、lock、backing、pending 或外部资源所有权。

`rdma_queue_data_engine_post_test` 在 VCS53 登录 bash 中 PROCESS/LOGICAL PASS，UVM
warning/error/fatal 为 0/0/0；changed-SV style 与 `git diff --check` 通过。详见
`task-rdma-batch177-cursor-policy-report.md`。

本批仍不关闭 SRQ lifecycle、跨队列/跨线程并发、SQD/SQE drain/flush、legacy descriptor、
外部 ordering/error、manager 调用窗口、AMBIGUOUS 全方向组合、完整 parent/core/
integration regression 和最终 ownership 审计；计划继续保持 `active`。
