# RDMA 结构重构执行交接

## 用户最新指令与当前状态

用户要求立即将主线优先级切换为结构优化：停止当前修复任务，先优化代码结构，
然后运行测试并修复发现的问题。此前“等待 F2 收口再开始”的顺序已被此指令替代。

本文件由侧边会话创建，记录可直接执行的任务范围与约束。侧边会话没有停止主线程，
也没有调用或干预其子代理；因此本文件不代表暂停完成、任务已调度或代码重构已启动。
交接时只读检查发现主线仍在运行 `rdma_queue_codec_test` 的 VCS53 wrapper。

工作树：`/home/ryan/workspace/ryan/rdma_work/.worktrees/rdma-cmq-contract-foundation`。
当前继续执行工作树 HEAD：`367a75bb909ac19abecc15c043ce4b95d6595f8b`；
有大量已存在的未提交改动。所有改动和已有验证证据必须保留。

## 当前批次状态（2026-09-21）

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
- `pcie_work` integration 仍受外部锁阻断，唯一阻断文本为 `external dependency is not approved: pcie_work`；
  不修改外部依赖，也不把该阻断伪造为业务失败或 GREEN。
- Batch104 之前的静态复审已通过：Python 292、CMQ manifest 22、SV keyword guard 3、
  `git diff --check`、changed-SV style，以及覆盖 5,286 个 function/task 的历史全目录中文契约/文件头
  scanner 均 GREEN；Batch110 按当前工作树重新扫描 185 个 `.sv`、2 个 `.svh`，共 5,382
  个 function/task、0 diagnostics，且 Python/manifest/keyword/queue/profile/Phase-1A
  辅助门禁均通过；Batch111 在 capability 改动后重扫为 5,387 个 function/task、0 diagnostics，
  摘要见 `evidence/batch111.*`，历史完整摘要仍位于 `evidence/final-static.meta`。

计划状态：`active`。Batch109/110 已关闭当前严格一对一 ownership/close/candidate seam
和同步 publication callback 重入 seam；Batch111 关闭 legacy Host epoch capability bypass；
Batch112 关闭同步 tokenless dataplane reset-admission seam；Batch113 关闭 SQ SGB
writer 的局部 image/payload authority seam；Batch114 关闭 UD transport-aware effective
mode 对齐 seam；Batch115–125 继续关闭 queue-data 的局部 target/replay/recovery 扫描
结构 seam，但 Batch119 关闭 recovery action/cardinality/query 顺序的局部契约、Batch120
关闭 device-producer replay 的局部职责 seam、Batch121 关闭 consumer replay 的局部职责
seam、Batch122 关闭 local-resource match/projection 的局部职责 seam、Batch123 关闭
consumer recovery authority preflight 的局部职责 seam、Batch124 关闭 consumer
recovery CQ→WQ release 的局部职责 seam、Batch125 关闭 CQ poll candidate staging 的
局部职责 seam；完整公开
post/replay 矩阵、广义 F2、coordinator 的全局并发/更深
生命周期语义、manager 外部调用窗口补偿、全目录后续生命周期审计和外部锁仍未关闭，
不得标记为 `complete`。

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
