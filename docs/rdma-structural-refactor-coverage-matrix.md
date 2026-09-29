# RDMA 结构重构覆盖矩阵

本矩阵把结构重构批次、职责边界、验证入口和遗留风险放在同一张可审查的表中。
它描述的是本项目模型/仿真契约覆盖，不等价于 Linux 驱动或真实 DUT 认证；所有
外部 PCIe、Host-memory 和 dpu_common 对象仍由各自环境拥有。

2026-09-28 最新合并：Batch222–225 已快进进入本地 `main`，源码基线 `93012a3`，
未推送。下表各批“未合回 main”等是历史状态；本次合并不关闭任何 OPEN 验收项，
也不改变 Batch225 已验证的生产/测试/构建输入。

## 业务与验证映射

| 业务边界 | 已落地的结构 seam | 主要验证入口 | 当前状态 | 遗留边界 |
| --- | --- | --- | --- | --- |
| CQ resize retry 失败收尾 | Batch232 收束 17 个记录内失败出口；保留早拒绝和两个解锁后成功分配出口，不合并正常 resize/retry policy | 21-case authority/阶段/restore/detach/release/null 故障、跨 engine factory 嵌套、既有 16-case resize 与五项 Python 门禁 | 生产净减 19 行，17 续接展开 token 等价、139 声明/类壳不变；重构前基线、终版专项、core 103/86、CMQ 28/11、integration 10、E2E 3、Host-memory 3、PCIe 1、Python 354/354、驱动及静态门禁通过；E2E 保留基线编译告警；见 `task-rdma-batch232-resize-retry-exit-report.md` | 未合回 main；完整 resize 业务编排、跨 owner 原子性及项目组合验收仍 OPEN |
| 门铃原始状态与 legacy 准入 | Batch231 删除 envelope/scheduler 的三个字段 helper，复用 types；legacy 仅在保留三枚举门禁后使用公共复制 | 136-case 枚举/factory 投影与 12-case PCIe 捕获，既有 effect/deadline/并发/factory 故障，三项 Python 门禁 | 生产净减 84 行，文件 47→44 methods，44 保留方法展开后 token 等价，15 public 及类壳不变；最终专项、core 103/86、CMQ 28/11、integration 10、E2E 3、Host-memory 3、PCIe 1、Python 349/349、驱动及静态门禁通过；E2E 保留基线编译告警；见 `task-rdma-batch231-doorbell-status-report.md` | 未合回 main；二态枚举穷举不等于 X/Z 注入；detached doorbell plan、external ordering/error 与项目组合验收仍 OPEN |
| 状态字段值操作归属 | Batch230 将两个 projector 的三个原位状态 helper 合为 rdma_status 的两个 static automatic 方法；直接调用 types，不保留转发壳 | 扩展既有 runtime test：18 个编码 × 九种入口=162 cases、嵌套 factory；既有 post test 的 null/自复制/hostile hook，五项 Python 门禁 | 生产净减 65 行，264 个保留方法展开后 token 等价，owner/锁/业务声明不变；最终专项、core 103/86、CMQ 28/11、integration 10、E2E 3、Host-memory 3、PCIe 1、Python 346/346、驱动及静态门禁通过；E2E 保留基线编译告警；见 `task-rdma-batch230-status-values-report.md` | 未合回 main；runtime fallback/data null/typed factory/legacy 校验策略分离，do_copy 原契约保留；不关闭完整业务编排与组合验收 |
| Runtime 值快照与账本分离 | Batch229 将 20 个 protected 深复制/比较/状态方法迁入无状态 static automatic projector；公开 cursor 比较保留兼容入口，锁、authority 和状态迁移仍由 runtime 拥有 | 独立 send/recv 全图与九类证据变异、24-case factory null/错型、fallback/noalloc/嵌套复制专项、六项 Python 门禁及既有 runtime/恢复业务回归 | runtime 4,646→3,814 行/94→74 methods，projector 884 行/21 methods；生产合计 +53 行，94 原方法 token 等价、58 public 不变；最终专项、core 103/86、CMQ 28/11、integration 10、E2E 3、Host-memory 3、PCIe 1、Python 341/341、驱动契约与静态门禁通过，E2E 保留基线编译告警；见 `task-rdma-batch229-runtime-projector-report.md` | 未合回 main；值层不代表无回调或跨 owner 原子快照，不新增 hostile alias 防御；runtime 组合验收、跨队列并发、SRQ 全生命周期、包 DAG 和全项目可读性仍 OPEN |
| Host-producer 未提交恢复出口 | Batch228 将 SQ/RQ/SRQ 提交尾段七处 installer 合为一个出口；无先前写入的 gate 拒绝、已提交异常与成功直接返回，NO_SUBMIT/AMBIGUOUS 和原诊断不混用 | 新增三队列 53-case gate/factory/I/O/commit/admission/SGB/retry/abort 矩阵、六项 Python 门禁；既有公开 post/recovery 用例 | engine 9,931→9,929 行、方法 token 828→679；139 声明/类壳不变、138 正文不变、七个续接展开后等价；最终专项、core 102/85、CMQ 28/11、integration 10、E2E 3、Host-memory 3、PCIe 1、Python 335/335、驱动契约及静态门禁通过，E2E 保留基线编译告警；见 `task-rdma-batch228-host-producer-exit-report.md` | 未合回 main；host admission 拒绝后的未接管证据能力、更完整业务编排、跨 owner 原子性、包 DAG 与全项目可读性验收仍 OPEN |
| 设备发布准备与取消编排 | Batch227 将准备提取为内部函数，以本次调用的普通值记录交付；九类取消续接统一，保留入口拒绝/reservation-only/完整 pending 三层权限，不新增 owner | 新增三队列 126-case 准备/factory/取消/retry/abort 矩阵、六项 Python 门禁；既有写后 30-case 与公开业务用例 | engine 9,916→9,931 行，生产净增 15 行；I/O task 268→121 行；原声明与 137 正文不变、准备及 I/O token 等价；最终 focused、core 101/84、CMQ 28/11、integration 10、E2E 3、Host-memory 3、PCIe 1、Python 329/329、驱动契约及静态门禁通过，E2E 保留基线编译警告；见 `task-rdma-batch227-device-publish-prepare-report.md` | 未合回 main；host-producer 失败续接、完整业务编排、跨 owner 原子性、包 DAG 与全项目可读性验收仍 OPEN |
| 设备发布写后恢复出口 | Batch226 将 CQ/CEQ/AEQ write/readback/mismatch/commit 四类失败统一到单次循环外的 evidence/recovery 尾段；写前取消、异常未写成功与 replay 保留原策略 | 新增三种队列的 30-case factory/I/O/commit/admission 矩阵、六项 Python 门禁，既有公开 device-publish/recovery 用例 | engine 9,934→9,916 行；138 声明/类壳不变、137 正文 token 不变、发布方法展开后等价；最终 focused、core 100/83、CMQ 28/11、integration 10、E2E 3、Host-memory 3、PCIe 1、Python 323/323、驱动契约及静态门禁通过，E2E 保留基线编译警告；见 `task-rdma-batch226-device-publish-exit-report.md` | 未合回 main；producer preparation/取消、更完整的业务编排、跨 owner 原子性、包 DAG 与全项目可读性验收仍 OPEN |
| CQ resize 发布前回滚出口 | Batch225 将 20 个相同 abort/finish 续接统一到函数内单次循环的失败出口；发布后直接返回，不新增 owner/状态/方法 | 新增 16-case 候选创建/回滚清理/发布后恢复/跨 engine 嵌套矩阵、六项 Python 门禁、既有 resize/SRQ/epoch 用例 | engine 9,977→9,934 行；138 声明与类壳不变、137 正文 token 不变、resize 展开后等价；排除 disable 跨调用退出风险，最终采用 break；最终 core 99/82、CMQ 28/11、integration 10、E2E 3、Host-memory 3、PCIe 1、focused 16-case、Python 317/317、驱动契约及静态门禁通过，E2E 保留基线编译警告；见 `task-rdma-batch225-cq-resize-exit-report.md` | 仅统一退出控制流；producer/resize 业务编排、跨 owner 原子性、包 DAG 与全项目可读性验收仍 OPEN |
| Consumer 通知证据与 CI 提交 | Batch224 将 CQ/event live poll 与 replay 的六段重复机制统一为两个 engine 内部步骤；不新增 owner/provider | 新增 45-case runtime 故障矩阵、六项 Python 结构门禁、既有 shadow/route/recovery/无分配组合 | 生产净减 23 行；136 原声明不变、133 方法 token 不变、三个 caller 展开后与基线一致；最终 core 98/81、CMQ 28/11、integration 10、E2E 3、Host-memory 3、PCIe 1、focused 45-case、Python 311/311、驱动契约及静态门禁通过，E2E 保留基线编译警告；见 `task-rdma-batch224-consumer-commit-steps-report.md` | shadow/WQE/幂等跳步保留在 caller；producer/resize 编排、跨 owner 原子性、包 DAG 和全项目可读性验收仍 OPEN |
| Queue-data 值投影与业务 owner 分离 | Batch223 将 25 个值方法集中到无字段/static automatic projector，engine 仍拥有全部索引及编排；value_ops 仅为类型别名 | 独立 identity/route/epoch 和 CQE/CEQE/AEQE snapshot、既有 factory/allocation guard 与恢复矩阵、6 项 Python 结构门禁 | engine 减少 872 行/25 methods；两生产文件合计 +17 行；161/161 方法 token 与 27 个公开声明不变；最终 core 97/80、CMQ 28/11、integration 10、E2E 3、Host-memory 3、PCIe 1、focused snapshot、Python 305/305、驱动契约及静态门禁通过，E2E 保留基线编译警告；见 `task-rdma-batch223-queue-data-projector-report.md` | 无状态不代表无回调；CQ detached slot 原位更新及部分失败输出语义保留；producer/consumer/resize 编排、跨 owner 原子性、包 DAG 和最终可读性验收仍 OPEN |
| Queue 状态字段传输 | Batch222 复用既有无分配初始化/复制 helper；raw/publish wrapper 保留各自 factory 边界，不新增生产组件 | post 新增完整字段/null/自复制/raw 工厂故障/复制先于返回 factory/无虚拟 hook 测试；既有 device publish allocation guard 与完整回归 | Batch160–221 已合入本地主线 `5f8dfe9`；Batch222 在独立分支完成，生产净减 24 行，159/161 方法 token 与全部声明不变；最终 core 97/80、CMQ 28/11、integration 10、E2E 3、Host-memory 3、PCIe 1、Python 299/299、驱动契约与静态门禁通过；见 `task-rdma-batch222-queue-status-transfer-report.md` | 本批尚未合回 main；publish wrapper 仍创建返回 status，不能误作无分配接口；queue-data 大职责拆分、跨 owner 原子性、包 DAG 与全项目可读性验收仍 OPEN |
| Resource 快照与 owner 分离 | Batch221 将 47 个投影/身份比较方法集中到无状态 projector；manager 保留唯一 ledger、guard、epoch 和 commit，不加转发壳 | resource-manager 回调重入与 authority 矩阵、control-plane probe、6 项 Python 结构门禁、完整回归 | manager 10,150→7,936 行，两生产文件合计 +3 行；最终 core 97/80、integration 10、CMQ 28/11、E2E 3、Host-memory 3、PCIe 1、Python 299/299、驱动契约与静态门禁通过；见 `task-rdma-batch221-resource-projector-report.md` | 无状态不等于纯函数；publication 后更新、跨 owner 原子性、queue-data 大职责拆分、包 DAG 和全项目可读性验收仍 OPEN |
| Allocator admission 原子提交 | Batch220 入口冻结 epoch，binding 投影锁外准备，首次登记和 ID/serial 消费共用短 guard commit；已饱和 epoch 拒绝新 reservation | 四个 fixture 的 131 个 status factory 窗口，另测 guard/epoch/generation 冲突和饱和边界 | 最终 focused、core 97/80、integration 10、CMQ 28/11、E2E 3、Host-memory 3、PCIe 1、Python 293/293、驱动契约与静态门禁全部通过，见 `task-rdma-batch220-allocator-admission-commit-report.md` | projector 由 Batch221 接续分离；publication 后更新、跨 owner 全局原子性、其它 epoch 饱和策略和项目结构验收未关闭 |
| Allocator 失败补偿隔离 | Batch219 普通对象/Function 共用 epoch-aware 补偿；过期预留只返还自身 ID，消费时冻结 epoch | resource-manager 五种交错分配、独占/pending/重复补偿、最大 ID/epoch/generation 和两个真实 factory 重入 | 最终 focused、core 97/80、integration 10、CMQ 28/11、E2E 3、Host-memory 3、PCIe 1、Python 293/293、驱动契约与静态门禁全部通过，见 `task-rdma-batch219-allocator-compensation-report.md` | reserve admission/registration 的外部窗口、饱和 epoch 的整体 publication 策略、跨 owner 原子性和项目结构验收未关闭 |
| Resource registry 强制快照提交 | Batch218 删除 check_snapshot 可选绕过；9 个生命周期 caller 强制入口 epoch/source，保留 QP exact-old recovery 与错误优先级 | resource-manager 的 10 个场景、30 个真实 callback 窗口；30 epoch / 10 guard / 7 source 冲突及重试 | focused、core 97/80（PROCESS/LOGICAL）、integration 10、CMQ 28/11、E2E 3、Host-memory 3、PCIe 1、驱动契约、Python 293/293 与静态门禁均通过，见 `task-rdma-batch218-registry-snapshot-contract-report.md` | stale rollback 由 Batch219 接续关闭；allocator admission、跨 owner 原子性、完整业务矩阵、大文件收缩及包 DAG 未关闭 |
| Resource 恢复/整批释放原子提交 | Batch217 restore/mark-error 共享双账本 helper；单资源与 Function teardown 共享全量预检再提交；lookup 只输出 detached 快照；MR reservation 保留 key index | resource-manager 新增 completion 重入、SRQ 四类 commit 冲突、批内重复/free-list 冲突与重试 | core 97/80（PROCESS/LOGICAL）、integration 10、CMQ 28/11、E2E 3、adapter、驱动契约、Python 293/293 与静态门禁通过，见 `task-rdma-batch217-resource-release-atomicity-report.md` | 9 个其它 registry caller 由 Batch218 接续关闭；allocator 外部窗口、跨 owner 原子性、完整业务矩阵及包 DAG 未关闭 |
| CMQ 值比较与提交证据 | Batch1 value contract、Batch2 typed snapshot、Batch5 body value、Batch6 journal value、Batch7 reset proof、Batch8 binding value | `rdma_cmq_engine_models_test`、`rdma_cmq_codec_test`、`rdma_cmq_completion_test`、CMQ gate | GREEN；Batch86 gate 28/28 process、11/11 logical、UVM 0/0/0 | legacy `execute()` 的三个 Phase 1B consumer 尚未完全移除 |
| CMQ completion/route authority | Batch27–30 CQE/CEQE/AEQE publish authority；Batch31–37 handle/route/cursor predicates | `rdma_cq_engine_test`、`rdma_cq_shadow_flush_test`、`rdma_eq_engine_test`、`rdma_aeqe_route_test` | focused 与 parent gate GREEN | 更深的 recovery/MMIO 语义仍由 owner task 维护 |
| queue-data attachment/recovery | Batch40、46–47、52–54、55–66、78–86：context geometry、route/epoch、CQ identity、pending attachment、CEQE route；Batch113 SQ external-SGB writer 的 canonical mode/count、descriptor packing 与 image-signature gate；Batch114 UD effective mode 对齐；Batch115 `post_recv()` RQ/SRQ target-resolution helper；Batch116 `replay_pending()` host-producer recovery helper（SGB/WQE、doorbell、producer commit）；Batch117 `recover_queue()` claimed recovery attachment scan helper；Batch118 `recover_queue()` reservation-only candidate collection helper；Batch119 `recover_queue()` action/confirmation preflight、reservation cardinality 与 query-before-recover contract；Batch120 `replay_pending()` device-producer recovery helper（reservation/route/epoch、DEVICE_WRITE、readback、commit）；Batch121 `replay_pending()` consumer recovery helper（CQ route/QP/SRQ identity、shadow/doorbell、consumer commit、CQ→WQ release、completion）；Batch123 `replay_consumer_pending()` authority preflight（`validate_consumer_recovery_authority()` 的 pending shape、route/epoch、CQ/QP/SQ/RQ/SRQ/WQ 与 release-range 只读校验）；Batch124 `replay_consumer_pending()` recovery-only CQ→WQ release seam（`release_consumer_pending_wqe()` 的 begin/release/finish bilateral gate、frozen completion target 与 failure evidence）；Batch125 `poll_cqe_once` candidate staging（`stage_cq_poll_candidate()` 的 WQ route/release snapshot、completion/result/pending、next cursor 与 shadow/doorbell preparation，首个 `enter_recovery_prepared()` mutation 保留在 caller）；Batch128 CEQ/AEQ shared consumer commit（`commit_event_poll_candidate()`）；Batch129 CQ poll WQ contract（`select_cq_poll_wq_target_contract()`、`validate_cq_poll_wq_attachment()` 的 selector/validator 与 staged-output canonical relookup）；Batch130 私有 RQ receive CQE 正向 poll fixture（`make_cqe_for_outstanding_receive()` 与 `check_private_rq_receive_cqe_e2e()`）；Batch131 staged WQ canonicalization（`canonicalize_cq_poll_wq_attachment()`）与 UD SEND 正向 poll fixture；Batch132 shared-SRQ receive CQE 正向 poll fixture（独立 SRQ/QP route helper、`post_recv`→`publish_cqe`→`poll_cqe` 与 SRQ ledger/cursor 断言）；Batch133 CQE variant/SRFQ topology consistency gate（`validate_cqe_variant_consistency()`、`validate_cqe_srfq_route_consistency()`、publish reservation 前 admission 与 poll image decode 前 admission）；Batch148 host-producer route/epoch snapshot、commit/recovery install 与统一 completion tail；Batch149 reservation-only recovery resolver（`resolve_reservation_only_recovery()` 的全量 query、cardinality 与唯一 abort/detach） | `rdma_queue_data_engine_poll_test`、`rdma_queue_data_engine_post_test`、`rdma_queue_data_engine_recovery_test`、`rdma_queue_data_engine_device_publish_test`、`rdma_queue_event_route_consume_test`、`rdma_aeqe_route_test`、`rdma_aeqe_f5_e2e_test` | Batch86 focused 与 integration GREEN；Batch113 post-test baseline/mutation focused GREEN；Batch114 UD 1B inline/1-SGE/2-SGE writer focused GREEN；Batch115 post/recovery focused 与公开 UD post/replay probe GREEN；Batch116 recovery/post focused GREEN；Batch117 device-publish/recovery/post focused GREEN；Batch118 device-publish/recovery/post focused GREEN；Batch119 device-publish/recovery/post focused GREEN，PROCESS/LOGICAL PASS、UVM 0/0/0；Batch120 device-publish/recovery/post focused GREEN，PROCESS/LOGICAL PASS、UVM 0/0/0；Batch121 device-publish/recovery/post focused GREEN，PROCESS/LOGICAL PASS、UVM 0/0/0，style/diff/queue/profile/manifest/keyword/Phase-1A/Python 门禁 GREEN，queue-data engine/device-publish test 逐文件 method scanner 139/122、0 diagnostics，全目录 scanner 5,405 methods/0 diagnostics；Batch123 device-publish/recovery/post focused PROCESS/LOGICAL PASS、UVM 0/0/0，style/diff/queue/profile/manifest/keyword/Phase-1A/Python 门禁 GREEN，queue-data engine/device-publish test 逐文件 method scanner 140/122、0 diagnostics，全目录 scanner 5,407 methods/0 diagnostics；Batch124 device-publish/recovery/post focused PROCESS/LOGICAL PASS、UVM 0/0/0，style/diff/queue/profile/manifest/keyword/Phase-1A/Python 门禁 GREEN，queue-data engine/device-publish test 逐文件 method scanner 141/122、0 diagnostics，全目录 scanner 5,408 methods/0 diagnostics；Batch125 poll/device-publish/recovery/post focused PROCESS/LOGICAL PASS、UVM 0/0/0，style/diff/queue/profile/manifest/keyword/Phase-1A/Python 门禁 GREEN，queue-data engine/device-publish test 逐文件 method scanner 142/122、0 diagnostics，全目录 scanner 5,409 methods/0 diagnostics；Batch128 event/poll focused PROCESS/LOGICAL PASS、UVM 0/0/0，`rdma_aeqe_f5_e2e_test` 通过；Batch129 四项 queue-data focused（poll/post/recovery/device-publish）均 PROCESS/LOGICAL PASS、UVM 0/0/0；Batch130 四项 queue-data focused（poll/post/recovery/device-publish）均 PROCESS/LOGICAL PASS、UVM 0/0/0，其中 poll 新增私有 RQ receive CQE 正向链；Batch131 四项 queue-data focused（poll/post/recovery/device-publish）均 PROCESS/LOGICAL PASS、UVM 0/0/0，其中 poll 追加 UD SEND 正向链与 staged hostile canonicalization probe；Batch132 四项 queue-data focused（poll/post/recovery/device-publish）均 PROCESS/LOGICAL PASS、UVM 0/0/0，其中 poll 新增 shared-SRQ receive CQE 正向链，覆盖 `local_srq_id`/SRFQ overlay、SRQ ledger/cursor release 与私有 RQ 不变；Batch133 publish/poll variant 与 SRFQ-topology rejection focused（poll/device-publish/post/recovery）均 PROCESS/LOGICAL PASS、UVM 0/0/0；dual-env fixture 显式启用 CQC shadow；锁定 `dpu_common`/`host_mem`/`net_packet` 后 transport E2E PROCESS/LOGICAL PASS、UVM INFO 32、WARNING/ERROR/FATAL 0，URC READ 在 net_packet wire capability 层按 `RDMA_SC_UNSUPPORTED_OPCODE` 拒绝；Batch148 post/recovery/poll/device-publish/hostile-failure/commit-failure focused 均 PROCESS/LOGICAL PASS、UVM INFO `3/3/3/220/27/8`、WARNING/ERROR/FATAL 0；Batch149 device-publish/recovery focused 均 PROCESS/LOGICAL PASS、UVM INFO `220/3`、WARNING/ERROR/FATAL 0；changed-SV style、`git diff --check`、queue/profile/manifest/keyword/Phase-1A/Python 292 与全目录 scanner 5,461 methods/0 diagnostics GREEN | query_pending 与 runtime.recover 的窄窗口并发、claimed/reservation 扫描缺少 engine-level 全局锁、host-produced SQ/RQ/SRQ reservation query 的既有 `INVALID_STATE` 边界、unclaimed admission 后重复 claimed runtime 的迁移窗口、consumer authority/release helper 只读 seam 不形成 engine-level 全局原子锁、CQ→WQ 跨队列 release 的更广泛并发、UD receive/replay、legacy descriptor 分支、CEQ/AEQ malformed retry、SRQ 全量公开 post/recovery lifecycle、snapshot 后 alias 审计、device/consumer recovery 组合矩阵与最终全目录 ownership/注释审计仍开放 |
| queue runtime | Batch37、41–42、45、48、50、53–54 的 cursor/credit/identity/value seam；Batch88 收敛 route/epoch 纯比较并完成注释合规刷新 | `rdma_queue_runtime_test`、`rdma_queue_lifecycle_test`、recovery focused suites、CMQ gate | Batch88 focused GREEN；Batch89–93 后 parent gate GREEN（28/28、11/11、UVM 0/0/0） | 不复制 runtime mutable ledger；Phase 1C F2 的全局 sge_num 收口仍暂停，RC inline-SGB 容量拒绝已由 Batch100 独立关闭 |
| queue-data CQ poll target | Batch126 从 `stage_cq_poll_candidate()` 提取 `resolve_cq_poll_wq_target()`，按冻结 CQE receive 标志和 QP link 选择 SQ/私有 RQ/共享 SRQ，并集中校验完整 handle incarnation、runtime/access、entry geometry、kind 与 backing role；Batch129 再拆出 `select_cq_poll_wq_target_contract()` 与共享 `validate_cq_poll_wq_attachment()`，让 selector 只推导冻结 target contract，validator 复用 kind/role/geometry/incarnation 门禁，poll admission 在首次 mutation 前拒绝 pending kind 漂移；Batch130 在现有 contract 之上补充私有 RQ `RDMA_CQE_VARIANT_RQ_SRFQ` receive CQE 的公开 publish→poll 正向链，验证 RQ release 与 SQ 不变；Batch131 将 staged WQ canonicalization 提取为 `canonicalize_cq_poll_wq_attachment()`，在首次 mutation 前统一 pending-kind、geometry/role/incarnation 校验，并以 detached alias probe 覆盖 canonical relookup；同批补充 UD SEND `RDMA_CQE_VARIANT_UD` 的公开 publish→poll 正向链；Batch132 在同一 frozen target contract 上补充真实 shared-SRQ `RDMA_CQE_VARIANT_RQ_SRFQ` receive CQE 的公开 publish→poll 正向链，验证 `local_srq_id`/SRFQ overlay、SRQ ledger release 与私有 RQ 不变；Batch133 让 variant/SRFQ topology gate 在 poll admission 前复用冻结 QP link authority，拒绝 receive/SRQ 拓扑漂移和错误 send overlay；resolver、canonicalizer 与 poll admission 对 selector output 的 null/错误 incarnation 均从冻结 link 回填 canonical handle，再按同一 target contract validator/relookup；helper 只读，不进入 pending、不写 Host-memory/MMIO | `rdma_queue_data_engine_poll_test`、`rdma_queue_data_engine_post_test`、`rdma_queue_data_engine_recovery_test`、`rdma_queue_data_engine_device_publish_test` | Batch126 四项 wrapper 均在最终源码边界 PROCESS/LOGICAL PASS、UVM 0/0/0；Batch129 四项 wrapper 均 PROCESS/LOGICAL PASS、UVM 0/0/0；Batch130 四项 wrapper 均 PROCESS/LOGICAL PASS、UVM 0/0/0，poll test 新增私有 RQ 正向链；Batch131 四项 wrapper 均 PROCESS/LOGICAL PASS、UVM 0/0/0，poll test 新增 UD SEND 正向链和 staged hostile canonicalization probe；Batch132 四项 wrapper 均 PROCESS/LOGICAL PASS、UVM 0/0/0，poll test 新增 shared-SRQ receive CQE 正向链；Batch133 四项 wrapper 均 PROCESS/LOGICAL PASS、UVM 0/0/0，publish hostile 断言 SRFQ topology/variant 拒绝，shared-SRQ poll probe 直接验证 malformed image rejection 后 occupancy/cursor 不变，poll 正向链验证共享 resolver；changed-SV style、`git diff --check`、queue/profile/manifest/keyword/Phase-1A/Python 292 与全目录 scanner 5,431 methods/0 diagnostics GREEN | UD receive/replay、legacy descriptor branch、CQ route/epoch admission、selector class-handle output 的 simulator 保真性、snapshot 后 alias 审计、engine-level 全局锁、private-RQ poll-side hostile、全量 malformed matrix、poll/recovery 组合、CQ→WQ 跨队列并发和最终 ownership 审计仍 OPEN |
| queue-data CQ poll commit | Batch127 将 `poll_cqe_once()` 首次 `enter_recovery_prepared()` 之后的 live-CQE mutation/commit 阶段提取为 `commit_cq_poll_candidate()`：shadow/doorbell、MMIO evidence、CQ consumer commit、CQ→WQ begin/release/finish、recovery completion 与 result publish；caller 只保留 read/decode/route/staging/relookup | `rdma_queue_data_engine_poll_test`、`rdma_queue_data_engine_post_test`、`rdma_queue_data_engine_recovery_test`、`rdma_queue_data_engine_device_publish_test` | Batch127 四项 wrapper 均在最终源码边界 PROCESS/LOGICAL PASS、UVM 0/0/0；全目录 scanner 185 `.sv`+2 `.svh`、5,411 methods/0 diagnostics；changed-SV style、queue/profile、manifest/keyword、Phase-1A、Python 292 与 `git diff --check` GREEN | helper 仍是 live-CQE 专用，不与 Batch124 frozen-recovery release 合并；shadow/doorbell null-status、poll/recovery 组合、RQ/SRQ 与 UD 正向 poll、engine-level 全局锁、跨队列并发和最终 ownership 审计仍 OPEN |
| queue-data event poll commit | Batch128 将 CEQ/AEQ poll 的 prepared pending 之后重复阶段提取为 `commit_event_poll_candidate()`：统一 admission、consumer doorbell、MMIO evidence、CI commit、failure continuation、recovery completion 与 route-miss/result publish；CEQ/AEQ 各自保留 decode、route、CQ flush secondary owner 与 detached candidate 准备，不触碰 CQ→WQ release | `rdma_queue_event_route_consume_test`、`rdma_aeqe_route_test`、`rdma_queue_data_engine_poll_test`、`rdma_queue_data_engine_recovery_test` | Batch128 event/poll wrappers 在最终源码边界 PROCESS/LOGICAL PASS、UVM 0/0/0；changed-SV style、`git diff --check` 通过；全目录 scanner/完整四项 queue-data 回归需在提交前继续刷新 | route miss 丢弃 payload 但仍 ack、doorbell/commit failure evidence、CEQ/AEQ malformed retry、legacy descriptor、engine-level 全局锁、staged WQ 二次 geometry/role revalidation、poll/recovery 组合、跨队列并发和最终 ownership 审计仍 OPEN |
| queue-data event poll preparation | Batch143 将 `poll_ceqe_once()`/`poll_aeqe_once()` 在 decode/route/result candidate 之后重复的 `prepare_consumer_pending()`→`prepare_consumer_doorbell()` 尾段提取为 `prepare_event_poll_continuation()`；CEQ `route_found` 与 AEQ `deliver_found` 仍留在 caller，首次 `enter_recovery_prepared()` 及 `commit_event_poll_candidate()` 顺序不变 | `rdma_queue_event_route_consume_test`、`rdma_aeqe_route_test` | Batch143 两项在最终源码边界 PROCESS/LOGICAL PASS、UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0`；helper 只做 detached staging，最终全目录 scanner 5,437 methods/0 diagnostics | CEQ/AEQ malformed retry、doorbell-failure recovery exactly-once、CQ→WQ release、SRQ lifecycle、legacy descriptor、跨队列并发、engine-level 全局锁和最终 ownership 审计仍 OPEN |
| queue-data event poll timeout | Batch154 将 `poll_ceqe()`/`poll_aeqe()` 重复的 deadline、`QUEUE_EMPTY` retry、null-status normalization 和 timeout 返回提取为 `poll_event_with_timeout()`；`poll_ceqe_once()`/`poll_aeqe_once()` 的 decode、route、pending、doorbell、commit、recovery 仍分离，public virtual wrapper 保留 | `rdma_queue_data_engine_poll_test`、`rdma_queue_event_route_consume_test`、`rdma_aeqe_route_test`、`rdma_eq_engine_test` | Batch154 三项 queue-data focused 与 EQ facade timeout focused 均 PROCESS/LOGICAL PASS、UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0`；changed-SV style、`git diff --check`、queue/profile/Phase-1A/Python 292 门禁 GREEN；全目录 scanner 5,465 methods/0 diagnostics | CEQ/AEQ malformed retry、route-miss/doorbell-failure recovery exactly-once、SRQ lifecycle、legacy descriptor、跨队列并发、engine-level 全局锁和最终 ownership 审计仍 OPEN |
| EQ facade operation envelope | Batch155 以 protected non-virtual `validate_operation_authority()` 与 `normalize_delegate_status()` 收束五个 public task 的配置/Function authority admission 和 delegate null-status 归一化；consumer/producer/secondary-authority typed delegate 调用仍分别显式保留，成功 `result=null` 不被误判为失败 | `rdma_eq_engine_test`、`rdma_queue_data_engine_poll_test`、`rdma_queue_event_route_consume_test`、`rdma_aeqe_route_test` | 四项最终源码边界 VCS53 均 wrapper rc=0、PROCESS/LOGICAL PASS、UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` 且 pristine；五个未配置入口、五条 null-status 消息及非空失败 status 对象身份已锁定；生产源码 327→272 行；style/diff/queue/profile/Phase-1A/Python 292 GREEN；全目录 scanner 5,467 methods/0 diagnostics | CEQ/AEQ route、timeout retry、runtime/backing/cursor、producer/consumer mutation、CQ-flush secondary authority、malformed retry、跨队列并发、SRQ lifecycle、legacy descriptor、外部 PCIe error/ordering、engine-level 全局锁与最终 ownership 审计仍 OPEN |
| CQ facade operation envelope | Batch156 以 protected non-virtual `validate_operation_authority()` 与 `normalize_delegate_status()` 收束 `poll_cqe()`/`publish_cqe()`/`resize()` 的配置/Function authority admission 和 delegate null-status 归一化；三个 typed virtual seam 保持独立，`flush_shadow()` 的 shared-only/inout/replay 契约不并入 | `rdma_cq_engine_test`、`rdma_cq_engine_resize_test`、`rdma_cq_shadow_flush_test` | 三项最终源码边界 VCS53 均 wrapper rc=0、PROCESS/LOGICAL PASS、UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` 且 pristine；三条 null 精确消息、三条非空失败 status 身份、poll/publish sentinel 清理和 stale-epoch 三组 counter 已锁定；生产源码 500→498 行，非注释非空行 373→344；style/diff/queue/profile/Phase-1A/Python 292 GREEN；全目录 scanner 5,469 methods/0 diagnostics | `flushed_shadow` 当前只写不读，replay 只校验 caller authority/返回 cached status，不回填缓存 snapshot，authority 匹配但 CI/arm/sequence 任意的输入仍可能成功；该契约须独立决策。跨队列并发、SRQ lifecycle、legacy descriptor、外部 PCIe error/ordering、engine-level 全局锁与最终 ownership 审计仍 OPEN |
| CQ shadow replay / factory atomicity | Batch157 删除可变 `shadow_flush_result`；新增 raw factory nonfatal helper、手工 handle clone、detached shadow snapshot clone，以及 queue-data URC evidence candidate 的 raw factory/cast。普通 `configure()+configure_shared()` 拒绝跨 Function UID/generation 并复用 live binding admission；首次 `flush_shadow()` 在 URC evidence 前分别 staging caller/cache，replay 从 cache 重建 canonical detached snapshot/status，不重复 evidence 或 `shadow_flush_count`；`configure_shared()`、首刷（含 evidence candidate）与 replay 的分配失败均保持 caller/cache/count/evidence 原子不变 | `rdma_cq_shadow_flush_test`、`rdma_cq_engine_test`、`rdma_cq_engine_resize_test` | 三项 VCS53 最终源码边界均 wrapper rc=0、PROCESS/LOGICAL PASS、UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` 且 pristine；factory null/错误类型、detached alias、authority rejection、跨 Function UID/generation、ordinary configure+shared live reset gate 已覆盖；style/diff/queue/profile/Phase-1A/manifest/keyword/Python 门禁 GREEN；全目录 scanner 5,483 methods/0 diagnostics | `configure_shared()`-only 没有 live binding，无法独立认证真实 reset；跨队列并发、SRQ lifecycle、legacy descriptor、外部 PCIe ordering/error、engine-level 全局锁、全目录最终 ownership 审计与完整 parent/core gate 仍 OPEN |
| queue-data host-producer completion tail | Batch144 将 `post_send()`/`post_recv()` reservation 后重复的 WQE `write_and_verify()`、next-cursor、producer doorbell、`commit_producer()` 与 detached result/recovery tail 提取为 `complete_host_producer_tail()`；SQ 专属 `write_sgb_and_verify()` 仍留在 caller | `rdma_queue_data_engine_post_test`、`rdma_queue_data_engine_recovery_test`、`rdma_queue_data_engine_poll_test`、`rdma_queue_data_engine_device_publish_test` | Batch144 post/recovery/poll 三项在最终源码边界 PROCESS/LOGICAL PASS、UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0`，device-publish 同样 PASS、UVM `INFO=220/WARNING=0/ERROR=0/FATAL=0`；changed-SV style、diff、queue/profile/Phase-1A/Python292 门禁通过；全目录 scanner 5,438 methods/0 diagnostics | helper 不新增 reservation/authority/route-epoch admission；post_send 的显式 route/epoch 复核、WQE/doorbell/commit hostile 组合、SRQ 全生命周期、legacy descriptor、跨队列并发、engine-level 全局锁与最终 ownership 审计仍 OPEN |
| queue-data host-producer admission | Batch145 将 SQ/私有 RQ/shared SRQ 的 `validate_attachment_route_epoch()`→`reserve_producer()` 顺序提取为 `reserve_host_producer_cursor()`；`post_send()` 在 SQE authority 后、`post_recv()` 在 owner/target 后共享该 admission，失败保持 cursor=null（含 null-status fault）且不触碰 backing/MMIO/ledger | `rdma_queue_data_engine_post_test`、`rdma_queue_data_engine_recovery_test`、`rdma_queue_data_engine_poll_test`、`rdma_queue_data_engine_device_publish_test` | Batch145 四项 focused 均 PROCESS/LOGICAL PASS；post/recovery/poll UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0`，device-publish `INFO=220/WARNING=0/ERROR=0/FATAL=0`；send stale-epoch fixture 返回 `RDMA_SC_STALE_GENERATION` 且 cursor/used/pending/Host-memory/MMIO 不变；changed-SV style、diff、queue/profile/Phase-1A/Python292 通过；全目录 scanner 5,440 methods/0 diagnostics | reservation 后 route 变化窗口、WQE/doorbell/commit hostile 组合、SRQ 全生命周期、legacy descriptor、跨队列并发、engine-level 全局锁、snapshot 后 alias 与最终 ownership 审计仍 OPEN |
| queue-data host-producer commit/recovery | Batch148 将 `snapshot_attachment_route_epoch()`、reservation 后窗口复核、`commit_host_producer_ledger()`、`admit_host_producer_recovery()`/`install_host_producer_recovery()` 与 `complete_host_producer_tail()` 收束为单一 producer admission/recovery/commit 结构；pending 统一保留 reservation 冻结 route/epoch，raw factory/handle clone 失败均 fail-closed | `rdma_queue_data_engine_post_test`、`rdma_queue_data_engine_recovery_test`、`rdma_queue_data_engine_poll_test`、`rdma_queue_data_engine_device_publish_test`、`rdma_queue_host_producer_failure_final_fix_test`、`rdma_queue_host_producer_commit_failure_test` | Batch148 focused 均 PROCESS/LOGICAL PASS；UVM INFO `3/3/3/220/27/8`，WARNING/ERROR/FATAL 全 0；stale replay 不增加 I/O，commit failure 保持 PI/CI/used 不变并留下 `AMBIGUOUS` evidence；style/diff/profile/queue/Phase-1A/manifest/keyword/Python 292 门禁 GREEN；全目录 scanner 5,460 methods/0 diagnostics | reservation 后跨线程 route 变化、admission/enter-recovery failure matrix、跨队列 CQ→WQ 并发、SRQ 全生命周期、legacy descriptor、外部 PCIe error/ordering 组合、engine-level 全局锁、snapshot alias 与最终 ownership 审计仍 OPEN |
| resource manager | Batch38–44、51、67、74、76、79 的 segment/backing/type/owner/recovery projection；Batch89 收敛 SRQ restore flush progress；Batch97 role cardinality；Batch99 context progress authority/parity；Batch102 QP/queue transient alias audit；Batch122 `lookup_local_resource()` 的 `scan_local_resource_matches()` 只读 owner/generation/local-id/cardinality seam | `rdma_resource_manager_test`、`rdma_aeqe_route_test`、`rdma_queue_recovery_test`、`rdma_queue_data_engine_post_test`、`rdma_queue_lifecycle_test`、`rdma_qp_lifecycle_test` | Batch99/102 focused GREEN；Batch104 current parent/core gate GREEN（CMQ 28/28 process、11/11 logical；core 95/95 process、78/78 logical；UVM 0/0/0）；Batch122 resource-manager/AEQE/recovery/post focused PROCESS/LOGICAL PASS、UVM 0/0/0，style/diff/queue/profile/manifest/keyword/Phase-1A/Python gates GREEN | manager-level registry scan/projection concurrency、duplicate-live fixture、跨 incarnation lifecycle 与更深 recovery/MMIO 仍开放 |
| Resource schema detached commit atomicity | Batch209 将 `registry_schema_status()`、`recovery_schema_status()` 和 `recovery_entry_schema_status()` 从边遍历边写回改为 detached 全量/单条投影；外部 clone/factory 完成后才获取 `mutation_guard`，并检查 `publication_epoch` 与 source 引用后一次性提交，保留未知 recovery key 的幂等成功语义 | `rdma_resource_manager_test` 的 PD-key/MR-carrier hostile fixture | VCS53 `rdma_resource_manager_test` PROCESS/LOGICAL PASS，UVM WARNING/ERROR/FATAL `0/0/0`；Python 293/293、changed-SV style、queue/profile/Phase-1A 与 diff gate 通过；报告见 `task-rdma-batch209-schema-commit-atomicity-report.md` | allocator/registry 跨线程或跨进程完整互斥、manager 更广泛外部调用窗口、SRQ 全生命周期、跨 queue/engine 原子性、SQD/SQE drain/flush、legacy descriptor、PCIe ordering/error/backpressure、Phase-1C F2 whole-plan 与最终 ownership 审计仍 OPEN |
| Resource registry replacement commit guard | Batch210 新增 `commit_registry_replacement()`，统一 stage/program/activate、CQ resize/replacement、CQ/QP programming attach 和 QP semantic-only commit 的最终 registry 写回；helper 在 guard 内重新确认 key/handle identity、validation、staged 单向变化并推进 `publication_epoch`，外部 projection 不持锁 | `rdma_resource_manager_test`，随后 core regression | VCS53 focused manager PROCESS/LOGICAL PASS、UVM WARNING/ERROR/FATAL `0/0/0`；core regression 重新执行后跨 queue/QP/control-plane 结果保持通过；报告见 `task-rdma-batch210-registry-commit-guard-report.md` | QP recovery 双账本、allocator/registry 跨线程或跨进程完整互斥、manager 其它外部调用窗口、SRQ 全生命周期、跨 queue/engine 原子性、SQD/SQE drain/flush、legacy descriptor、PCIe ordering/error/backpressure、Phase-1C F2 whole-plan 与最终 ownership 审计仍 OPEN |
| Queue progress 双账本 OCC 提交 | Batch211 为 `rdma_queue_progress_candidate` 增加 `manager_epoch`、registry/recovery source 引用；`queue_progress_snapshots()` 在 projection 前冻结非拥有 OCC 证据，`commit_queue_progress()` 在 mutation guard 内复核 epoch、两份 source 引用和 detached validate 后同步写回 registry/recovery 并推进 publication epoch | `rdma_resource_manager_test`、queue lifecycle/QP lifecycle recovery paths | VCS53 `rdma_resource_manager_test` PROCESS/LOGICAL PASS，UVM WARNING/ERROR/FATAL `0/0/0`；candidate clear shape、changed-SV style、Python contract tests 与 `git diff --check` GREEN；报告见 `task-rdma-batch211-queue-progress-occ-report.md` | QP 专用 `commit_qp_progress()` 仍需同等 OCC source/epoch seam；allocator/registry 跨线程或跨进程完整互斥、manager 其它外部调用窗口、SRQ 全生命周期、跨 queue/engine 原子性、SQD/SQE drain/flush、legacy descriptor、PCIe ordering/error/backpressure、Phase-1C F2 whole-plan 与最终 ownership 审计仍 OPEN |
| QP recovery progress OCC 提交 | Batch212 为 QP 专用 `qp_progress_snapshots()`/`commit_qp_progress()` 增加 epoch、registry source、recovery source 的 snapshot→commit 证据；flush、owned cleanup、context cleanup 三个入口在同一 guard 内同步提交 QP registry 与 ERROR recovery | `rdma_resource_manager_test`、`rdma_qp_lifecycle_test` | 两项 VCS53 focused PROCESS/LOGICAL PASS，UVM WARNING/ERROR/FATAL `0/0/0`；Batch211 core 97/97 PROCESS、80/80 LOGICAL 与 integration 10/10 保持通过；报告见 `task-rdma-batch212-qp-progress-occ-report.md` | QP recovery 其它状态写回仍有直接 registry/recovery 路径；allocator/registry 跨线程或跨进程完整互斥、manager 其它外部调用窗口、SRQ 全生命周期、跨 queue/engine 原子性、SQD/SQE drain/flush、legacy descriptor、PCIe ordering/error/backpressure、Phase-1C F2 whole-plan 与最终 ownership 审计仍 OPEN |
| QP recovery metadata OCC helper | Batch213 新增 `commit_recovery_replacement()`，统一 `update_qp_recovery_progress()` 与 `retain_qp_query_mapping()` 的 recovery-only detached projection→source/epoch/validate→guard commit；成功推进 `publication_epoch`，不改变 mapping ownership 或 recovery authority | `rdma_qp_recovery_test` | VCS53 PROCESS/LOGICAL PASS，UVM WARNING/ERROR/FATAL `0/0/0`；changed-SV style、`git diff --check` 通过；报告见 `task-rdma-batch213-qp-recovery-metadata-occ-report.md` | mark-error/programmed 的 registry+recovery 双写、allocator/registry 跨线程或跨进程完整互斥、manager 其它外部调用窗口、SRQ 全生命周期、跨 queue/engine 原子性、SQD/SQE drain/flush、legacy descriptor、PCIe ordering/error/backpressure、Phase-1C F2 whole-plan 与最终 ownership 审计仍 OPEN |
| QP ERROR/programmed 双账本原子提交 | Batch214 新增 `commit_resource_recovery_replacement()`，统一 `mark_qp_error()` 与 `commit_qp_programmed()` 的 registry/recovery/staged 最终写回；helper 复核 resource/recovery source、epoch、handle identity 与双 validate，再同步安装/清除 recovery 并推进 publication epoch | `rdma_resource_manager_test`、`rdma_qp_lifecycle_test`、`rdma_qp_recovery_test` | 三项 VCS53 focused PROCESS/LOGICAL PASS，UVM WARNING/ERROR/FATAL `0/0/0`；changed-SV style 与 `git diff --check` 通过；报告见 `task-rdma-batch214-qp-error-double-ledger-report.md` | allocator/registry 跨线程或跨进程完整互斥、manager 其它外部调用窗口、SRQ 全生命周期、跨 queue/engine 原子性、SQD/SQE drain/flush、legacy descriptor、PCIe ordering/error/backpressure、Phase-1C F2 whole-plan 与最终 ownership 审计仍 OPEN |
| Outstanding ledger registry OCC 提交 | Batch215 扩展 `commit_registry_replacement()` 的可选 snapshot/epoch 复核，`track_outstanding()` 与 `retire_outstanding()` 通过同一 guard 原子更新 detached outstanding ledger；旧 source/epoch、重复或未知 ID 均 fail-closed | `rdma_resource_manager_test` | VCS53 PROCESS/LOGICAL PASS，UVM WARNING/ERROR/FATAL `0/0/0`；changed-SV style 与 `git diff --check` 通过；报告见 `task-rdma-batch215-outstanding-ledger-occ-report.md` | 其它 manager 外部写回、allocator/registry 跨线程或跨进程完整互斥、SRQ 全生命周期、跨 queue/engine 原子性、SQD/SQE drain/flush、legacy descriptor、PCIe ordering/error/backpressure、Phase-1C F2 whole-plan 与最终 ownership 审计仍 OPEN |
| Recovery clear OCC 提交 | Batch216 新增 `clear_recovery_record()`，`clear_recovery()` 在 absence/release-completion 前置通过后携带 source/epoch 进入 guard 删除；未知 key 保持幂等成功，成功删除推进 publication epoch | `rdma_resource_manager_test` | VCS53 PROCESS/LOGICAL PASS，UVM WARNING/ERROR/FATAL `0/0/0`；changed-SV style 与 `git diff --check` 通过；报告见 `task-rdma-batch216-recovery-clear-occ-report.md` | 其它 manager 外部写回、allocator/registry 跨线程或跨进程完整互斥、SRQ 全生命周期、跨 queue/engine 原子性、SQD/SQE drain/flush、legacy descriptor、PCIe ordering/error/backpressure、Phase-1C F2 whole-plan 与最终 ownership 审计仍 OPEN |
| environment/backing composition | Batch91 复审 env/config、queue backing access、responder registry 的 detached snapshot、borrowed adapter、claim/seal 和 Function-incarnation 契约；Batch105 candidate detached value-graph seal 与 hostile cross-context mutation 拒绝；Batch106 env-local reset reentrancy guard；Batch107 reset 后 registration incarnation 刷新；Batch108 coordinator↔env↔router ownership seam 只读审计；Batch109 严格一对一 lease/token、bilateral attach/detach、close 和 capability handshake；Batch110 coordinator publication guard 与同步 callback 拒绝；Batch111 legacy Host epoch callback capability seal 与 direct mutation guard；Batch112 tokenless dataplane reset admission、opaque allocate rollback、cleanup drain 与 fresh-incarnation recovery；Batch185 detached tokenless admission policy characterization | `rdma_env_composition_test`、`rdma_queue_backing_access_test`、`rdma_responder_registry_test`、`rdma_reset_candidate_integrity_test`、`rdma_device_env_test`、`rdma_host_mem_router_test`、`rdma_reset_coordinator_lifecycle_test`、reset integration suites | Batch91 focused、Batch101/103 reset integration、Batch105/106 focused、Batch107 integration/CMQ/core regression、Batch109 focused 与 integration 10/10、Batch110 focused 6 项与 integration 10/10/CMQ/core GREEN；Batch111 focused/lifecycle、integration 10/10、CMQ 28/28+11/11、core 95/95+78/78 与 Python 292 均在当前 worktree GREEN；Batch112 focused host-router/coordinator、integration 10/10、Python 292、style/diff GREEN，UVM 0/0/0；Batch185 coordinator focused VCS53、Python 292、changed-SV style/diff GREEN；全目录 scanner 当前新增 policy 后为 5,489 methods/0 diagnostics，静态辅助门禁通过 | coordinator 的跨线程/跨进程全局并发锁、跨环境 callback 语义、manager 外部调用窗口补偿与更深生命周期/所有权审计仍开放 |
| SQ payload transaction | Batch92 把 receipt/Function/SGE/mapping candidate staging 前移到 refs++/Host I/O 之前，并归一化外部 null status | `rdma_sq_payload_writer_test`、queue-data post paths | Batch92 focused GREEN；Batch89–93 后 parent gate GREEN | Host-memory partial write 后的补偿语义仍由 writer/adapter 契约维护 |
| CMQ poison/recovery contract | Batch93 校正 poison 的 FIFO 清理、diagnostic staging fallback 和 fail-closed 失败边界说明 | `rdma_cmq_engine_test`、`rdma_cmq_completion_test`、CMQ gate | Batch93 focused GREEN；parent gate GREEN（28/28、11/11、UVM 0/0/0） | 尚未加入同一 poll late-final+malformed CQE 的组合 fault fixture |
| codec/profile/wire | Batch9–26、68、72–75 的 tuple/profile/mask/CQE metadata 与 hostile factory fixture；Batch100 RC inline-SGB fixed-capacity guard（512B/32 chunks）；Batch113 writer 对已编码 image/SGB signature 的 fail-closed 校验；Batch114 UD transport-aware `INLINE_SGB`/`SGE_SGB` effective mode | codec/profile/driver-field mutation tests、`rdma_defs`、`rdma_sq_codec_test`、`rdma_queue_codec_test`、`rdma_ud_urc_sqe_codec_test`、`rdma_queue_data_engine_post_test` | Batch100 focused GREEN（3/3 wrapper、PROCESS/LOGICAL PASS、UVM 0/0/0）；Batch113/114 focused GREEN；保留冻结 wire 坐标和 reserved bits | 完整公开 UD post/replay 矩阵、8-bit XOR 多点抵消限制与 Phase 1C F2 whole-plan 收口仍 OPEN；不将局部 gate 误称为 ABI/F2 全量修复 |
| Function context/binding | Batch87 候选式 build/reset/activate、identity consistency、owner handle 与 PCIe projection；Batch95 延迟 registration；Batch98 reset preflight；Batch101 跨 context prepare/commit 原子性；Batch105 candidate fingerprint/value-graph seal；Batch106 coordinator epoch staging、registration incarnation 与 router-local capacity 预检；Batch107 reset 后 stale registration 拒绝与 current baseline refresh；Batch109 三条 commit seam 的 generation/epoch provenance seal 与 leased mutation authorization；Batch110 coordinator publication guard；Batch111 coordinator/router direct mutation guard 与 opaque Host epoch publication capability；Batch112 tokenless dataplane admission 与 reset 后 fresh context recovery；Batch185 detached tokenless admission policy characterization | `rdma_function_context_test`、`rdma_env_composition_test`、`rdma_device_env_test`、`rdma_reset_cascade_test`、`rdma_reset_candidate_integrity_test`、`rdma_reset_coordinator_test`、`rdma_reset_coordinator_lifecycle_test`、`rdma_host_mem_router_test` | Batch98/101/105/106 focused、Batch107 integration/CMQ/core regression、Batch109 focused 与 integration 10/10、Batch110 focused 6 项与 integration/CMQ/core GREEN，UVM 0/0/0；Batch101 关闭跨 context 半提交窗口，Batch106 关闭普通 scope 的部分 epoch bump 窗口，Batch107 关闭 reset 后旧 registration 快路径，Batch109 关闭 tokenless leased mutation 绕过，Batch110 关闭同步 publication callback 重入，Batch111 关闭 legacy Host epoch capability bypass；Batch112 focused host-router/coordinator 与 integration 10/10、Batch185 coordinator focused VCS53 与 Python/style/diff 均 GREEN | coordinator 的跨线程/跨进程全局并发锁、全目录生命周期/所有权复审、manager 外部调用窗口补偿及最终注释审查仍开放 |
| SR-IOV/PCIe allocator | Batch87 null status、pre-existing ownership guard、BAR rollback、lease factory atomicity；Batch90 清理多 VF 失败时 `discovered` 部分输出并加入 VF1 注入；当前接入 `pcie_work` main 的真实 config-proxy/SR-IOV 路径 | `rdma_sriov_enumerator_authority_test`、`rdma_sriov_enumeration_test`、`rdma_pcie_work_adapter_test`、allocator focused | core authority GREEN；依赖锁 verify GREEN；`rdma_pcie_work_adapter_test` compile/elab/link 与仿真 GREEN（UVM 4/0/0/0）；`rdma_sriov_enumeration_test` compile/elab/link 与仿真 GREEN（UVM 260/0/0/0） | pcie_work 上游缺少 root README/LICENSE/tag，需保留供应链风险；host_mem/pcie_work 完整 regression、更多 PCIe error/ordering matrix 仍开放 |
| 外部环境与门禁 | dpu_common identity authority；VCS53 wrapper；manifest/style/diff gates；全目录中文契约 scanner；Batch106 focused reset evidence；Batch107 current-source static and parent/core/integration evidence；Batch109 ownership/close/candidate evidence；Batch110 publication-guard evidence；Batch111 mutation-guard/capability evidence；Batch113 SGB writer mutation evidence；Batch114 UD effective-mode evidence；Batch118 reservation-candidate seam evidence；Batch119 recovery-action contract evidence；Batch120 device-producer replay seam evidence；Batch121 consumer recovery seam evidence；Batch122 local-resource match/projection seam evidence；Batch123 consumer-authority preflight evidence；Batch124 consumer release seam evidence；Batch125 poll candidate-staging evidence；Batch126 poll target-resolution evidence；Batch127 poll commit-candidate evidence；Batch128 event commit-candidate evidence；Batch130 private-RQ poll evidence；Batch131 staged WQ canonicalization/UD SEND poll evidence；Batch132 shared-SRQ receive poll evidence；Batch133 variant/SRFQ admission、shared-SRQ hostile poll 与 transport capability evidence；pcie_work adoption/lock/adapter/SR-IOV evidence | `scripts/run_vcs53.sh`、Python 292、manifest 22、`rdma_defs` 203、style、diff-check、current-source contract scanner、Batch111 reset/integration/CMQ/core suites、resource-manager/AEQE/recovery/post focused tests、`rdma_queue_data_engine_poll_test`、`rdma_queue_data_engine_post_test`、queue-data recovery/device-publish focused tests、`rdma_queue_event_route_consume_test`、`rdma_aeqe_route_test`、codec focused tests、`tools/check_external_dependency_lock.py` | Batch113/114 post/codec suites PROCESS/LOGICAL PASS、UVM 0/0/0；Batch118 device-publish/recovery/post PROCESS/LOGICAL PASS、UVM 0/0/0；Batch119 device-publish/recovery/post focused PROCESS/LOGICAL PASS、UVM 0/0/0；Batch120 device-publish/recovery/post focused PROCESS/LOGICAL PASS、UVM 0/0/0；Batch121 device-publish/recovery/post focused GREEN，PROCESS/LOGICAL PASS、UVM 0/0/0；Batch122 resource-manager/AEQE/recovery/post focused GREEN，PROCESS/LOGICAL PASS、UVM 0/0/0；style/keyword/diff/queue/profile/manifest/Phase-1A/Python gates GREEN；Batch123 device-publish/recovery/post focused PROCESS/LOGICAL PASS、UVM 0/0/0，全目录 scanner 185 `.sv`+2 `.svh`、5,407 methods/0 diagnostics；Batch124 device-publish/recovery/post focused PROCESS/LOGICAL PASS、UVM 0/0/0，全目录 scanner 185 `.sv`+2 `.svh`、5,408 methods/0 diagnostics；Batch125 poll/device-publish/recovery/post focused PROCESS/LOGICAL PASS、UVM 0/0/0，全目录 scanner 185 `.sv`+2 `.svh`、5,409 methods/0 diagnostics；Batch126 poll/post/recovery/device-publish focused PROCESS/LOGICAL PASS、UVM 0/0/0，全目录 scanner 185 `.sv`+2 `.svh`、5,410 methods/0 diagnostics；Batch127 poll/post/recovery/device-publish focused PROCESS/LOGICAL PASS、UVM 0/0/0，全目录 scanner 185 `.sv`+2 `.svh`、5,411 methods/0 diagnostics；Batch128 poll/event route focused PROCESS/LOGICAL PASS、UVM 0/0/0（`rdma_queue_data_engine_poll_test`、`rdma_queue_event_route_consume_test`、`rdma_aeqe_route_test`）；Batch130 poll/post/recovery/device-publish focused PROCESS/LOGICAL PASS、UVM 0/0/0，其中 poll 新增私有 RQ receive CQE 正向链；Batch131 poll/post/recovery/device-publish focused PROCESS/LOGICAL PASS、UVM 0/0/0，其中 poll 新增 UD SEND 正向链和 staged hostile canonicalization probe；Batch132 poll/post/recovery/device-publish focused PROCESS/LOGICAL PASS、UVM 0/0/0，其中 poll 新增 shared-SRQ receive CQE 正向链；Batch133 poll/post/recovery/device-publish focused PROCESS/LOGICAL PASS、UVM 0/0/0，transport E2E UVM INFO 32/WARNING 0/ERROR 0/FATAL 0；pcie_work/host_mem lock verify GREEN；adapter 与 SR-IOV focused 分别 UVM INFO 4/260、WARNING/ERROR/FATAL 全为 0；全目录 scanner 刷新为 5,431 methods/0 diagnostics，style/diff/queue/profile/manifest/keyword/Phase-1A/Python 292 GREEN | 任何 VCS 仿真必须继续在 53 主机登录 shell 执行；host_mem/pcie_work 完整 regression、coordinator 跨线程/跨进程并发、更深生命周期审计、公开 UD replay 与外部 ordering/error matrix 仍开放 |

| queue-data device-producer publish admission | Batch158 将 `publish_cqe()`、`publish_ceqe()` 与 `publish_aeqe_common()` 重复的 `reserve_device_producer()`/expected-polarity 检查提取为 `reserve_device_publish_checked()` 与 `check_device_publish_polarity()`；CQE/CEQE 继续 reservation→polarity→codec，AEQE 继续 image staging→reservation→route/epoch recheck→polarity→commit | `rdma_queue_data_engine_device_publish_test`、`rdma_queue_data_engine_poll_test`、`rdma_aeqe_route_test`、`rdma_aeqe_f5_e2e_test` | Batch158 四项 VCS53 最终源码边界均 wrapper rc=0、PROCESS/LOGICAL PASS，UVM `INFO=220/3/3/115`、WARNING/ERROR/FATAL 全为 0；`git diff --check`、changed-SV style、queue/profile/Phase-1A/Python 292 与全目录 scanner 5,485 methods/0 diagnostics GREEN | authority/codec 顺序、AEQE reservation 后 route/epoch 窗口、write/commit recovery、跨队列并发、SRQ lifecycle、legacy descriptor、外部 PCIe ordering/error、engine-level 全局锁和最终 ownership 审计仍 OPEN |

| CMQ shared transport envelope decode | Batch159 将 observed submit 与 recovery submit 重复的 transport envelope 解码提取为 `decode_transport_envelope()`；统一输出 detached operation status、observation code/message 与 raw submission effect，保留 observed/recovery context 的文案差异和 malformed effect 覆盖规则；observer arm、effect fold、分类、journal/CAS mutation 仍留在 caller | `rdma_cmq_engine_test`（18-process logical runner） | Batch159 VCS53 wrapper rc=0，18/18 PROCESS PASS、1/1 LOGICAL PASS，18 个 UVM report 均 pristine（WARNING/ERROR/FATAL 全为 0）；静态 gates、Python 292/292 与全目录 scanner 5,488 methods/0 diagnostics GREEN | malformed observed/recovery 组合的更广泛矩阵、跨队列/跨线程并发、engine-level 全局锁、SRQ lifecycle、legacy descriptor、外部 ordering/error、完整 CMQ/core regression、typed URC factory 与最终 ownership/Phase-1C F2 审计仍 OPEN |
| CMQ transaction kernel / staging | Batch160 将 slot record、preallocated publish/reset/MMIO observer 与 submit/recovery/expiry/cancel staging value 移出 `rdma_cmq_engine.sv`；新增 `rdma_cmq_transaction_kernel.sv` 统一 sequence→index/wrap、occupancy、CQ owner 和 slot geometry，expiry timeout 与 generation cancel 共用 `rdma_cmq_terminal_transition_candidate_stage_t`；engine 继续唯一拥有 runtime/journal/fence/lock，profile 继续唯一负责 SQE/CQE/doorbell 编解码 | `rdma_cmq_engine_test`（18-process logical runner）及 `rdma_cmq_driver_field_mutation_test` | 最终 VCS53 core 与完整 CMQ gate 均 rc=0，18/18 engine process、11/11 logical、字段变异证据 PASS，UVM WARNING/ERROR/FATAL 全为 0；静态 manifest 23/23、keyword/style/diff GREEN；全目录复审 191 文件、5,496 methods、0 hard diagnostics | journal locator、completion/timeout/late、reset epoch 的进一步公共接口仍开放；observed/recovery/reset 的 admission/commit 仍由 engine policy 保持，未引入第二账本 owner；跨线程并发、外部 ordering/error、完整 Phase-1C F2 与最终 ownership 审计仍 OPEN |
| QP lifecycle transition policy | Batch161 将 `RESET→INIT→RTR→RTS`、`ERROR/RESET` 回退和当前 `SQD/SQE` capability gate 从 `rdma_qp_lifecycle_executor` 的内嵌 `case` 抽为无状态 `rdma_qp_transition_decide()`；policy 只返回 semantic-only/full-modify/invalid decision，executor 继续拥有 outstanding-work、QPC image、CMQ、resource manager 和 commit 顺序 | `rdma_qp_lifecycle_test`、`rdma_qp_recovery_test`、`rdma_control_plane_test`、`rdma_control_plane_cmq_engine_test` | 四项 VCS53 focused 均 PROCESS/LOGICAL PASS，UVM WARNING/ERROR/FATAL 全为 0；状态主干、ERROR/RESET、非法迁移及 SQD/SQE gate 已覆盖；Python 293/293、style/diff、manifest/keyword/queue/profile/Phase-1A、依赖锁与全目录 192 文件/5,498 methods/0 diagnostics GREEN | SQD/SQE drain/flush 仍未实现并保持 `RDMA_SC_UNSUPPORTED_OPCODE`；QP destroy dependency、跨队列并发、reset 统一验收和后续 lifecycle operation envelope 仍开放 |
| Resource lifecycle blocker admission | Batch162/168 在 `rdma_resource_manager` 内以 `snapshot_activity_blockers()` 统一读取 manager registry 的 live dependents 与 resource-owned `outstanding_ids`；Batch168 新增 detached `rdma_resource_activity_blocker_snapshot`，附带 dependent/outstanding 数量，`begin_quiesce()`、QP/facade finalize 与 reservation release 继续在原调用点决定错误优先级、状态迁移和 `force_release_key()`，不复制账本或把依赖判断下放到 policy | `rdma_resource_manager_test`、`rdma_queue_lifecycle_test`、`rdma_qp_lifecycle_test`、`rdma_qp_recovery_test`、`rdma_control_plane_test` | Batch168 的 resource-manager、queue lifecycle、QP lifecycle、control-plane 四项 VCS53 均 PROCESS/LOGICAL PASS，UVM WARNING/ERROR/FATAL 全为 0；dependency fixture 验证 PD 三个直接 dependent/零 outstanding；全目录中文契约 scanner 196 文件、5,518 methods、0 diagnostics，changed-SV style 与 diff-check GREEN | QP/SRQ 跨资源 destroy dependency 的更广泛组合、跨队列并发、reset 统一验收、manager 外部调用窗口补偿与最终 ownership 审计仍开放 |
| Resource allocator/factory transaction seam | Batch163 新增 `rdma_resource_identity_candidate` detached value，`reserve_identity_candidate()` 统一承载一次 identity 预留的 owner、handle、local-id、serial 与 binding-registration 回滚证据；PD/MR/CQ/QP/SRQ/CMQ/CEQ/AEQ 的 `create_*` 入口复用 `reserve→construct→register→publish` 与 `rollback_identity_candidate()`，manager 继续唯一拥有 allocator、registry 和 resource publication | `rdma_resource_manager_test`、`rdma_queue_lifecycle_test`、`rdma_qp_lifecycle_test`、`rdma_qp_recovery_test`、`rdma_control_plane_test` | 五项 VCS53 focused 均 PROCESS/LOGICAL PASS，UVM WARNING/ERROR/FATAL 全为 0；Python 293/293、changed-SV style、`git diff --check`、queue/profile/Phase-1A 与静态 manifest/keyword 门禁通过；当前源码 193 文件（191 `.sv`、2 `.svh`），本批新增 5 个有中文契约的方法，未复制 mutable ledger | `create_function()` 仍保留专用 Function 身份路径；allocator/registry 并发、跨 incarnation destroy、reset 统一验收、外部调用窗口补偿和最终 ownership 审计仍开放 |
| Resource identity publication seam | Batch192 新增受保护 `publish_identity_candidate()`，统一普通 PD/MR/CQ/QP/SRQ/CMQ/CEQ/AEQ 的 candidate.valid → authoritative shape → `register_resource()` → null/失败回滚 → candidate.clear 骨架；字段投影、依赖 admission、output cast 与 QP sequence 更新仍留在 caller，Function generation/tombstone 路径不复用 | `rdma_resource_manager_test`、`rdma_queue_lifecycle_test`、`rdma_qp_lifecycle_test`、`rdma_control_plane_test` | 四项 VCS53 focused 均 PROCESS/LOGICAL PASS，UVM WARNING/ERROR/FATAL 为 0/0/0；Python 293/293、changed-SV style 与 `git diff --check` PASS；manager 仍为 allocator、registry、binding registration 和 publication 唯一 owner | allocator/registry 跨线程并发、跨 incarnation destroy dependency、SRQ 全生命周期、legacy descriptor、外部 ordering/error/backpressure、manager 外部调用窗口、Phase-1C F2 whole-plan 和最终 ownership 审计仍 OPEN |
| Resource publication stage/commit seam | Batch193 新增 `rdma_resource_publication_candidate`，将 `register_resource()` 的 factory/clone 投影收束到 `stage_resource_publication()`，将 registry、incarnation owner/handle 与 known-generation 写入收束到无外部调用的 `commit_resource_publication()`；兼容入口只负责 stage→commit→published/clear，manager 仍唯一拥有四份 mutable 账本 | `rdma_resource_manager_test`（stage/commit probe）、`rdma_queue_lifecycle_test`、`rdma_qp_lifecycle_test`、`rdma_control_plane_test` | Batch193 四项 VCS53 focused PROCESS/LOGICAL PASS，UVM WARNING/ERROR/FATAL 为 0/0/0；null stage 保持 registry 不变，valid candidate 在 stage 后不可 lookup、commit 后可 lookup，clear 后二次 commit 返回 `RDMA_SC_INVALID_STATE`；Python/style/diff/scanner 门禁通过 | stage 期间的跨线程/跨进程互斥、allocator/registry 全局并发、跨 incarnation destroy dependency、SRQ 全生命周期、外部 ordering/error/backpressure、Phase-1C F2 whole-plan 和最终 ownership 审计仍 OPEN |
| Lifecycle result initialization seam | Batch166 新增 `rdma_lifecycle_result_seed`，统一 control-plane、queue lifecycle 与 QP executor 的 detached transaction-id/pending-status/initial-resource-state staging；seed 只保存值，不复制 result/recovery ledger，三个 executor 继续各自拥有 policy、CMQ 顺序和 resource commit | `rdma_control_plane_test`、`rdma_queue_lifecycle_test`、`rdma_qp_lifecycle_test` | 三项 VCS53 focused 均 PROCESS/LOGICAL PASS，UVM WARNING/ERROR/FATAL 全为 0；新增 model include 与 executor 调用路径完成 VCS 编译，`git diff --check`、changed-SV style 通过 | reset coordinator evidence/candidate、QP/SRQ destroy dependency、跨队列/跨线程并发、SQD/SQE drain/flush、外部 ordering/error、manager 外部调用窗口补偿和最终 ownership 审计仍开放 |

| Reset epoch candidate | Batch167 新增 `rdma_reset_epoch_candidate`，把 `prepare_function_epoch_commit()` 的 detached Function epoch capture、scope 递增和 validate 收束为显式 candidate；coordinator 仍唯一提交 `m_function_epochs`，VF/PF/Host/Device reset policy 与 quiesce/release 顺序不变 | `rdma_reset_coordinator_test`、`rdma_reset_coordinator_pf_root_scope_test`、`rdma_reset_coordinator_lifecycle_test` | 三项在 VCS53 锁定依赖边界 PROCESS/LOGICAL PASS，UVM WARNING/ERROR/FATAL 全为 0；candidate source alias、unknown/空 map、clear 后拒绝和现有 scope 行为均通过；报告见 `task-rdma-batch167-reset-epoch-candidate-report.md` | coordinator 跨线程/跨进程并发、QP/SRQ 跨资源 destroy dependency、SQD/SQE drain/flush、外部 ordering/error、manager 外部调用窗口补偿和最终 ownership 审计仍开放 |

| Queue-data detached result models | Batch169 新增 `rdma_queue_data_transaction_models.sv`，把 post/device-publish/CQ-completion/CEQ-AEQ-event 四类公共结果对象从 `rdma_queue_data_engine.sv` 移到独立模型层；结果只拥有 detached 值快照，engine 继续唯一拥有 attachment、poll/post/recovery 和 runtime mutation | `rdma_queue_data_engine_poll_test`、`rdma_queue_data_engine_post_test`、`rdma_queue_data_engine_recovery_test`、`rdma_queue_data_engine_device_publish_test`、`rdma_queue_event_route_consume_test` | 五项 VCS53 focused 均 PROCESS/LOGICAL PASS，UVM WARNING/ERROR/FATAL 全为 0；core package include 顺序和结果类型消费者均完成编译验证；报告见 `task-rdma-batch169-queue-data-result-models-report.md` | queue-data parent/core 全量 regression、跨队列并发、SRQ lifecycle、legacy descriptor、外部 ordering/error、engine-level 全局锁和最终 ownership 审计仍开放 |

| Queue-data attachment models | Batch170 将 `rdma_queue_data_attachment`、`rdma_queue_data_qp_link` 和 `rdma_cq_resize_recovery` 从 queue-data engine 顶层移到同一 transaction-model 文件；backing-access 先定义，engine 仍唯一拥有索引和 runtime/backing 编排 | `rdma_queue_data_engine_poll_test`、`rdma_cq_engine_test`、`rdma_eq_engine_test` 及 Batch169 queue-data focused | 当前 boundary 的 poll/CQ/EQ focused 均 PROCESS/LOGICAL PASS，UVM WARNING/ERROR/FATAL 全为 0；模型默认字段、capability 非拥有语义和 core package include 顺序完成编译验证；报告见 `task-rdma-batch170-queue-data-attachment-models-report.md` | queue-data parent/core 全量 regression、跨队列并发、SRQ lifecycle、legacy descriptor、外部 ordering/error、engine-level 全局锁和最终 ownership 审计仍开放 |

| QP/SRQ dependency combination snapshot | Batch171 扩展 `rdma_resource_activity_blocker_snapshot`，由 `snapshot_activity_blockers()` 一次扫描生成 QP/SRQ/非 QP dependent 分类及 dependent outstanding 证据；`begin_cq_resize()` 复用 detached 结果，允许空闲 QP 引用 CQ，拒绝非 QP 或有在途 QP dependent | `rdma_resource_manager_test` dependency fixture | VCS53 PROCESS/LOGICAL PASS，UVM WARNING/ERROR/FATAL 全为 0；PD→SRQ→QP hostile combination 验证 QP/SRQ 分类和既有 leaf-first destroy 顺序；changed-SV style、`git diff --check` PASS；报告见 `task-rdma-batch171-dependency-combination-snapshot-report.md` | 跨队列/跨线程并发、SRQ 全生命周期、SQD/SQE drain/flush、legacy descriptor、外部 PCIe ordering/error、manager 外部调用窗口补偿和最终 ownership 审计仍开放 |
| CEQ/AEQ event decode and malformed retry | Batch172 将 `poll_ceqe_once()`/`poll_aeqe_once()` 重复的 codec key、registry lookup、decode 与 null-status 处理提取为只读 `decode_event_image()`；CEQ/AEQ 各自继续拥有 owner/route/CQ-flush/pending/doorbell/CI commit policy；malformed decode 在首次 mutation 前拒绝，修复 raw image 后由 caller 显式 retry | `rdma_queue_event_route_consume_test` | CEQ/AEQ reserved-bit hostile fixture 均验证第一次 `RDMA_SC_CODEC_ERROR` 不改变 CI、occupancy、pending、MMIO，恢复原始 16B image 后恰好一次 consumer commit；VCS53 PROCESS/LOGICAL PASS，UVM WARNING/ERROR/FATAL 为 0/0/0；changed-SV style、`git diff --check` PASS；报告见 `task-rdma-batch172-event-decode-retry-report.md` | malformed 多点/timeout 组合、doorbell-failure recovery exactly-once、跨队列并发、SRQ 生命周期、legacy descriptor、外部 ordering/error 和最终 ownership 审计仍开放 |
| CEQ/AEQ consumer doorbell recovery | Batch173 在真实 CEQ/AEQ topology 上复用 `rdma_queue_data_engine_ordering_fault` 注入一次确定性 `NO_SUBMIT` doorbell failure；公开 `recover_queue()` 先拒绝未确认 retry，再仅重放同一 pending，完成 CI/occupancy 后拒绝第二次 retry；不新增 owner/ledger/lock | `rdma_queue_event_route_consume_test` | CEQ/AEQ 首次 poll 均保留 `RDMA_QUEUE_MMIO_NO_SUBMIT` pending；确认 retry doorbell 次数恰增 1、occupancy 归零；重复 retry `RDMA_SC_INVALID_STATE` 且无额外 MMIO；VCS53 PROCESS/LOGICAL PASS，UVM WARNING/ERROR/FATAL 0/0/0；changed-SV style 与 `git diff --check` PASS；报告见 `task-rdma-batch173-event-doorbell-recovery-report.md` | `RDMA_QUEUE_MMIO_AMBIGUOUS` 不可重放策略、跨队列/跨线程并发、SRQ 全生命周期、legacy descriptor、外部 PCIe ordering/error、engine-level 全局锁和最终 ownership 审计仍 OPEN |
| Queue-data cursor policy | Batch177 将 `rdma_queue_data_engine.sv` 的 ring cursor 环回计算下沉为无状态 `rdma_queue_cursor_policy::advance()`；engine 保留兼容 wrapper，并继续拥有 depth/index admission、runtime mutation、reservation 与 commit | `rdma_queue_data_engine_post_test` 及 queue-data poll/device-publish/recovery focused | VCS53 `rdma_queue_data_engine_post_test` PROCESS/LOGICAL PASS，UVM WARNING/ERROR/FATAL 0/0/0；policy 不复制 runtime ledger/lock/backing；changed-SV style 与 `git diff --check` PASS；报告见 `task-rdma-batch177-cursor-policy-report.md` | SRQ 全生命周期、跨队列/跨线程并发、SQD/SQE drain/flush、legacy descriptor、外部 PCIe ordering/error、manager 外部调用窗口补偿、AMBIGUOUS 全方向组合和最终 ownership 审计仍 OPEN |
| Runtime/queue-data shared cursor policy | Batch178 将 `rdma_queue_cursor_policy` 提升为 `src/core/rdma_queue_cursor_policy.sv` 公共纯值层；runtime `cursor_advance()` 与 queue-data wrapper 共用同一 successor 规则，重复 class/算术删除，runtime/engine 继续各自拥有 admission、mutation、ledger、reservation、lock 和 commit | `rdma_queue_runtime_test`、`rdma_queue_data_engine_post_test`，最终回归覆盖 queue-data poll/device-publish/recovery | Batch178 两项 focused VCS53 均 PROCESS/LOGICAL PASS，UVM WARNING/ERROR/FATAL 0/0/0；修改后完整回归 core 97/97 PROCESS、80/80 LOGICAL、integration 10/10、UVM pristine 107，PROCESS/LOGICAL FAIL 为 0；报告见 `task-rdma-batch178-shared-cursor-policy-report.md` | SRQ 全生命周期、跨队列/跨线程并发、SQD/SQE drain/flush、legacy descriptor、外部 PCIe ordering/error、manager 外部调用窗口补偿、AMBIGUOUS 全方向组合和最终 ownership 审计仍 OPEN |
| CQ poll WQ target policy | Batch179 将 send/private-RQ/shared-SRQ 的 runtime kind/backing role 映射提取为无状态 `rdma_queue_wq_target_policy::for_cqe()`，selector 继续拥有 handle、attachment、route/epoch 和 ledger admission | `rdma_queue_data_engine_post_test::check_wq_target_policy` 与既有 CQ poll/recovery focused | VCS53 `rdma_queue_data_engine_post_test` 编译、PROCESS、LOGICAL PASS，UVM WARNING/ERROR/FATAL 0/0/0；changed-SV style 与 `git diff --check` PASS；报告见 `task-rdma-batch179-wq-target-policy-report.md` | SRQ 全生命周期与 destroy dependency、跨队列/跨线程并发、SQD/SQE drain/flush、legacy descriptor、外部 PCIe/Host-memory ordering/error/backpressure、manager 外部调用窗口补偿、AMBIGUOUS 全方向组合、完整 regression 和最终 ownership 审计仍 OPEN |

> 当前口径更新（2026-09-24）：上表“外部环境与门禁”行末的 5,431 methods 是
> Batch133 历史边界，不是当前总数。Batch160 当前 scanner 为 191 文件（189 `.sv`、
> 2 `.svh`）、5,496 methods（`.sv` 5,494、`.svh` 2）、0 diagnostics；完整 CMQ gate
> 已追加重跑并通过 11/11 logical、18/18 engine process，字段变异证据 PASS，UVM
> warning/error/fatal 为 0/0/0。表中早期行使用的“当前 worktree”均指对应批次当时的源码
> 边界，不指 Batch160 当前源码边界。

> Batch161 QP policy 当前源码边界为 192 个文件（190 `.sv`、2 `.svh`）、5,498 个
> methods（`.sv` 5,496、`.svh` 2）、0 hard diagnostics；新增 policy 不复制 mutable
> owner，`rdma_qp_lifecycle_executor` 仍是 QP 资源/QPC/CMQ 提交顺序的唯一 owner。

> Batch163 allocator/factory transaction 当前源码边界为 193 个文件（191 `.sv`、2
> `.svh`）、5,504 methods（`.sv` 5,502、`.svh` 2）、0 diagnostics。`rdma_resource_identity_candidate` 只保存一次 transient reservation 的
> detached 回滚证据；allocator 数组、binding registration、registry 和 publication 仍由
> `rdma_resource_manager` 唯一拥有。当前 focused 回归均为 VCS53 PROCESS/LOGICAL PASS，
> UVM warning/error/fatal 为 0/0/0；计划继续保持 `active`。

> Batch168 当前源码边界已刷新为 196 个源码文件（194 `.sv`、2 `.svh`）、5,518 个
> function/task、0 hard diagnostics；Batch167 reset candidate 与 Batch168 activity blocker
> focused 均通过，项目级计划仍保持 `active`。

> Batch169 当前源码边界为 197 个源码文件（195 `.sv`、2 `.svh`）、5,518 个
> function/task、0 hard diagnostics；queue-data 五项 focused 均通过，项目级计划仍保持
> `active`。

> Batch170 当前源码边界仍为 197 个源码文件（195 `.sv`、2 `.svh`）、5,518 个
> function/task、0 hard diagnostics；queue-data attachment/CQ/EQ focused 通过，current
> boundary CMQ gate 为 28/28 process、11/11 logical，core regression 为 97/97 process、
> 80/80 logical，integration regression 为 10/10 scenarios，所有 UVM summary pristine。

> Batch171 没有新增源码文件或 function/task；当前源码边界仍为 197 个源码文件（195
> `.sv`、2 `.svh`）、5,518 个 function/task。resource-manager focused 在锁定
> `dpu_common` 依赖的 VCS53 登录 bash 中通过，UVM warning/error/fatal 为 0/0/0；项目级
> 计划继续保持 `active`。

### pcie_work 当前接入证据（2026-09-22）

- `pcie_work` 固定为 main commit `1a80801e7d336ceeb492e7cdf57ba26ef27c2456`，依赖闭包
  tree SHA-256 为 `8a9853c2cb618b5f73f4d2fed2167fad3a7b08bce37298cfef9ea159b1c5feb1`，锁中
  75 个文件行均为 `APPROVED`；`host_mem` 固定为
  `365b7553fc7dac6b4ad55886a8e4869153607c28`/`b9cd7d686c954823bdeafcea2f02013908fed51db5a8f4d39e96e5e877f6c770`。
- 对干净本地 clone 执行 `tools/check_external_dependency_lock.py verify` 的
  `pcie_work` 与 `host_mem` 两项均通过；adapter 只通过本项目
  `rdma_pcie_work_adapter` seam 消费外部类型，没有复制或修改外部源码。
- 53 机登录 bash 的 `rdma_pcie_work_adapter_test` 和
  `rdma_sriov_enumeration_test` 均 compile/elab/link、仿真和 UVM summary 通过，分别为
  `INFO=4/260`、`WARNING=0/ERROR=0/FATAL=0`。完整依赖 regression 尚未完成，且上游仓库
  缺少 root README/LICENSE/tag，供应链审计风险保留在开放边界。

### Batch134/135 当前更新（2026-09-22）

- Batch134 在锁定的 `pcie_work` 供应商快照上补充了 TL-only poisoned/error 与基础
  ordering smoke：53 机登录 bash 中 `pcie_tl_smoke_err_test` 为
  `UVM_INFO=5/WARNING=0/ERROR=0/FATAL=0`，ordering smoke 为
  `UVM_INFO=6/WARNING=0/ERROR=0/FATAL=0`，scoreboard 为 `2 requests / 1 completion /
  1 matched`。该结果只证明供应商本体的窄 TL 契约，不替代 RDMA adapter 组合注入。
- Batch135 在 queue-data poll fixture 中补充公开 UD 私有 RQ 的
  `post_recv()` Host-memory write fault → confirmed `recover_queue(RETRY_PENDING)` →
  `publish_cqe()`/`poll_cqe()` receive/release 闭环；测试逐字节比较 replay image，验证
  RQ/CQ occupancy、cursor、`wr_id`、QPN 与单项 release，并确认未确认 retry 被
  `RDMA_SC_INVALID_ARGUMENT` 拒绝。53 机最终源码边界 compile/elab/link/PROCESS/LOGICAL
  全部 PASS，UVM 为 `INFO=3/WARNING=0/ERROR=0/FATAL=0`。
- 两批均只关闭窄证据 seam：`pcie_work` 的 adapter↔TL error/ordering 组合、timeout、
  malformed TLP、tag-conflict、DMA/backpressure、多 root/SR-IOV stress，以及 UD
  多包/多队列 replay、malformed CQE/recovery 组合、legacy descriptor、跨队列并发和
  engine-level 全局锁仍保持 OPEN。对应报告为
  `task-cmq-batch134-pcie-work-error-ordering-report.md` 和
  `task-cmq-batch135-ud-receive-replay-report.md`。

### Batch136 当前更新（2026-09-22）

- `rdma_queue_lifecycle_executor.sv` 将 `rollback_created()` 中 pre-delete flush、delete
  和 post-delete flush 三处同构的 legacy CMQ 输出处理收束到
  `execute_queue_command()`；helper 新增阶段诊断消息，但保留原有
  `live_binding_fence()` checkpoint、ambiguity 判定和失败即返回顺序。`create_locked()`
  与 `destroy_locked()` 的其它 legacy consumer 尚未迁移。
- `rdma_queue_lifecycle_test` 与 `rdma_queue_recovery_test` 在 53 机最终源码边界均
  compile/elab/link、PROCESS/LOGICAL PASS，UVM 均为 `INFO=3/WARNING=0/ERROR=0/FATAL=0`；
  changed-SV style、`git diff --check`、queue/profile 门禁通过。
- 本批只关闭 rollback 重复逻辑的局部结构 seam，不把兼容 `cmq.execute()` 误报成
  `execute_observed()` 全量迁移；三个 Phase 1B consumer、timeout/ambiguous 组合、
  engine-level 全局锁和完整 parent regression 仍开放。详见
  `task-cmq-batch136-legacy-rollback-execution-seam-report.md`。

### Batch137 当前更新（2026-09-22）

- 在 Batch136 的 rollback helper 复用基础上，`create_locked()` 和 `destroy_locked()`
  的 create、delete、两类 flush 路径共三处 direct `cmq.execute()` 已统一调用
  `execute_queue_command()`；调用方仍保留原 `live_binding_fence()` checkpoint、
  ambiguity 分类和 manager progress 提交顺序。当前 executor 内 direct
  `cmq.execute()` 只剩 helper 内部一处，兼容入口尚未替换为 `execute_observed()`。
- `rdma_queue_lifecycle_test` 与 `rdma_queue_recovery_test` 在 53 机均 rc=0、PROCESS/
  LOGICAL PASS，UVM 均为 `INFO=3/WARNING=0/ERROR=0/FATAL=0`；changed-SV style、
  `git diff --check`、queue/profile 门禁通过。详见
  `task-cmq-batch137-create-destroy-legacy-execution-seam-report.md`。

### Batch138 当前更新（2026-09-22）

- `rdma_control_plane.sv` 新增 `execute_control_command()`，把
  `rollback_mr_creation()`、`deregister_mr()` 的 OCC_FLUSH/MR_DEREGISTER/TQ_FLUSH
  以及 `execute_recovery_hardware_step()` 的五处同构 legacy `cmq.execute()` 结果
  归一化收束到单一入口；helper 清空本次 ticket/completion，克隆 status，并对空 CMQ
  或空 command fail-closed。调用方原有 timeout、ticket、generation fence、恢复记录、
  ACTIVE 回滚和资源释放顺序不变。
- KEY_ALLOC 因成功 status 对象和 timeout→recovery/rollback 分支特殊保留 direct 路径；
  因此 control-plane/QP consumer direct call 从 Batch137 边界的 11 降为 6（KEY_ALLOC
  1、QP lifecycle 5），helper 内兼容调用不计入 consumer 数。该批仍未切换
  `execute_observed()`，ticket/completion alias 与 `last_execute_no_submit_proven` 仍开放。
- `rdma_control_plane_cmq_engine_test`、`rdma_control_plane_test` 在 53 机均
  compile/elab/link、PROCESS/LOGICAL PASS，UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0`；
  `git diff --check`、changed-SV style、queue/profile 和 Python 292 门禁通过。详见
  `task-cmq-batch138-control-plane-legacy-execution-seam-report.md`。

### Batch139 当前更新（2026-09-22）

- `rdma_qp_lifecycle_executor.sv` 新增 `execute_qp_legacy_command()`，仅收束 raw
  legacy dispatch 的 ticket/completion/status 初始化、CMQ/command guard 和一次
  `cmq.execute()`；presence/query、QPC_CREATE、QPC_MODIFY、recovery query 与 terminal
  rollback 的 pre/post fence、ambiguity、completion、timeout 和 recovery 分支均留在
  原调用点。QP 文件 direct legacy dispatch 只剩 helper 内一处。
- `rdma_qp_lifecycle_test` 与 `rdma_qp_recovery_test` 在 53 机最终源码边界均
  compile/elab/link、PROCESS/LOGICAL PASS，UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0`；
  `git diff --check`、changed-SV style、queue/profile 和 Python 292 门禁通过。详见
  `task-cmq-batch139-qp-legacy-execution-seam-report.md`。
- 跨 queue/control-plane/QP 三类 consumer 当前只剩 control-plane KEY_ALLOC 一处
  direct consumer call；三个 helper 内各保留一次兼容 dispatch。该计数不表示
  `execute_observed()`、detached ticket/completion ownership 或 legacy accessor 已删除。

### Batch140 当前更新（2026-09-22）

- control-plane 的 KEY_ALLOC 已通过 `execute_control_command()` 的兼容入口收束；其
  raw status identity、CMQ/command guard、ticket/completion 初始化和单次 legacy dispatch
  均保留，原有 timeout ticket、recovery/rollback 和 generation 顺序不变。Batch141
  随后把 raw status 与 detached status 拆成两个显式 seam，不再依赖隐含的布尔 ownership
  选择。
- 至此 queue lifecycle、control-plane、QP lifecycle 三个 consumer 文件不再含 direct
  `cmq.execute()` call site；每个文件只在兼容 helper 内保留一次 raw dispatch。该结构
  去重仍不等于 `execute_observed()` 或 detached ticket/completion ownership 迁移。
- `rdma_control_plane_cmq_engine_test` 与 `rdma_control_plane_test` 在 53 机最终源码边界
  均 compile/elab/link、PROCESS/LOGICAL PASS，UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0`；
  `git diff --check`、changed-SV style、queue/profile 和 Python 292 门禁通过。详见
  `task-cmq-batch140-key-alloc-legacy-execution-seam-report.md`。

### Batch141 当前更新（2026-09-22）

- `rdma_control_plane.sv`（源码 SHA-256
  `c50b305eb0a3da0489870c3496056fe381f0cf7248fd5956149befd7947de0b5`）将一次 raw legacy dispatch 收束为
  `execute_control_command_raw_status()`：它负责 CMQ/command fail-closed guard、
  ticket/completion 初始化和 backend 原始 status identity；
  `execute_control_command()` 复用该 seam，再以 `checked_status()` 生成 detached status，
  供 MR rollback、deregister 和 recovery hardware-step 使用。KEY_ALLOC 显式调用 raw
  seam，并在调用点保留 null-status 归一化、timeout ticket、recovery/rollback 和
  generation 检查；dispatch 次数、失败优先级和资源提交顺序不变。
- `rdma_control_plane_cmq_engine_test` 与 `rdma_control_plane_test` 在 53 机最终源码边界
  均 compile/elab/link、PROCESS/LOGICAL PASS，UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0`；
  `git diff --check`、changed-SV style、profile naming、queue lifecycle 与 Python
  292 门禁通过。该批只澄清 raw/detached status ownership，不迁移
  `execute_observed()` 或 detached ticket/completion ownership；legacy descriptor、
  跨组件并发和更广 parent/core/integration regression 仍开放。详见
  `task-cmq-batch141-control-status-ownership-seam-report.md`。

### Batch142 当前更新（2026-09-22）

- Batch142 边界的 `rdma_queue_data_engine.sv`（源码 SHA-256
  `b651f42066610ad7bdc844b1094e2a5471199648f9510710f06e814fe83d5876`）将 AEQE reservation 前的 clone、live primary-route
  authority、profile owner、registry/type 检查、codec encode 和固定 16-byte image 校验
  收束到 `prepare_aeqe_publish_image()`；失败时清空 `encode_model`/`image`，不触碰
  attachment、runtime、cursor、backing、pending、Host-memory 或 MMIO。caller 继续
  负责 reservation 后 epoch/polarity、cancel/recovery 与 commit，CQE/CEQE 的
  reserve-before-encode 语义不变。
- `rdma_queue_data_engine_device_publish_test`（UVM INFO 220）、`rdma_aeqe_route_test`
  （INFO 3）、`rdma_aeqe_f5_e2e_test`（INFO 115）和
  `rdma_queue_event_route_consume_test`（INFO 3）均在 53 机 compile/elab/link、
  PROCESS/LOGICAL PASS，WARNING/ERROR/FATAL 全为 0；changed-SV style、diff、profile、
  queue lifecycle 与 Python 292 门禁同样通过。Batch142 自身源码边界的全目录 scanner
  为 185 `.sv`、2 `.svh`、5,436 methods（`.sv` 5,434、`.svh` 2）、0 diagnostics；
  Batch143 helper 加入后才刷新为当前最终边界的 5,437 methods（`.sv` 5,435、`.svh` 2）。
  该批只关闭 AEQE image staging 的局部职责 seam；malformed retry、poll/recovery 组合、
  SRQ 全生命周期、legacy descriptor、跨队列并发和 registry null/type-fault 原子性证据
  仍 OPEN。详见 `task-cmq-batch142-aeqe-image-staging-report.md`。

### Batch143 当前更新（2026-09-22）

- Batch143 边界的 `rdma_queue_data_engine.sv`（源码 SHA-256
  `20b260200fb20c41074678cfe48c27c2a628fce1988d6ef70867ef2d5754f6ab`）将
  `poll_ceqe_once()` 与 `poll_aeqe_once()` 在 image decode、owner/route 解析和 detached
  result candidate 之后重复的 `prepare_consumer_pending()`→`prepare_consumer_doorbell()`
  尾段提取为 `prepare_event_poll_continuation()`。CEQ 的 `route_found` 与 AEQ 的
  `deliver_found` 仍由 caller 决定 payload 是否交付，route miss 仍确认事件但丢弃
  payload；首次 `enter_recovery_prepared()` 与 `commit_event_poll_candidate()` 的顺序
  不变。
- helper 只做 detached pending/doorbell/noalloc-status staging，不执行 attachment lookup、
  peek/read/decode/route/result clone，不写 Host-memory/MMIO，不推进 CI/used，也不建立
  recovery evidence；两条入口仍由 `commit_event_poll_candidate()` 统一承担 runtime
  mutation 与 consumer commit。`rdma_queue_event_route_consume_test` 和
  `rdma_aeqe_route_test` 在 53 机最终源码边界均 compile/elab/link、PROCESS/LOGICAL PASS，
  UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0`。
- `rdma_queue_data_engine_final_fix_test` 不在当前 core factory/manifest 中；其无效入口只
  产生预期的 UVM `INVTST`，未计入 Batch143 源码验证结果。`git diff --check`、changed-SV
  style、profile naming、queue lifecycle checker 与 Python 292/292 均通过；全目录 scanner
  当前为 185 `.sv`、2 `.svh`、5,437 methods（`.sv` 5,435、`.svh` 2）、0 diagnostics。
  CEQ/AEQ malformed retry、doorbell-failure recovery exactly-once、CQ→WQ release、SRQ 全
  生命周期、legacy descriptor、跨队列并发、engine-level 全局锁和最终 ownership 审计仍
  OPEN，计划继续保持 `active`。详见 `task-cmq-batch143-event-preparation-seam-report.md`。

### Batch144 当前更新（2026-09-22）

- Batch144 边界的 `rdma_queue_data_engine.sv`（源码 SHA-256
  `1dfe2bf1038d2fe847e801e4f5eaad837b649c00f0efd9733427b5c448af7388`）将
  `post_send()` 与 `post_recv()` 在 producer reservation、model encode 以及 SQ 专属
  `write_sgb_and_verify()`（仅发送路径）之后重复的 WQE write/readback、next cursor、
  producer doorbell、ledger commit、detached result 和 recovery pending 尾段提取为
  `complete_host_producer_tail()`。
- helper 按固定顺序调用 `write_and_verify()`、`submit_producer_doorbell()` 和
  `attachment.runtime.commit_producer()`；写回/读回失败保留 `NO_SUBMIT` pending，
  doorbell/commit 失败保留 `AMBIGUOUS` evidence，pending clone 失败返回
  `RESOURCE_EXHAUSTED`，recovery 返回值不覆盖首个阶段 status。helper 不取得 queue、
  backing、request 或 handle 的外部生命周期所有权。
- 该 task 接收 caller 冻结的 attachment、queue handle、runtime kind、cursor、image、
  semantic request、`wr_id`/`signaled`、可选 SQ doorbell image 和 local id；它不重新
  执行 reservation/authority/route-epoch admission。`post_recv()` 的显式 attachment
  route/epoch 检查仍在 helper 之前；`post_send()` 的独立 route/epoch 复核不在本批新增，
  不能把 helper precondition 当作已完成 gate。`rdma_queue_data_engine_post_test`、
  `rdma_queue_data_engine_recovery_test` 和 `rdma_queue_data_engine_poll_test` 在 53 机
  最终源码边界均 compile/elab/link、PROCESS/LOGICAL PASS，UVM
  `INFO=3/WARNING=0/ERROR=0/FATAL=0`。
- changed-SV style、`git diff --check`、profile naming、queue lifecycle、Phase-1A 和
  Python 292/292 均通过；全目录 scanner 当前为 185 `.sv`、2 `.svh`、5,438 methods
  （`.sv` 5,436、`.svh` 2）、0 diagnostics。WQE/doorbell/commit hostile 组合、SRQ 全
  生命周期、legacy descriptor、跨队列并发、engine-level 全局锁和最终 ownership 审计仍
  OPEN，计划继续保持 `active`。详见
  `task-cmq-batch144-host-producer-tail-report.md`。

### Batch145 当前更新（2026-09-22）

- Batch145 最终边界的 `rdma_queue_data_engine.sv` SHA-256 为
  `dde548fb979c0dd1e694651031edc2acb469766e57d2d9f221673001016bb431`。新增的
  `reserve_host_producer_cursor()` 在任何 producer reservation 之前统一执行
  attachment route/epoch 校验，再取得 detached producer cursor；`post_send()` 与
  `post_recv()` 保留各自 request/owner/SRQ authority 顺序，只共享这段无
  Host-memory/MMIO/ledger 副作用的 admission。
- `rdma_queue_data_engine_post_test` 的 send stale-epoch fixture 先推进 binding epoch，
  再调用 direct `post_send()`，确认返回 `RDMA_SC_STALE_GENERATION`，result、SQ
  cursor、used/pending、Host-memory 和 PCIe 调用计数均不变。post/recovery/poll 三项
  focused 在 53 机均 PROCESS/LOGICAL PASS、UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0`；
  device-publish 同样 PASS、UVM `INFO=220/WARNING=0/ERROR=0/FATAL=0`。
- changed-SV style、`git diff --check`、profile naming、queue lifecycle、Phase-1A 和
  Python 292/292 均通过；全目录 scanner 当前为 185 `.sv`、2 `.svh`、5,440 methods
  （`.sv` 5,438、`.svh` 2）、0 diagnostics。该批只关闭 direct send stale-epoch
  admission seam，不宣称 reservation 后 route 变化窗口、host-producer hostile fault
  matrix、SRQ 全生命周期、跨队列并发或最终 ownership 审计已完成。详见
  `task-cmq-batch145-host-producer-admission-report.md`。

### Batch123 当前更新

- queue-data attachment/recovery 追加 `validate_consumer_recovery_authority()` 只读
  preflight：pending shape、route/epoch、CQ completion target、QP identity、SQ/RQ/SRQ
  route、WQ attachment 和 release range；`replay_consumer_pending()` 继续负责所有
  shadow/doorbell、CQ commit、CQ→WQ release 与 completion 副作用。
- 当前状态：device-publish/recovery/post 三套 VCS53 均 PROCESS/LOGICAL PASS、UVM
  0/0/0；style/diff/queue/profile/manifest/keyword/Phase-1A/Python 门禁 GREEN；逐文件
  method scanner 为 140/122，全目录为 185 `.sv`、2 `.svh`、5,407 methods、0 diagnostics。
- 该 helper 只读且不形成 engine-level 全局原子锁；CQ→WQ 跨队列、CEQ/AEQ malformed
  retry、SRQ 全量 lifecycle、device+consumer 组合和最终 ownership 审计仍 OPEN。

### Batch124 当前更新

- queue-data attachment/recovery 追加 recovery-only `release_consumer_pending_wqe()`：统一
  `begin_consumer_release_noalloc()`、以 pending 冻结 completion index/wrap 调用
  `release_cq_wqe()`、null-status 归一化、`finish_consumer_release_noalloc()` 与失败
  recovery evidence；`replay_consumer_pending()` 仍保留 authority、shadow/doorbell、CQ
  commit 与 completion，poll 路径继续使用独立 live-CQE 契约。
- 当前状态：device-publish/recovery/post 三套 VCS53 均 PROCESS/LOGICAL PASS、UVM
  0/0/0；style/diff/queue/profile/manifest/keyword/Phase-1A/Python 门禁 GREEN；逐文件
  method scanner 为 141/122，全目录为 185 `.sv`、2 `.svh`、5,408 methods、0 diagnostics。
- seam 仅收束 recovery 的 CQ→WQ 双边 gate，不形成 engine-level 全局锁，也不宣称
  poll/recovery 全阶段组合、CQ→WQ 跨队列并发、CEQ/AEQ malformed retry、SRQ 全量
  lifecycle、device+consumer 组合或最终 ownership 审计已关闭。

### Batch125 当前更新

- queue-data attachment/recovery 追加 `stage_cq_poll_candidate()`：集中 WQ route/release
  snapshot、completion/result/pending、next cursor 和 shadow/doorbell preparation；
  function 不 admission、不提交 cursor、不执行 MMIO，`poll_cqe_once()` 保留首个
  `enter_recovery_prepared()` mutation 及后续 shadow→commit→release 顺序，并在 caller
  对 WQ output 做完整 QP/SRQ incarnation relookup/校验。
- 当前状态：poll/device-publish/recovery/post 四套 VCS53 均 PROCESS/LOGICAL PASS、UVM
  0/0/0；style/diff/queue/profile/manifest/keyword/Phase-1A/Python 门禁 GREEN；逐文件
  method scanner 为 142/122，全目录为 185 `.sv`、2 `.svh`、5,409 methods、0 diagnostics。
- RQ/SRQ 与 UD 正向 poll、当前入口不可达的 legacy descriptor 分支、engine-level 全局锁、
  poll/recovery 全阶段组合、CQ→WQ 跨队列并发和最终 ownership 审计仍 OPEN。

### Batch126 当前更新

- queue-data poll 追加只读 `resolve_cq_poll_wq_target()`：按冻结 CQE receive 标志和
  QP link 统一选择 SQ、私有 RQ 或共享 SRQ，校验完整 handle incarnation、runtime/access、
  entry geometry、kind 与 backing role；该 helper 不 reserve/snapshot ledger、不进入
  pending、不写 Host-memory/MMIO。`stage_cq_poll_candidate()` 继续负责 detached
  preparation，`poll_cqe_once()` 继续保留 simulator 兼容的完整 relookup、首个
  `enter_recovery_prepared()` mutation 以及 shadow/doorbell→CQ commit→CQ→WQ release
  顺序。
- 当前 poll/post/recovery/device-publish 四项 wrapper 均在最终源码边界 PROCESS/LOGICAL
  PASS、UVM 0/0/0；style/diff/queue/profile/manifest/keyword/Phase-1A/Python 与全目录
  scanner GREEN，`git diff --check` 通过。RQ/SRQ 与 UD 正向 poll 端到端矩阵、legacy
  descriptor branch、CQ route/epoch admission、engine-level 全局锁、poll/recovery 组合、
  CQ→WQ 跨队列并发和最终 ownership 审计仍 OPEN。

### Batch127 当前更新

- queue-data poll 追加受保护 `commit_cq_poll_candidate()`：把 live-CQE 的
  `enter_recovery_prepared()`、CQC shadow/legacy doorbell、MMIO evidence、CQ consumer
  commit、CQ→WQ bilateral release gate、recovery completion 与最终 result publish 收束在
  一个顺序明确的 task。`poll_cqe_once()` 继续独占 occupancy/read/decode/route、detached
  staging 和 admission 前的 WQ identity relookup；该 task 不重新解析可变 CQE/route，也
  不与 Batch124 的 frozen-recovery release helper 合并。
- 四项 queue-data wrapper 均在最终源码边界 PROCESS/LOGICAL PASS、UVM 0/0/0；全目录
  scanner 为 185 个 `.sv`、2 个 `.svh`、5,411 个 function/task，0 diagnostics；style/diff、
  queue/profile、manifest/keyword、Phase-1A 与 Python 292 门禁 GREEN。shadow publication
  的 null status 仍由外层 `poll_cqe` wrapper 归一化；RQ/SRQ 与 UD 正向 poll、poll/recovery
  全阶段组合、engine-level 全局锁、CQ→WQ 跨队列并发和最终 ownership 审计仍 OPEN。

### Batch128 当前更新

- queue-data event poll 追加受保护 `commit_event_poll_candidate()`：CEQ/AEQ caller 在
  各自完成 image decode、route/secondary-owner 解析、detached result 与 pending/doorbell
  preparation 后，共用 admission→consumer doorbell→MMIO evidence→CI commit→recovery
  completion→result publish 的单向 task；route miss 仍确认 ring entry 但丢弃 payload，
  CQ 专用 WQE release 不进入该 helper。
- `rdma_queue_data_engine_poll_test`、`rdma_queue_event_route_consume_test`、
  `rdma_aeqe_route_test` 与 `rdma_aeqe_f5_e2e_test` 在最终源码边界 PROCESS/LOGICAL PASS、
  UVM 0/0/0；Batch128 仍不覆盖 RQ/SRQ/UD 正向 poll 全矩阵、legacy descriptor、CEQ/AEQ
  malformed retry 或 staged WQ 二次 geometry/role hostile fixture。计划继续保持 `active`。

### Batch129 当前更新

- queue-data poll 将 WQ target contract 拆为只读
  `select_cq_poll_wq_target_contract()` 与共享 `validate_cq_poll_wq_attachment()`：
  selector 依据冻结 `cqe.rq_cqe` 和 `link` 推导唯一 target handle/runtime kind/backing
  role，不读取 `pending.completion_wq_kind`；validator 统一检查 resource kind、
  runtime/access、depth、`RDMA_WQE_BYTES` entry geometry、kind/role 与完整 handle
  incarnation。`resolve_cq_poll_wq_target()` 采用 selector→lookup→validator，
  `poll_cqe_once()` 在 `enter_recovery_prepared()` 前拒绝 pending kind 漂移；resolver 和
  poll admission 对 selector output 的 null/错误 incarnation 都按冻结 link 回填 canonical
  handle，再以同一 target contract 做 validator/relookup；不新增 runtime、ledger、Host-memory、
  MMIO 或生命周期所有权。
- 新增 poll test-only probe 覆盖正常 SQ、depth=0、entry-size=32、错误 role 和 stale
  generation 五类 validator 结果；生产路径已有 selector-output canonicalize 与 staged
  attachment fallback，但该 probe 尚未强制完整 `poll_cqe_once()` hostile staged-output
  分支。当前 `rdma_queue_data_engine_poll_test`、
  `rdma_queue_data_engine_post_test`、`rdma_queue_data_engine_recovery_test` 已
  PROCESS/LOGICAL PASS、UVM 0/0/0，changed-SV style 与 `git diff --check` 通过；
  `rdma_queue_data_engine_device_publish_test` 也 PROCESS/LOGICAL PASS、UVM 0/0/0；
  全目录 scanner 覆盖 185 个 `.sv`、2 个 `.svh`（187 files），5,416 methods（`.sv` 5,414、
  `.svh` 2），0 diagnostics，manifest 22/22、SV keyword 3/3、queue/profile/Phase-1A、
  changed-SV style、`git diff --check` 与 Python 292 均通过，计划继续保持 `active`。
- 已知边界：selector 通过 `output rdma_handle` 跨 function 传递 class handle，VCS53 当前
  focused 通过但 simulator handle 保真性仍待独立证据；probe CQE 未设置 `cqe.qp_h`（target
  authority 仍由冻结 wire-QPN/CQ-route 上游 link 提供）；`stage_cq_poll_candidate()` 的
  snapshot 发生在二次 validator 之前，未来需审计错误 runtime/同 metadata alias。

### Batch130 当前更新

- `rdma_queue_data_engine_poll_test` 新增私有 RQ 正向 receive CQE fixture：
  `make_cqe_for_outstanding_receive()` 显式设置 `rq_cqe=1`、
  `RDMA_CQE_VARIANT_RQ_SRFQ`、`rqe_cpl=1` 以及冻结的 QPN/WQE index+wrap；
  `check_private_rq_receive_cqe_e2e()` 通过公开 `post_recv`→`publish_cqe`→`poll_cqe`
  链路验证 `RDMA_WR_RECV`、`wr_id`、单个 released slot、RQ/SQ/CQ occupancy、RQ/CQ
  producer-consumer cursor 收敛及第二次 `RDMA_SC_QUEUE_EMPTY`。本批只增补测试和证据，
  未修改生产 queue-data engine，也不把 detached `byte_len` 软件字段误当成 wire payload
  断言；RQ overlay 以 `rqe_cpl` 和显式 variant 保真为边界。
- `rdma_queue_data_engine_poll_test`、`rdma_queue_data_engine_post_test`、
  `rdma_queue_data_engine_recovery_test`、`rdma_queue_data_engine_device_publish_test`
  均在当前源码边界 PROCESS/LOGICAL PASS、UVM 0/0/0；changed-SV style、
  `git diff --check`、queue/profile/manifest/keyword/Phase-1A/Python 292 与全目录
  scanner（185 `.sv`+2 `.svh`、5,418 methods/0 diagnostics）GREEN。
- 本批关闭“私有 RQ 正向 receive poll 缺少公开端到端证据”的窄 seam；SRQ/UD 正向 poll、
  legacy descriptor、hostile staged/recovery 组合、CQ→WQ 跨队列并发、engine-level
  全局锁、snapshot alias 与最终 ownership 审计仍 OPEN，计划继续保持 `active`。

### Batch131 当前更新

- `rdma_queue_data_engine.sv` 新增只读 `canonicalize_cq_poll_wq_attachment()`，将
  `poll_cqe_once()` admission 前的冻结 target 选择、pending kind 一致性、WQ
  geometry/role/incarnation validator 与 detached staged alias 的 canonical relookup
  收束为单一职责阶段。失败路径不建立 pending，不推进 cursor/ledger，不写
  Host-memory 或 MMIO；首次 `enter_recovery_prepared()`、doorbell、CQ commit 与
  CQ→WQ release 顺序保持不变。
- `rdma_queue_data_engine_probe` 增加六类 detached hostile alias/pending-kind probe，
  覆盖 null、entry-size、backing-role、runtime-depth、stale-generation 回查成功和
  pending kind 漂移 fail-closed；`rdma_queue_data_engine_poll_test` 新增
  `make_cqe_for_outstanding_ud_send()` 与 `check_ud_send_cqe_e2e()`，经公开
  `post_send`→`publish_cqe`→`poll_cqe` 验证 `RDMA_CQE_VARIANT_UD`、source-QPN、
  SMAC/VLAN overlay、SQ/CQ release、RQ 不变及二次 `RDMA_SC_QUEUE_EMPTY`。
- 四项 queue-data wrapper 在最终源码边界均 PROCESS/LOGICAL PASS、UVM 0/0/0；
  changed-SV style、`git diff --check`、queue/profile/manifest/keyword/Phase-1A、
  Python 292 与全目录 scanner（185 `.sv`、2 `.svh`、5,422 methods、0 diagnostics）
  GREEN。该批关闭 staged WQ canonicalization 的局部 admission seam，并取得 UD SEND
  单路径正向证据；SRQ 正向 poll、UD receive/replay、legacy descriptor、poll/recovery
  全阶段组合、CQ→WQ 跨队列并发、engine-level 全局锁、snapshot 后 alias 与最终
  ownership 审计仍 OPEN，计划继续保持 `active`。

### Batch133 当前更新

- queue-data engine 新增 `resolve_cqe_variant_for_route()`、
  `validate_cqe_srfq_route_consistency()` 与 `validate_cqe_variant_consistency()`。
  `publish_cqe()` 在 WQE lookup/producer reservation 前以冻结 QP link 的 transport
  和 SRQ presence 做 variant/SRFQ admission；`resolve_cqe_variant_for_image()` 在
  poll decode 前复用同一 topology gate。CQ attachment transport 不再被用来猜测
  共享 CQ 上交错的 RC/UD/URC QP overlay。
- focused poll/device-publish/post/recovery 四项 wrapper 在当前生产边界均
  PROCESS/LOGICAL PASS、UVM 0/0/0。publish hostile case 验证 private-RQ/shared-SRQ
  SRFQ mismatch、RC/UD variant mismatch 的 reservation 前原子拒绝；shared-SRQ poll
  再用 test-only probe 在已提交槽位只翻转 SRFQ wire bit，验证 poll-side rejection
  在 image decode 前保持 SRQ/CQ occupancy、cursor 与 result 不变，恢复原像后继续
  合法 poll。该证据只覆盖 shared-SRQ receive 的窄注入，不代表 private-RQ poll 或
  全量 malformed matrix 已闭合。
- transport E2E 在锁定 `DPU_COMMON_ROOT`、`HOST_MEM_ROOT`、`NET_PACKET_ROOT` 后，
  通过 CQC shadow-enabled composition setup 和 RC/UD/URC 正向矩阵；URC READ 由
  核心语义层允许、net_packet wire capability 层按 `RDMA_SC_UNSUPPORTED_OPCODE`
  拒绝，测试按分层契约检查，不修改外部依赖。若外部 preflight 再次漂移，只记录原始
  阻断，不把它冒充业务 GREEN。
- 本批关闭 publish/poll 共用 variant/SRFQ authority 的局部 admission seam，并补齐
  shared-SRQ poll-side malformed image 的窄注入证据；UD receive/replay、private-RQ
  poll hostile、legacy descriptor、全量 malformed matrix、poll/recovery 组合、CQ→WQ
  跨队列并发、engine-level 全局锁、SRQ 全量 lifecycle、snapshot 后 alias 与最终
  ownership 审计仍开放，计划继续保持 `active`。

## 证据索引

- 每批 focused 说明与 source/archive/log SHA 位于
  `.superpowers/sdd/2026-09-17-rdma-structural-refactor/task-cmq-batch*-*.md` 和
  对应 `evidence/batch*` 文件。
- 最新 Batch86 parent gate 见 `evidence/batch86.meta`；Batch87–93 的 authority、runtime、
  recovery、环境组合、SQ payload 和 poison 边界见 `evidence/batch87.meta` 至
  `evidence/batch93.meta` 及各自 artifact 清单/报告。Batch94–99 的 focused 证据、
  源码指纹和失败边界见 `evidence/batch97.*`、`evidence/batch98.*`、`evidence/batch99.*`
  及 `task-cmq-batch94*` 至 `task-cmq-batch99*` 报告。
- Batch100 的 RC inline-SGB capacity ABI 锚点、3 个 focused 日志和静态检查位于
  `.superpowers/sdd/2026-09-14-rdma-phase1c-abi-fixes/evidence/batch100-*`，报告为
  `task-cmq-batch100-phase1c-f2-report.md`；它只关闭本地容量拒绝缺口，不代表 Phase 1C F2
  全部收口。
- Batch101 的跨 context reset prepare/commit 日志和 artifact 指纹位于
  `evidence/batch101.*`，Batch102 的 QP/queue lifecycle alias 审计及静态检查位于
  `evidence/batch102.*`；两批报告分别为 `task-cmq-batch101-reset-atomicity-report.md`
  和 `task-cmq-batch102-qp-alias-audit-report.md`。Batch103 focused follow-up 与 Batch104
  current-source parent/core gate 日志位于 `evidence/batch103-*`、`evidence/batch104-*`。
- 历史静态证据索引位于 `evidence/final-static.meta`、`final-static-artifact-sha256.txt`、
  `final-static-python.log`、`final-static-cmq-manifest.log`、`final-static-style.log`、
  `final-static-diff-check.log`、`final-static-contract-scan.log` 和
  `final-static-rdma_defs.log`；这些路径记录早期批次，不能代表 Batch156 当前工作树。
  历史 final-static scanner 覆盖 185 个 `.sv`、2 个 `.svh`、
  5,286 个 function/task，0 diagnostics；Batch109 报告中的 5,346 是其当时的旧扫描口径，
  Batch110 当时工作树以同一 API 重新计数为 5,382 个、0 diagnostics。冻结 ABI manifest
  的摘要更新只反映对应记录边界的源码字节，未改变 wire 坐标或外部依赖；Batch111
  capability 改动后的 scanner 已重计为 5,387 个 function/task、0 diagnostics，详见
  `evidence/batch111.*`；
  Batch155 的 5,467-method 历史结果见
  `task-cmq-batch155-eq-facade-operation-envelope-report.md`；Batch156 当前 5,469-method/
  0-diagnostic 结果及复现口径见
  `task-cmq-batch156-cq-facade-operation-envelope-report.md`；Batch157 当前 5,483-method/
  0-diagnostic 结果、VCS wrapper hash 和 factory atomicity 证据见
  `task-cmq-batch157-cq-shadow-replay-atomicity-report.md`；Batch158 当前 5,485-method/
  0-diagnostic 结果与 device-publish focused 证据见
  `task-cmq-batch158-device-publish-admission-report.md`；Batch159 当前 5,488-method/
  0-diagnostic 结果与 shared transport envelope decode 证据见
  `task-cmq-batch159-transport-envelope-decode-report.md`。
- `pcie_work` 的正确 suite 阻断证据是
  `evidence/post-batch87-rdma_sriov_pcie_work-correct-blocked.log`；`rc=2` 只表示
  `external dependency is not approved: pcie_work`，不是 UVM 业务失败。
- Batch105 candidate-integrity 的源码刷新与 Batch106 reset-coordinator lifecycle focused
  证据分别见 `task-cmq-batch105-reset-candidate-integrity-report.md`、
  `evidence/batch105.meta`/`batch105-artifact-sha256.txt` 和
  `task-cmq-batch106-reset-coordinator-lifecycle-report.md`、`evidence/batch106.meta`/
  `batch106-artifact-sha256.txt`；报告中的日志和 source SHA 必须属于同一当前工作树边界。
- Batch107 reset-incarnation refresh、当前 integration/CMQ/core regression 与静态门禁见
  `task-cmq-batch107-reset-incarnation-refresh-report.md`、`evidence/batch107.meta`、
  `evidence/batch107-artifact-sha256.txt`、`evidence/batch107-rdma_reset_coordinator_lifecycle_test.log`、
  `evidence/batch107-integration-regression.log`、`evidence/batch107-cmq-gate-regression.log`
  和 `evidence/batch107-core-regression.log`；这些日志与当前源码边界对应。
- Batch108 的 coordinator ownership / transaction 只读审计与下一批契约决策见
  `task-cmq-batch108-coordinator-ownership-audit.md`；它不代表新增源码或 GREEN 验证。
- Batch109 的一对一 coordinator lease、bilateral detach/close、capability handshake 和
  candidate provenance seal 见 `task-cmq-batch109-coordinator-ownership-and-close-report.md`；
  当前 integration 10/10、focused seams 和最终静态门禁必须与 Batch109 源码指纹对应，不能
  复用 Batch107 的旧日志。
- Batch110 的同步 publication guard、生命周期 fixture 修正与当前源码全量验证见
  `task-cmq-batch110-reset-publication-guard-report.md`；对应日志为
  `evidence/batch110-rdma_reset_coordinator_lifecycle_test.log`、
  `evidence/batch110-integration-regression.log`、`evidence/batch110-cmq-gate-regression.log`、
  `evidence/batch110-core-regression.log` 及 `evidence/batch110-contract-scan.log`。本批
  scanner 重新计数为 5,382 个 function/task、0 diagnostics，不能继续沿用 5,346/5,371
  的旧口径。
- Batch111 的 coordinator mutation guard、legacy Host epoch capability seal 与 lifecycle
  fixture 见 `task-cmq-batch111-reset-mutation-guard-report.md`；当前源码的 focused、
  integration、CMQ、core、Python、`rdma_defs` 与全量静态/hash 日志均冻结在
  `evidence/batch111.*`，其中 core 为 95/95 process、78/78 logical，scanner 为 5,387
  methods/0 diagnostics。不能使用错误 worktree 的旧 core 编译日志。
- Batch113 的 SQ SGB writer authority 说明见 `task-cmq-batch113-sgb-writer-authority-report.md`；
  focused post/codec 结果由本批报告记录。它只覆盖首次 Host-memory write 前的
  mode/count、descriptor packing 和 signature gate，不替代 UD transport-aware mode
  的后续 focused 证据。
- Batch114 的 UD effective-mode 修复与 focused 证据见
  `task-cmq-batch114-ud-sgb-effective-mode-report.md`；该批确认共享 resolver 与
  writer/codec 对齐，但不替代完整公开 `post_send()`/`replay_pending()` 矩阵。
- Batch115 的 receive target-resolution 提取、公开 UD 正向/恢复探针和当前
  `rdma_queue_data_engine_post_test`/`rdma_queue_data_engine_recovery_test` 证据见
  `task-cmq-batch115-receive-target-resolution-report.md`；临时公开 UD probe 已在
  验证后删除，仅保留报告中的可复核结果，不把它当作长期测试入口。
- Batch116 的 host-producer recovery task 提取、null-status fail-closed 处理和当前
  `rdma_queue_data_engine_recovery_test`/`rdma_queue_data_engine_post_test` 证据见
  `task-cmq-batch116-host-producer-recovery-report.md`；本批只重排 recovery 阶段职责，
  不把 producer helper 的 focused GREEN 扩大解释为 SRQ 全生命周期或广义 F2 完成。
- Batch117 的 claimed recovery attachment 只读扫描、unclaimed handoff 保序和当前
  `rdma_queue_data_engine_device_publish_test`/`rdma_queue_data_engine_recovery_test`/
  `rdma_queue_data_engine_post_test` 证据见
  `task-cmq-batch117-claimed-recovery-scan-report.md`；本批不把 candidate 定位 helper
  的 focused GREEN 扩大解释为 reservation-only、SRQ 全生命周期或广义 F2 完成。
- Batch118 的 reservation-only candidate collection、caller 保序和当前
  `rdma_queue_data_engine_device_publish_test`/`rdma_queue_data_engine_recovery_test`/
  `rdma_queue_data_engine_post_test`、style/diff、queue/profile/Python 门禁结果见
  `task-cmq-batch118-reservation-candidate-scan-report.md`；本批 helper 只收集借用引用，
  不判定 reservation、多匹配或 action 合法性，不把 focused GREEN 扩大解释为
  reservation contract、SRQ 全生命周期、跨队列并发或广义 F2 完成。
- Batch119 的 action/confirmation preflight、reservation cardinality、query-before-recover
  顺序和当前三套 queue-data VCS53 结果见
  `task-cmq-batch119-recovery-action-contract-report.md`；本批将 control-plane 拒绝点
  前移并保持全部 evidence/detach 保序，但不把局部 recovery contract GREEN 扩大解释为
  query/recover 原子并发、完整 SRQ/跨队列 lifecycle、device/consumer 全阶段或广义 F2
  完成。
- Batch120 的 device-producer recovery task 提取、当前 source/test 指纹和三套 queue-data
  VCS53 结果见 `task-cmq-batch120-device-producer-recovery-report.md`；本批只重排
  DEVICE_WRITE/readback/commit 的职责边界，不把 helper 的 focused GREEN 扩大解释为
  consumer recovery、完整 SRQ/跨队列 lifecycle、全局并发锁或广义 F2 完成。
- Batch121 的 consumer recovery task 提取、当前 source/test 指纹和三套 queue-data
  VCS53 结果见 `task-cmq-batch121-consumer-recovery-report.md`；本批只重排 CQ route、
  shadow/doorbell、consumer commit、CQ→WQ release 与 completion 的职责边界，不把
  helper 的 focused GREEN 扩大解释为 SRQ 全生命周期、跨队列并发、device/consumer
  组合 recovery、全局并发锁或广义 F2 完成。
- Batch122 的 local resource match scan、当前 source 指纹和 resource-manager/AEQE/
  recovery/post focused VCS53 结果见 `task-cmq-batch122-local-resource-match-scan-report.md`；
  本批只分离 registry 只读 cardinality 与 detached projection，不把 local lookup 的
  focused GREEN 扩大解释为 manager-level 并发、跨 incarnation lifecycle、完整 SRQ/
  跨队列 recovery 或广义 F2 完成。
- Batch123 的 consumer recovery authority preflight、当前 source/test 指纹、三套 queue-data
  VCS53 结果和静态门禁见 `task-cmq-batch123-consumer-authority-report.md`；本批只分离
  pending/route/QP/WQ/release 的只读 authority 查询，不把 helper 的 focused GREEN 扩大解释为
  engine-level 全局锁、CEQ/AEQ malformed retry 矩阵、SRQ/跨队列 lifecycle、device+consumer
  组合 recovery、全目录 ownership 审计或广义 F2 完成。
- Batch124 的 recovery-only CQ→WQ release seam、当前 source 指纹、三套 queue-data VCS53
  结果和静态门禁见 `task-cmq-batch124-consumer-release-report.md`；本批只收束
  begin/release/finish 与 failure evidence 的局部职责边界，不把 helper 的 focused GREEN
  扩大解释为 engine-level 全局锁、poll/recovery 全阶段组合、CQ→WQ 跨队列并发、
  CEQ/AEQ malformed retry、SRQ lifecycle、device+consumer 组合、全目录 ownership 审计
  或广义 F2 完成。
- Batch125 的 CQ poll candidate staging、当前 source 指纹、四套 queue-data VCS53 结果和
  静态门禁见 `task-cmq-batch125-poll-candidate-staging-report.md`；本批只分离
  pre-admission detached preparation，不把 helper 的 focused GREEN 扩大解释为 RQ/SRQ 或
  UD 正向 poll 全覆盖、legacy descriptor branch、engine-level 全局锁、poll/recovery
  组合、跨队列 lifecycle、全目录 ownership 审计或广义 F2 完成。
- Batch126 的 CQ poll completion target resolver、当前 source 指纹和 focused/静态门禁结果
  见 `task-cmq-batch126-poll-target-resolution-report.md`；本批只分离 SQ/RQ/SRQ target
  选择与 attachment authority 检查，不把 focused GREEN 扩大解释为 RQ/SRQ/UD 正向 poll
  全覆盖、CQ route/epoch admission、engine-level 全局锁、poll/recovery 组合、跨队列
  lifecycle、全目录 ownership 审计或广义 F2 完成。
- Batch128 的 CEQ/AEQ shared consumer commit seam、当前 source 指纹和 event/poll focused
  VCS53 结果见 `task-cmq-batch128-event-commit-candidate-report.md`；本批只收束事件队列
  consumer 副作用顺序，不把 focused GREEN 扩大解释为 CEQ/AEQ malformed retry、RQ/SRQ/UD
  正向 poll 全覆盖、staged WQ geometry/role 二次校验、engine-level 全局锁、跨队列
  lifecycle、全目录 ownership 审计或广义 F2 完成。
- Batch129 的 CQ poll WQ target selector/validator、当前 source/test 指纹和已完成的
  poll/post/recovery focused 结果见 `task-cmq-batch129-poll-wq-contract-report.md`；本批
  只收束冻结 target contract、attachment geometry/role/incarnation 校验与 staged-output
  canonical relookup，不把当前四项 focused GREEN 扩大解释为 RQ/SRQ/UD 正向 poll 全覆盖、
  selector class-handle simulator 保真性、RQ/SRQ/UD 正向 poll、跨队列并发、全量静态门禁
  或广义 F2 完成。
- Batch130 的私有 RQ receive CQE 正向 poll fixture、当前 source/test 指纹和四项
  queue-data focused 结果见 `task-cmq-batch130-private-rq-cqe-poll-report.md`；本批只
  关闭私有 RQ 的 `post_recv`→`publish_cqe(rq_cqe=1)`→`poll_cqe` 正向证据，不把它扩大
  解释为 SRQ/UD 正向 poll、legacy descriptor、hostile staged/recovery 组合、
  CQ→WQ 跨队列并发、engine-level 全局锁、全目录 ownership 审计或广义 F2 完成。
- Batch131 的 staged WQ canonicalization、当前 source/test 指纹、四项 queue-data
  focused 结果和静态门禁见 `task-cmq-batch131-poll-wq-canonicalization-report.md`；本批
  只收束 poll admission 前的 canonical attachment 校验，并补充 UD SEND 的
  `post_send`→`publish_cqe`→`poll_cqe` 单路径证据，不把它扩大解释为 SRQ 正向 poll、UD
  receive/replay、legacy descriptor、poll/recovery 全阶段组合、跨队列并发、engine-level
  全局锁、snapshot alias 或最终 ownership 审计。
- Batch132 的 shared-SRQ receive CQE 正向 poll fixture、当前 source/test 指纹、四项
  queue-data focused 结果和静态门禁见 `task-cmq-batch132-shared-srq-cqe-poll-report.md`；
  本批只补充真实 SRQ/QP route 的 `post_recv`→`publish_cqe(rq_cqe=1,srfq=1)`→`poll_cqe`
  单路径证据，并固定 `local_srq_id` 为 SRFQ wire ID，验证 SRQ ledger/cursor release
  与私有 RQ 不变；不把它扩大解释为 UD receive/replay、publish variant consistency、
  legacy descriptor、poll/recovery 全阶段组合、跨队列并发、engine-level 全局锁、snapshot
  alias 或最终 ownership 审计。
- Batch133 的 CQE variant/SRFQ topology gate、四项 focused VCS53 结果、shared-SRQ
  publish/poll hostile evidence、dual-env CQC shadow 修正和锁定依赖 transport E2E 结果见
  `task-cmq-batch133-cqe-variant-consistency-report.md`；该批关闭 publish/poll 共用的
  局部 authority seam，不替代 private-RQ hostile、UD receive/replay、legacy descriptor、
  全量 malformed matrix、poll/recovery 组合、跨队列并发或最终 ownership 审计。
- Batch141 的 raw/detached status ownership seam、control-plane focused VCS53 结果和
  source SHA 见 `task-cmq-batch141-control-status-ownership-seam-report.md`；该批只拆分
  legacy status identity，不把 compatibility helper 误报为 `execute_observed()` 迁移。
- Batch142 的 AEQE reservation 前 image staging、四项 queue-data focused VCS53 结果和
  source SHA 见 `task-cmq-batch142-aeqe-image-staging-report.md`；该批只收束可失败的
  detached preparation，不覆盖 malformed retry、SRQ lifecycle 或 registry fault 原子性。
- Batch143 的 CEQ/AEQ prepared-consumer continuation seam、两项 event-route focused
  VCS53 结果、最终源码 SHA 和 scanner 口径见
  `task-cmq-batch143-event-preparation-seam-report.md`；该批只收束
  `prepare_consumer_pending()`/`prepare_consumer_doorbell()` 的 detached staging，保留
  caller 的 route/delivery 判定与 `commit_event_poll_candidate()` mutation 边界，不覆盖
  malformed retry、doorbell-failure recovery exactly-once、SRQ lifecycle、跨队列并发或
  最终 ownership 审计。无效 `rdma_queue_data_engine_final_fix_test` 入口未计入结果。
- Batch144 的 SQ/RQ/SRQ host-producer completion tail、三项 post/recovery/poll focused
  VCS53 结果、最终源码 SHA 和 scanner 口径见
  `task-cmq-batch144-host-producer-tail-report.md`；该批只收束 reservation 后的
  write/readback、doorbell、producer commit、result/recovery 尾段，不新增
  reservation/authority/route-epoch admission；post_send 的独立 route/epoch 复核、
  hostile fault 组合、SRQ lifecycle、跨队列并发和最终 ownership 审计仍开放。
- Batch145 的 host-producer route/epoch admission 收缩、send stale-epoch fixture、四项
  focused VCS53 结果、最终源码 SHA 和 5,440-method scanner 口径见
  `task-cmq-batch145-host-producer-admission-report.md`；该批关闭 direct `post_send()`
  在 reservation 前缺少 route/epoch gate 的局部 seam，并统一 `post_send()`/
  `post_recv()` 的 route-check→reserve 编排，不覆盖 reservation 后 route 变化窗口、
  hostile producer fault matrix、SRQ 全生命周期、跨队列并发或最终 ownership 审计。
- Batch148 的 host-producer commit/recovery route 收缩、stale replay 与 ledger-commit
  hostile 证据见 `task-cmq-batch148-host-producer-commit-route-report.md`。本批把
  attachment route/epoch snapshot、reservation 后窄窗口复核、ledger commit、recovery
  admission/install 和 producer completion tail 收束为相邻 seam；WQE/readback、doorbell
  与 commit 的第一阶段失败 evidence 及 reservation 冻结 route/epoch 均保持不变。
  post/recovery/poll/device-publish/hostile-failure/commit-failure 六项 focused 在 53 机
  均 PROCESS/LOGICAL PASS，UVM INFO 为 `3/3/3/220/27/8`，WARNING/ERROR/FATAL 全 0；
  当前全目录 scanner 为 185 `.sv`、2 `.svh`、5,460 methods、0 diagnostics。该批仍不
  覆盖 reservation 后跨线程 route 变化、admission/enter-recovery failure matrix、SRQ
  全生命周期、跨队列并发、legacy descriptor、外部 PCIe error/ordering 组合、全局锁或
  最终 ownership 审计，计划继续保持 `active`。
- Batch149 的 reservation-only recovery seam 见
  `task-cmq-batch149-reservation-only-recovery-seam-report.md`。本批将
  `recover_queue()` found==null 分支中的 candidate query、multiple-reservation
  cardinality、retry-without-image 拒绝和唯一 abort/detach 收束到
  `resolve_reservation_only_recovery()`；unclaimed admission 失败分支的 ACTIVE/
  cursor guard 保持独立。device-publish/recovery focused 在 53 机均 PROCESS/LOGICAL
  PASS，UVM `INFO=220/3`、WARNING/ERROR/FATAL 全 0；当前全目录 scanner 为 5,461
  methods、0 diagnostics。该批仍不覆盖 reservation 后并发、跨队列 release、SRQ 全
  生命周期、legacy descriptor、外部 PCIe error/ordering、全局锁或最终 ownership 审计，
  计划继续保持 `active`。

### Batch150 当前更新（2026-09-22）

- `src/codec/rdma/rdma_cmq_codecs.sv` 的两个 CMQ consumer 不再各自维护重复的
  `context_key()`/`is_context_opcode()` case/集合；package-scope
  `rdma_cmq_context_codec_key()` 与 `rdma_cmq_is_context_opcode()` 负责共享映射，原
  protected 方法保留为兼容转发。六个 context opcode 和 unknown fail-closed key
  逐值保持；显式 `rdma_register_cmq_request_bodies()` registration 表仍是独立表，
  本批不把它宣称为全局单一 authority。
- 删除 `rdma_cmq_codec_test.sv` 中无调用的旧 context-key fixture，并更新 frozen ABI
  manifest 摘要；生产 codec 与测试文件合计净减少 53 行。最终全目录 scanner 为
  185 `.sv`、2 `.svh`、5,462 methods、0 diagnostics。
- 最终 53 机 `rdma_cmq_codec_test`、`rdma_context_body_codec_test`、
  `rdma_context_cmq_regression_test` 均 PROCESS/LOGICAL PASS，UVM INFO 为 `4/3/3`，
  WARNING/ERROR/FATAL 全 0；`cmq_gate regression` 为 PROCESS 28/28、LOGICAL 11/11、
  UVM pristine 28/28、wrapper rc=0。changed-SV style、`git diff --check`、queue/profile/
  manifest/keyword/Phase-1A/Python 292 门禁均 GREEN。
- 该批只关闭 CMQ consumer helper 的局部重复 seam，不覆盖完整 CMQ registry 单源化、
  queue-data/SRQ/跨队列并发、legacy descriptor、外部 ordering/error、engine-level
  全局锁或最终 ownership 审计；计划继续保持 `active`。

### Batch151 当前更新（2026-09-22）

- `src/model/rdma_authority_validation.sv` 将 CQ/EQ/RQ/SQ facade 的 live Function
  authority 检查统一为 `rdma_validate_live_authority()`；protected facade 方法仍保留
  为薄转发，configured/delegate/binding、incarnation、ACTIVE 和 `validate()` null/
  failure 的拒绝顺序不变。四项 facade focused 在 53 机均 PROCESS/LOGICAL PASS，UVM
  warning/error/fatal 为 0/0/0；Batch151 边界全目录 scanner 为 188 文件（186 `.sv`、
  2 `.svh`）、5,463 methods、0 diagnostics。详见
  `task-cmq-batch151-authority-validation-helper-report.md`。

### Batch152 当前更新（2026-09-22）

- `src/core/rdma_queue_facade_configuration.sv` 收束 SQ/RQ/EQ `configure()` 重复的
  dependency-null/timeout、shared-engine 五引用一致性、binding validation 和
  ACTIVE admission；one-shot configured 门禁与 authority/delegate 快照仍归各 facade，
  CQ 的特殊 URC/shared configure 不参与泛化。`rdma_sq_engine_test`、
  `rdma_rq_engine_test`、`rdma_eq_engine_test` 在 53 机均 PROCESS/LOGICAL PASS，UVM
  `INFO=3/WARNING=0/ERROR=0/FATAL=0`；最新全目录 scanner 为 189 文件（187 `.sv`、
  2 `.svh`）、5,464 methods（`.sv` 5,462、`.svh` 2）、0 diagnostics。该批只关闭
  facade configuration admission 的重复 seam，计划继续保持 `active`。详见
  `task-cmq-batch152-facade-configuration-shrink-report.md`。

### Batch153 当前更新（2026-09-22）

- `src/core/rdma_cq_engine.sv` 的普通 `configure()` 接入
  `rdma_validate_queue_facade_configuration()`，与 SQ/RQ/EQ 共用 dependency-null/
  timeout、shared-engine 五引用一致性、binding validation 和 ACTIVE admission；
  CQ `configure_shared()` 的 URC completion-QP/shadow/shared delegate 约束、
  `configured`/`shared_configured` one-shot 门禁及 authority/delegate/timeout 快照仍归
  CQ facade。`rdma_cq_engine_test`、`rdma_cq_engine_resize_test`、
  `rdma_cq_shadow_flush_test` 在 53 机均 PROCESS/LOGICAL PASS，UVM
  `INFO=3/WARNING=0/ERROR=0/FATAL=0`；全目录 scanner 仍为 189 文件（187 `.sv`、
  2 `.svh`）、5,464 methods（`.sv` 5,462、`.svh` 2）、0 diagnostics。该批只关闭
  普通 CQ configuration admission 的重复 seam，计划继续保持 `active`。详见
  `task-cmq-batch153-cq-configuration-admission-report.md`。

### Batch154 当前更新（2026-09-22）

- `src/core/rdma_queue_data_engine.sv` 新增受保护 `poll_event_with_timeout()`，让
  CEQ/AEQ public poll wrapper 共用 deadline、`QUEUE_EMPTY` retry、null-status 和
  timeout 外壳；`poll_ceqe_once()`/`poll_aeqe_once()` 的 decode、route、pending、
  doorbell、commit、recovery 和 detached-result 逻辑仍各自保留。三项 queue-data
  focused（`rdma_queue_data_engine_poll_test`、`rdma_queue_event_route_consume_test`、
  `rdma_aeqe_route_test`）以及覆盖非零 timeout 的 `rdma_eq_engine_test` 在 53 机均
  PROCESS/LOGICAL PASS，UVM
  `INFO=3/WARNING=0/ERROR=0/FATAL=0`；当前全目录 scanner 为 189 文件（187 `.sv`、
  2 `.svh`）、5,465 methods（`.sv` 5,463、`.svh` 2）、0 diagnostics。该批只关闭
  event poll timeout wrapper 的重复 seam，计划继续保持 `active`。详见
  `task-cmq-batch154-event-poll-timeout-shrink-report.md`。

### Batch155 当前更新（2026-09-23）

- `src/core/rdma_eq_engine.sv` 以 `validate_operation_authority()` 和
  `normalize_delegate_status()` 收束五个 facade task 的配置/Function authority 与
  null-status 外壳；五条 typed delegate 调用保持独立，生产源码由 327 行降至 272 行。
  EQ facade、queue-data poll、event-route consume 与 AEQE route 四项 VCS53 均
  PROCESS/LOGICAL PASS，UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` 且 pristine；五个
  未配置入口、五条 null-status 精确消息和非空失败 status 对象身份均有断言。全目录
  scanner 为 189 文件（187 `.sv`、2 `.svh`）、5,467 methods（`.sv` 5,465、
  `.svh` 2）、0 diagnostics。该批不合并 route、timeout、producer/consumer mutation
  或 CQ-flush secondary authority，计划继续保持 `active`。详见
  `task-cmq-batch155-eq-facade-operation-envelope-report.md`。

### Batch156 当前更新（2026-09-23）

- `src/core/rdma_cq_engine.sv` 以 `validate_operation_authority()` 和
  `normalize_delegate_status()` 收束 poll/publish/resize 三个普通入口的配置、Function
  authority 与 null-status 外壳；三条 typed virtual seam 独立，`flush_shadow()` 保持
  shared-only/inout/replay 顺序。CQ facade、resize 与 shadow-flush 三项 VCS53 均
  wrapper rc=0、PROCESS/LOGICAL PASS，UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` 且
  pristine；未配置消息、null 精确消息、失败 status 身份、sentinel 清理和 stale-epoch
  counter 均有断言。生产源码 500→498 行，非注释非空行 373→344；全目录 scanner
  为 189 文件（187 `.sv`、2 `.svh`）、5,469 methods（`.sv` 5,467、`.svh` 2）、
  0 diagnostics。`flushed_shadow` replay 不回填缓存快照的边界仍开放，计划继续保持
  `active`。详见 `task-cmq-batch156-cq-facade-operation-envelope-report.md`。

### Batch157 当前更新（2026-09-23）

- `src/core/rdma_cq_engine.sv` 删除 `shadow_flush_result`，新增 raw factory nonfatal
  创建、手工 `rdma_handle` clone 和 detached `rdma_cq_shadow_snapshot` clone；普通
  `configure()+configure_shared()` 拒绝跨 Function UID/generation，并在补齐 shared
  shadow 前复用 live binding admission。`src/core/rdma_queue_data_engine.sv` 的 URC
  evidence candidate 也改用 raw factory/cast。首次
  `flush_shadow()` 在 URC evidence 前独立 staging caller/cache；replay 重新从
  `flushed_shadow` 构造 canonical detached snapshot/status，不重复 evidence 或
  `shadow_flush_count`。`configure_shared()`、首刷和 replay 的 factory null/错误类型
  失败均返回 `RDMA_SC_RESOURCE_EXHAUSTED`，不提交部分配置或改变 caller/cache/count/
  evidence。
- `rdma_cq_shadow_flush_test` 覆盖 shared handle、首刷 snapshot/cache/evidence candidate、
  replay snapshot/handle 的失败原子性和解除故障后的重试；`rdma_cq_engine_test` 覆盖
  ordinary `configure()+configure_shared()` 的跨 UID/generation 拒绝与 live reset-epoch
  gate，并显式使用 projected 21-bit local CQ ID。三项 CQ focused VCS53 均 rc=0、PROCESS/
  LOGICAL PASS、UVM
  `INFO=3/WARNING=0/ERROR=0/FATAL=0` 且 pristine；完整 wrapper/simulator hash 见
  `task-cmq-batch157-cq-shadow-replay-atomicity-report.md`。
- 本批静态门禁、Python 292/292 和全目录中文契约 scanner 均 GREEN；当前为 189 文件
  （187 `.sv`、2 `.svh`）、5,483 methods（`.sv` 5,481、`.svh` 2）、0 diagnostics。
  `configure_shared()`-only 无 live binding 的 reset 认证限制、跨队列并发、SRQ lifecycle、
  legacy descriptor、外部 PCIe ordering/error、engine-level 全局锁、完整 parent/core
  gate 与最终 ownership 审计仍 OPEN；计划继续保持 `active`。

### Batch158 当前更新（2026-09-23）

- `src/core/rdma_queue_data_engine.sv` 新增受保护的
  `reserve_device_publish_checked()` 与 `check_device_publish_polarity()`，将
  `publish_cqe()`、`publish_ceqe()` 和 `publish_aeqe_common()` 重复的设备 producer
  reservation、null-status 归一化、expected-polarity 比较与 polarity cancel 收束为
  两个窄 seam。CQE/CEQE 仍按 authority→reservation→polarity→codec，AEQE 仍按
  image staging→reservation→route/epoch recheck→polarity→commit；`write_commit_device_entry()`
  的 backing、MMIO、ledger 与 recovery 所有权未移动。
- `check_device_publish_polarity()` 的 reservation 是 `inout`：匹配时保留 runtime 内部
  保留的 reservation 对外返回 detached 快照，失败时调用既有 cancel/recovery 并清零
  reservation。AEQE reservation 后 `validate_attachment_route_epoch()` 仍在 polarity
  检查前执行，因而没有把 post-reservation reset/route 窗口隐藏到泛化 helper 中。
- `rdma_queue_data_engine_device_publish_test`、`rdma_queue_data_engine_poll_test`、
  `rdma_aeqe_route_test` 与 `rdma_aeqe_f5_e2e_test` 在 53 机最终源码边界均 wrapper
  rc=0、PROCESS/LOGICAL PASS，UVM INFO 分别为 `220/3/3/115`，WARNING/ERROR/FATAL
  全为 0；`git diff --check`、changed-SV style、queue/profile/Phase-1A 与 Python
  292/292 均通过。全目录 scanner 为 189 文件（187 `.sv`、2 `.svh`）、5,485 methods
  （`.sv` 5,483、`.svh` 2）、0 diagnostics。
- 本批只关闭设备发布 admission 的局部重复 seam；跨队列/跨线程并发、SRQ lifecycle、
  legacy descriptor、外部 PCIe ordering/error、engine-level 全局锁、完整 parent/core
  gate 和最终 ownership 审计仍 OPEN，计划继续保持 `active`。详见
  `task-cmq-batch158-device-publish-admission-report.md`。

### Batch159 当前更新（2026-09-23）

- `src/core/rdma_cmq_engine.sv` 新增 `decode_transport_envelope()`，统一 observed
  submit 与 recovery submit 对 transport envelope 的 status shape、observation 文案
  和 submission effect 解码；合法 status 仍复制为 detached status，合法 effect 保留，
  malformed status/effect 各自 fail-closed，recovery 的 effect 文案覆盖和 observed 的
  combined 文案均保持。decoder 不执行 observer arm、effect fold、分类、journal/CAS
  mutation 或外部 transport 调用。
- `tests/unit/rdma_cmq_engine_test.sv` 新增 probe 与四行 recovery envelope contract
  （null、malformed status、malformed effect、双 malformed），并在 recovery mutation
  fixture 前运行；caller-owned envelope、status alias、operation/observation 文案和
  raw effect 降级均有断言。`rdma_cmq_engine_test` 在 53 机 wrapper rc=0、18/18
  PROCESS PASS、1/1 LOGICAL PASS，18 个 UVM report 均 WARNING/ERROR/FATAL 为 0。
- 静态 gates 与 Python 292/292 通过；全目录 scanner 为 189 文件（187 `.sv`、2 `.svh`）、
  5,488 methods（`.sv` 5,486、`.svh` 2）、0 diagnostics。更广 malformed recovery
  组合、并发/global lock、SRQ lifecycle、legacy descriptor、外部 ordering/error、完整
  CMQ/core gate、typed URC factory 与最终 ownership/Phase-1C F2 审计仍 OPEN，计划继续
  保持 `active`。详见 `task-cmq-batch159-transport-envelope-decode-report.md`。

### Batch160-164 当前更新（2026-09-24）

- Batch160 将 CMQ transaction models/kernel 从 engine 物理职责中拆出；Batch161 将 QP
  lifecycle transition policy 收束为无状态值决策；Batch162 将 resource lifecycle blocker
  snapshot 收束为只读 admission seam；Batch163 将普通资源创建统一为 identity candidate
  的 reserve→construct→register→publish/rollback 骨架。四批均保留原有 mutable owner、
  reset/generation/route authority、错误优先级和外部 adapter 生命周期，详见对应 batch
  report 与项目级计划。
- Batch164 新增 `rdma_queue_runtime_transaction_models.sv`，把 runtime 专用枚举、cursor、
  pending recovery evidence 和 host slot ledger 从 `rdma_queue_runtime.sv` 移到 detached
  value-model 文件；runtime 仍唯一拥有 lock、PI/CI、occupancy、reservation、ledger、
  pending publication 与 route/epoch mutation。`rdma_queue_runtime_test`、queue-data
  post/poll/recovery 四项 VCS53 focused 均 wrapper rc=0、PROCESS/LOGICAL PASS，UVM
  WARNING/ERROR/FATAL 为 0/0/0。
- Batch165 将 `create_function()` 的专用 generation/tombstone 身份预留收束为
  `rdma_function_identity_candidate`，新增 reserve/rollback seam，但不把 Function 强行并入
  普通 serial allocator；`rdma_resource_manager_test`、`rdma_control_plane_test` 和
  `rdma_queue_lifecycle_test` 在 53 机均 PROCESS/LOGICAL PASS，UVM WARNING/ERROR/FATAL
  为 0/0/0。
- 当前工作树静态证据：`git diff --check`、changed-SV style、Python 293/293 和 queue/
  profile/Phase-1A gates 通过；全目录中文契约 scanner 为 194 个源码文件（192 `.sv`、
  2 `.svh`）、5,507 methods、0 diagnostics。跨队列/跨线程并发、SRQ 全生命周期、reset
  统一验收、外部 ordering/error、manager 外部调用窗口补偿、完整 parent/core gate 与
  最终 ownership/Phase-1C F2 审计仍 OPEN，计划继续保持 `active`。

### Batch193 当前更新（2026-09-25）

- `src/core/rdma_resource_transaction_models.sv` 新增
  `rdma_resource_publication_candidate`，只保存 registry/published detached 快照、
  owner/handle 快照和稳定 key；`valid()`/`clear()` 不读取或复制 manager registry、
  allocator、lock 或外部 adapter。
- `src/core/rdma_resource_manager.sv` 将 `register_resource()` 重构为
  `stage_resource_publication()` → `commit_resource_publication()`：所有 factory/clone
  调用完成后才进入无外部调用的四账本 commit，兼容入口仍按原 API 返回 published 快照，
  不改变 create/lookup/rollback 错误顺序或所有权。
- `rdma_resource_manager_test` 新增 null/stage/commit/clear 矩阵；resource-manager、
  queue lifecycle、QP lifecycle、control-plane 四项 VCS53 focused 均 PROCESS/LOGICAL
  PASS，UVM WARNING/ERROR/FATAL 为 0/0/0；Python、changed-SV style、`git diff --check`
  与当前源码中文契约 scanner 均通过。详见
  `task-rdma-batch193-resource-publication-stage-commit-report.md`。
- 本批只关闭 projection 与 publication mutation 的结构窗口；跨线程/跨进程全局锁、
  allocator/registry 并发、跨 incarnation destroy dependency、SRQ lifecycle、外部
  ordering/error/backpressure、Phase-1C F2 whole-plan 和最终 ownership 审计仍 OPEN，
  计划继续保持 `active`。

## 尚未关闭的验收项

1. Phase 1C F2 仍暂停于更广泛的 `sge_num` canonical-authority/whole-plan 收口；Batch100
   已在本项目 codec 内关闭 RC raw `INLINE_SGB` 的 `TPL=513 / SGE_NUM=33` 固定容量拒绝缺口，
   没有扩大数组或修改外部契约。详见 Batch100 报告与 phase1c evidence。
2. Batch99 最后源码边界的 parent/core gate 是 **pre-Batch101 inherited baseline**：
   `evidence/post-batch99-final2-cmq_gate-regression.log`（SHA-256
   `f8ee6a4ae9e2802c2eebf9d7c69a2103ba678d7f605adf57072efc74ff3f7283`），28/28 process、
   11/11 logical、28/28 UVM pristine；更早的 Batch93/99 gate 仅保留为历史边界证据。
   同一旧源码边界的 core regression 亦 GREEN：`evidence/post-batch99-final2-core-regression.log`
   （SHA-256 `c59989807df0feb7cc92e9b34cf0640190c7f0b521e864e7cff130e0e8a7a30b`），
   95/95 process、78/78 logical、95/95 UVM pristine；Batch104 已在 Batch101/102 后的当前
   源码边界重新验证 parent/core gate（CMQ 28/28 process、11/11 logical；core 95/95 process、
   78/78 logical；UVM pristine），因此旧 SHA 只作历史边界证据。Batch107 已在当前源码
   边界再次刷新 CMQ gate（28/28 process、11/11 logical）、core regression（95/95 process、
   78/78 logical）以及 integration regression（8/8 tests），严格 UVM 仍为 0/0/0；Batch109
   在 candidate/ownership/close 改动后的当前源码边界再次验证 CMQ 28/28、core 95/95 和
   integration 10/10，严格 UVM 仍为 0/0/0；Batch110 在 publication-guard 与 queue-codec
   当前工作树上重新验证同样的 CMQ/core/integration 结论，严格 UVM 仍为 0/0/0；Batch111
   已刷新 focused/lifecycle、integration 10/10 和 CMQ gate 28/28+11/11，core 与静态门禁
   已在 Batch111 当前源码边界证据闭合。
3. 全目录中文 function/task、文件头和静态门禁复审已在 Batch111 当前源码边界通过（185
   `.sv`、2 `.svh`、5,387 methods、0 diagnostics）；Batch123 已在当前源码边界重扫为
   5,407 methods、0 diagnostics；Batch106 覆盖 registration/epoch/
   router-local overflow 与 scope 原子性 focused seam，Batch107 关闭 reset 后 stale
   registration 快路径，Batch109 关闭严格一对一 lease/close 与 candidate provenance 绕过，
   Batch110 关闭同步 publication callback 重入，Batch111 关闭 legacy Host epoch capability
   bypass；coordinator 的跨线程/跨进程全局并发锁、更深生命周期/所有权语义复审仍需后续
   完成，并在后续源码变化后重复门禁。Batch129 当前源码边界已刷新为 185 个 `.sv`、2 个
   `.svh`、5,416 methods（`.sv` 5,414、`.svh` 2）、0 diagnostics；Batch133 在最终源码
   边界刷新为 5,431 methods/0 diagnostics；Batch142 自身为 5,436 methods，Batch143
   helper 后为 5,437 methods；Batch144 当前最终边界为 5,438 methods（`.sv` 5,436、
  `.svh` 2），Batch145 在新增 admission helper 与 stale-epoch fixture 后为 5,440
  methods；Batch148 当前边界为 5,460 methods（`.sv` 5,458、`.svh` 2）/0 diagnostics；
  manifest/keyword、queue/profile、
   Phase-1A、changed-SV style、`git diff --check` 与 Python 292 均通过；Batch152 边界为
   5,464 methods（`.sv` 5,462、`.svh` 2），Batch154 边界为 5,465 methods；Batch155
   边界为 5,467 methods，Batch156 最新边界为 5,469 methods（`.sv` 5,467、`.svh`
   2），Batch157 当前边界为 5,483 methods（`.sv` 5,481、`.svh` 2），Batch158 当前边界为
   5,485 methods（`.sv` 5,483、`.svh` 2），Batch159 当前边界为 5,488 methods（`.sv`
   5,486、`.svh` 2），0 diagnostics。
4. Batch114 已关闭 UD codec 与通用 model/writer 对非零 inline/1–2 SGE 的 effective
   mode 对齐缺口；Batch115 已用临时 focused probe 补充公开 `post_send()`/
   `replay_pending()` 的 UD 1B inline/1–2 SGE 与 SGB failure recovery 证据；Batch116
   将 host-producer recovery 阶段独立为 helper 并重跑 recovery/post focused，但完整
   SRQ/跨队列 lifecycle 矩阵、device/consumer recovery 全阶段组合仍需独立证据；
   Batch117 只读拆出 claimed scan，Batch118 只读拆出 reservation-only candidate scan；
   两批均未覆盖 reservation-only 查询/abort 的所有 hostile 组合，且不能通过放宽 writer
   gate 掩盖新的 transport authority 缺口。Batch123 已在当前源码边界重新运行全目录
   scanner，Batch129 已在当前源码边界重扫为 5,416 methods/0 diagnostics；Batch133 最终
   源码边界为 5,431 methods/0 diagnostics；Batch142/Batch143 历史边界分别为 5,436/
   5,437 methods，Batch144 当前边界为 5,438 methods，Batch145 当前边界为 5,440，
   Batch148 当前边界为 5,460 methods/0 diagnostics；Batch152 边界为 5,464 methods/0
   diagnostics；Batch154 边界为 5,465 methods，Batch155 边界为 5,467 methods，
   Batch156 边界为 5,469 methods，Batch157 当前边界为 5,483 methods，Batch158 当前边界为
   5,485 methods，Batch159 当前边界为 5,488 methods/0 diagnostics；
   不把 Batch111/Batch122 的旧计数冒充当前源码结果。
5. 旧批次条目中的 `pcie_work` OPEN/UNAPPROVED 文案是批准前的历史记录；当前锁已按用户
   指定上游快照更新为 75 个 `APPROVED` 闭包行，`tools/check_external_dependency_lock.py`
   对干净 clone 的 verify 已通过，adapter 与 SR-IOV focused 也已在 53 机 GREEN。当前
   仍不能把这两项 focused 证据等同于完整外部 regression 或整份重构计划完成。

因此矩阵当前是“持续更新、计划 active”，不能据此把整份结构重构计划标记为完成。

### Batch174 当前更新（2026-09-24）

- 新增 `src/codec/rdma/rdma_sge_authority.sv`，统一 SQ 非零 SGE 计数和 RQ typed
  SGE 数量/总长度 authority；SQ/RQ model 保留各自 payload mode、external-SGB
  provenance、snapshot 和 wire-width gate，不复制可变账本或外部资源所有权。
- `rdma_queue_codec_test` 在 53 机当前源码边界 PROCESS/LOGICAL PASS，UVM
  WARNING/ERROR/FATAL 为 0/0/0；changed-SV style 与 `git diff --check` 通过。
- 该批只关闭 codec/model 的重复统计 seam；inline/SGE/atomic/UD/URC whole-plan
  authority、SRQ lifecycle、跨队列/跨线程并发、外部 ordering/error、manager 调用窗口、
  完整 parent/core/integration regression 与最终 ownership 审计继续 OPEN，计划保持
  `active`。

### Batch175 当前更新（2026-09-24）

- `rdma_queue_runtime_transaction_models.sv` 新增 `rdma_queue_mmio_transition_policy`，
  `rdma_queue_runtime.sv` 的普通/noalloc recovery admission 共享同一纯值迁移表；锁、
  pending、confirmation、兼容 marker 和 failure status 仍只有 runtime 可写。
- `rdma_queue_runtime_test` 在 53 机当前源码边界 PROCESS/LOGICAL PASS，UVM
  WARNING/ERROR/FATAL 为 0/0/0；changed-SV style 与 `git diff --check` 通过。
- AMBIGUOUS 全方向组合、SRQ lifecycle、跨队列/跨线程并发、外部 ordering/error、
  manager 调用窗口、完整 parent/core/integration regression 和最终 ownership 审计
  继续 OPEN，计划保持 `active`。

### Batch176 当前更新（2026-09-24）

- runtime recovery 的两个 failure-record 入口共享锁内
  `copy_recovery_failure_status_locked()`；failure status 字段复制不再有两份实现，
  但 lock、pending、MMIO evidence、retry confirmation 和 status-slot owner 仍归 runtime。
- `rdma_queue_runtime_test` 当前源码边界 PROCESS/LOGICAL PASS，UVM WARNING/ERROR/FATAL
  为 0/0/0；changed-SV style 与 `git diff --check` 通过。
- SRQ lifecycle、AMBIGUOUS 全方向组合、跨队列/跨线程并发、外部 ordering/error、manager
  调用窗口、完整 parent/core/integration regression 与最终 ownership 审计继续 OPEN。

### Batch180 当前更新（2026-09-24）

- 新增 `src/core/rdma_queue_lifecycle_opcode_policy.sv`，统一 queue lifecycle executor
  的 CQ/SRQ/CEQ/AEQ create/query/delete opcode 纯值映射；兼容 wrapper 保留原 public
  调用点，policy 不复制 queue/resource/recovery ledger 或外部资源所有权。
- `rdma_queue_lifecycle_models_test` 在 VCS53 当前源码边界 PROCESS/LOGICAL PASS，UVM
  WARNING/ERROR/FATAL 为 0/0/0；changed-SV style 与 `git diff --check` PASS。
- SRQ lifecycle、跨队列/跨线程并发、SQD/SQE drain/flush、legacy descriptor、外部
  ordering/error、manager 调用窗口、AMBIGUOUS 全方向组合和最终 ownership 审计继续 OPEN，
  项目计划保持 `active`。

### Batch181 当前更新（2026-09-24）

- 新增 `src/core/rdma_queue_mmio_transition_policy.sv`，将 Batch175 的 MMIO evidence
  纯值迁移表从 runtime transaction models 独立出来；runtime 仍唯一拥有 evidence、
  pending、lock、retry confirmation 和 MMIO 副作用。
- `rdma_queue_runtime_test` 新增 13 个 detached matrix case，覆盖 consumer/device
  producer 的 AMBIGUOUS 全方向不可升级、NO_SUBMIT confirmation、device write-attempt
  前置条件及拒绝路径不消费授权；VCS53 focused PROCESS/LOGICAL PASS，UVM
  WARNING/ERROR/FATAL 为 0/0/0。
- 本批只关闭 policy 文件边界和直接矩阵证据，不把它扩大解释为 SRQ lifecycle、跨队列/
  跨线程并发、SQD/SQE drain/flush、legacy descriptor、外部 ordering/error、manager 调用
  窗口、Phase-1C F2 或最终 ownership 审计完成；项目计划继续 `active`。

### Batch182 当前更新（2026-09-24）

- 新增 `src/core/rdma_resource_dependency_policy.sv`，统一 QP/SRQ/OTHER dependent
  分类和 parent release blocker 纯值规则；manager 仍唯一执行 registry 扫描和 snapshot
  计数，不复制 registry、lock、recovery 或 resource ownership。
- `rdma_resource_manager_test` 的 dependency policy matrix 在 VCS53 当前源码边界
  PROCESS/LOGICAL PASS，UVM WARNING/ERROR/FATAL 为 0/0/0；未知 kind 按 OTHER
  fail-closed。
- 本批只收束 destroy/resize admission 的分类 seam；SRQ 全生命周期组合、跨队列/跨线程
  并发、SQD/SQE drain/flush、legacy descriptor、外部 ordering/error、manager 调用窗口、
  Phase-1C F2 和最终 ownership 审计继续 OPEN。

### Batch183 当前更新（2026-09-24）

- `rdma_resource_dependency_policy` 新增 release mode 与 `blocks_release(snapshot, mode)`，
  将严格 destroy/finalize 与 CQ resize 的 SRQ/QP/其它 dependent 组合阻塞规则集中为纯值
  policy；manager 仍唯一拥有 registry 扫描、锁、状态提交和外部 backing 生命周期。
- `rdma_resource_manager_test` 增加 idle QP、busy QP、idle SRQ、resource outstanding 与
  strict release 矩阵；`rdma_resource_manager_test` 在 VCS53 当前源码边界
  PROCESS/LOGICAL PASS，UVM WARNING/ERROR/FATAL 为 0/0/0。
- 本批只收束 SRQ/QP destroy admission 的重复条件，不关闭 SRQ 全生命周期完整组合、跨队列/
  跨线程并发、SQD/SQE drain/flush、legacy descriptor、外部 ordering/error/backpressure、
  manager 外部调用窗口、Phase-1C F2 或最终 ownership 审计。

### Batch184 当前更新（2026-09-24）

- `rdma_queue_runtime_test` 增加 test-only lock probe 与 fork contention case，验证另一线程
  持有 production runtime semaphore 时 `query_occupancy()` 返回 `RESOURCE_BUSY`，释放后查询
  恢复且 occupancy 不变；生产 runtime 未新增第二把锁或账本。
- 该批只补单 runtime semaphore 的跨线程 characterization，不关闭跨 queue/engine 全局
  并发、SRQ 全生命周期、SQD/SQE drain/flush、legacy descriptor、外部 ordering/error/
  backpressure、manager 调用窗口、Phase-1C F2 或最终 ownership 审计。

### Batch185 当前更新（2026-09-24）

- `rdma_reset_coordinator.sv` 新增无状态 `rdma_reset_tokenless_admission_policy::evaluate()`，
  `authorize_tokenless_dataplane()` 保持原 guard/transaction 读取与 cleanup 语义，仅委托
  detached policy；Function/Host/Device epoch、owner/token、router 和外部 manager 所有权
  未移动。
- `rdma_reset_coordinator_test` 增加 idle、publication-only、transaction-only、combined
  active 与 cleanup override 五项矩阵；VCS53 focused 需确认 PROCESS/LOGICAL PASS 且 UVM
  WARNING/ERROR/FATAL 为 0/0/0。详见 `task-rdma-batch185-reset-tokenless-admission-policy-report.md`。
- 本批只关闭同步 tokenless admission 重复条件；跨线程/跨进程全局锁、SRQ lifecycle、
  外部 ordering/error/backpressure、manager 调用窗口与最终 ownership 审计继续 OPEN。

### Batch186 当前更新（2026-09-24）

- 新增 `src/adapter/rdma_adapter_status_policy.sv`，统一 Host-memory API 与 concrete
  adapter 的 null-status fail-closed 构造；base/wrapper 只传递组件前缀和 operation，非空
  status 原样保留，null 统一返回 `RDMA_SC_INVALID_STATE`。
- policy 不读取或复制 mapping、ledger、cursor、外部 backing 或 adapter ownership；
  `rdma_adapter_contract_test` 增加 null/non-null identity matrix，真实 host-memory
  integration 保留既有诊断文案与 leak 约束。VCS53 host_mem focused 已通过，UVM
  WARNING/ERROR/FATAL 为 0/0/0。
- 本批不关闭 SRQ lifecycle、全局并发、外部 ordering/error/backpressure、manager 调用窗口、
  Phase-1C F2 或最终 ownership 审计。

### Batch187 当前更新（2026-09-24）

- 新增 `rdma_srq_destroy_value_policy()`，统一 SRQ OCC flush 与本地 backing release 的
  detached role/phase recipe；policy 只投影值数组，manager 仍唯一拥有 dependency scan、
  CMQ completion、registry/recovery commit 和外部 backing 生命周期。
- canonical/no-SGB recipe、SRQ/QP destroy busy、restore/retry 和 flush failure 场景在
  `rdma_queue_lifecycle_test` 中验证；VCS53 PROCESS/LOGICAL PASS，UVM WARNING/ERROR/FATAL
  为 0/0/0。详见 `task-cmq-batch187-srq-destroy-value-policy-report.md`。
- 本批不关闭 shared-QP recovery 的更广组合、跨 queue/engine 并发、SQD/SQE drain/flush、
  外部 ordering/error/backpressure、Phase-1C F2 或最终 ownership 审计。

### Batch188 当前更新（2026-09-24）

- 新增 `src/core/rdma_qp_urc_backing_policy.sv`，将 URC RSQ/RDSQ/DSQ 的固定 role、
  4 KiB/4 KiB/8 KiB 长度和顺序提取为无状态 typed factory；RC/UD/未知 transport
  fail-closed 为空数组。
- `rdma_qp_lifecycle_executor::materialize_plan()` 仍使用原 `allocate_ref()` 和
  partial-plan rollback，未转移 manager、mapping、Host-memory、QP plan 或 recovery
  所有权；`rdma_qp_lifecycle_test` 直接矩阵与 URC 实际 plan 均通过。
- 当前 VCS53 QP focused PROCESS/LOGICAL PASS，UVM WARNING/ERROR/FATAL 为 0/0/0；本批
  只收束 URC backing factory，不关闭 SQD/SQE drain/flush、跨 queue/engine 全局并发、
  legacy descriptor、外部 ordering/error/backpressure、Phase-1C F2 或最终 ownership
  审计。

### Batch189 当前更新（2026-09-24）

- `rdma_qp_lifecycle_executor::modify_locked()` 现在缓存并复用
  `rdma_qp_transition_decide()` 的唯一 decision；SQD/SQE unsupported gate 仍在原
  transport 校验窗口前生效，但 executor 不再复制状态条件。
- QP lifecycle focused VCS53 PROCESS/LOGICAL PASS，UVM WARNING/ERROR/FATAL 为 0/0/0；
  outstanding、QPC staging、CMQ、generation fence 和 resource commit 顺序保持不变。
- 本批不实现 SQD/SQE drain/flush，不关闭跨 queue/engine 全局并发、legacy descriptor、
  外部 ordering/error/backpressure、Phase-1C F2 或最终 ownership 审计。

### Batch190 当前更新（2026-09-24）

- `src/codec/rdma/rdma_sge_authority.sv` 新增 `derive_send()`，把 SQ 的零长度过滤、
  null/reserved-bit/2GiB/32 项边界、canonical `sge_num` 和 payload 总长度收束为纯值
  authority；RC/UD codec 以及 `rdma_queue_data_engine::write_sgb_and_verify()` 共享该
  helper，不保存输入引用或接管 SGB/Host-memory 生命周期。
- `rdma_sqe_authority_test` 新增 sentinel、zero-length、null、reserved bit31 矩阵；
  `rdma_sqe_authority_test` 与 `rdma_sq_codec_test` 在 VCS53 当前源码边界均
  PROCESS/LOGICAL PASS，UVM warning/error/fatal 为 0/0/0。Python 293/293、style/diff、
  queue/profile/Phase-1A gates 已通过；core 全回归正在运行，结果待补录。
- 本批只推进 Phase-1C F2 的 SQ SGE whole-plan authority，不关闭 RQ raw/typed provenance、
  SRQ lifecycle、跨 queue/engine 并发、SQD/SQE drain/flush、legacy descriptor、外部
  ordering/error/backpressure、manager 外部调用窗口和最终 ownership 审计；计划继续保持
  `active`。

### Batch191 当前更新（2026-09-24）

- `rdma_queue_data_engine.sv` 新增 `execute_consumer_wqe_release()`，统一 live CQ poll
  与 consumer recovery retry 的 CQ release gate、routed WQ release、finish 和失败
  evidence 事务；`release_consumer_pending_wqe()` 保留为 recovery 兼容入口并委托该
  seam。CQ→SQ/RQ/SRQ 锁序、pending/runtime 唯一 owner、shadow/doorbell evidence 和
  public API 未改变。
- `rdma_queue_runtime_test`、`rdma_queue_data_engine_poll_test`、
  `rdma_queue_data_engine_recovery_test` 在 VCS53 当前源码边界均 PROCESS/LOGICAL PASS，
  UVM WARNING/ERROR/FATAL 为 `0/0/0`；Python 293/293、changed-SV style 和 diff gate
  通过。详见 `task-rdma-batch191-cq-release-transaction-seam-report.md`。
- 本批只关闭 CQ consumer release 的重复事务 seam，不关闭 SRQ 全生命周期组合、跨
  queue/engine 全局并发、SQD/SQE drain/flush、legacy descriptor、外部
  ordering/error/backpressure、Phase-1C F2 whole-plan、manager 外部调用窗口或最终
  ownership 审计，项目计划继续保持 `active`。

### Batch192 当前更新（2026-09-25）

- `rdma_resource_manager.sv` 新增 `publish_identity_candidate()`，普通资源创建入口
  不再各自重复 candidate 有效性检查、registry publication、null-status 归一化、失败
  rollback 和成功 clear；Function 的 generation/tombstone 路径保持独立。
- `rdma_resource_manager_test`、`rdma_queue_lifecycle_test`、`rdma_qp_lifecycle_test`、
  `rdma_control_plane_test` 在 VCS53 当前源码边界均 PROCESS/LOGICAL PASS，UVM
  WARNING/ERROR/FATAL 为 0/0/0；Python 293/293、changed-SV style 与 `git diff --check`
  均通过。详见 `task-rdma-batch192-resource-publish-seam-report.md`。
- 本批只收束 resource publication 重复事务 seam，不关闭 allocator/registry 并发、SRQ
  全生命周期、legacy descriptor、外部 ordering/error/backpressure、manager 调用窗口、
  Phase-1C F2 whole-plan 或最终 ownership 审计，矩阵和项目计划继续保持 `active`。

### Batch194 当前更新（2026-09-25）

- `rdma_resource_publication_candidate::valid()` 现在按 canonical key 格式重算
  registry/incarnation/generation key，并核对 owner/handle kind 以及 registry/published
  snapshot 的 owner/handle identity；`commit_resource_publication()` 拒绝已经存在的
  registry/incarnation key，防止旧 stage 覆盖同一 incarnation。
- `rdma_resource_manager_test` 增加 hostile key、hostile owner 和 duplicate stage/commit
  矩阵；resource-manager focused VCS53 PROCESS/LOGICAL PASS，UVM WARNING/ERROR/FATAL 为
  0/0/0；Python 293/293、changed-SV style 与 `git diff --check` PASS。详见
  `task-rdma-batch194-publication-candidate-integrity-report.md`。
- 本批只收束 detached publication candidate 的 key/identity provenance 和重复提交覆盖
  窗口；跨线程/跨进程互斥、allocator/registry 全局并发、SRQ 全生命周期、legacy
  descriptor、外部 ordering/error/backpressure、Phase-1C F2 whole-plan 与最终 ownership
  审计仍 OPEN，计划继续保持 `active`。
### Batch195 当前更新（2026-09-25）

- 新增 `rdma_queue_progress_candidate`，把 queue progress 的 `key`、authoritative resource
  snapshot、可选 ERROR recovery snapshot 和 `has_recovery` 统一为 detached 值；`valid()`/
  `clear()` 只负责 shape 与生命周期，不读取或拥有 registry、recovery ledger、锁或外部
  backing。
- `queue_progress_snapshots()` 统一输出 candidate，`commit_queue_progress()` 统一校验后
  原子写回 registry/recovery_records；flush/cleanup/context 三个入口复用同一事务值并保留
  原有 role cardinality、authority、SRFQ flush 前置、错误优先级和提交顺序。
- `rdma_resource_manager_test` 增加 default/partial/complete/clear shape 矩阵；resource
  manager、queue lifecycle、QP lifecycle、control plane focused VCS53 均 PROCESS/LOGICAL
  PASS，UVM WARNING/ERROR/FATAL `0/0/0`，changed-SV style 与 `git diff --check` PASS。
  详见 `task-rdma-batch195-queue-progress-candidate-report.md`。
- 本批只收束 queue progress detached 参数边界；registry 跨线程/跨进程互斥、manager 外部
  调用窗口、SRQ 全生命周期、跨 queue/engine 并发、Phase-1C F2 whole-plan 和最终
  ownership 审计仍 OPEN，计划继续保持 `active`。

### Batch196 当前更新（2026-09-25）

- `rdma_sge_authority::derive_typed_common()` 统一 SQE/RQE typed SGE 的 raw-list
  上限、null、reserved bit31、2 GiB sentinel、累计长度和输出原子性；`derive_send()`
  / `derive_receive()` 保留原 API 与方向诊断文案，仅作为薄 wrapper。
- `rdma_sqe_authority_test` 的 SQ/RQ authority 矩阵在 VCS53 PROCESS/LOGICAL PASS，
  UVM WARNING/ERROR/FATAL 为 `0/0/0`；Python 293/293、style/diff、queue/profile/
  Phase-1A gates 均 PASS。详见 `task-rdma-batch196-sge-authority-dedup-report.md`。
- 本批只去重纯值校验实现；registry/allocator 并发、SRQ lifecycle、跨 queue/engine
  并发、SQD/SQE drain/flush、legacy descriptor、外部 ordering/error/backpressure、
  manager 调用窗口和最终 ownership 审计仍 OPEN。

### Batch197 当前更新（2026-09-25）

- 新增 `src/core/rdma_cmq_legacy_dispatch.sv`，以无状态
  `rdma_cmq_dispatch_legacy_raw()` 统一 control-plane、queue lifecycle 和 QP
  lifecycle 三处 legacy CMQ raw dispatch 的输出初始化、参数门禁和一次 execute。
  null-status、completion、fence、ambiguity 与 recovery 仍由各 caller 保持，队列
  合并 guard 的既有 `INVALID_ARGUMENT` 语义不变。
- `rdma_control_plane_test` 在 VCS53 PROCESS/LOGICAL PASS，UVM WARNING/ERROR/FATAL
  `0/0/0`；changed-SV style 与 `git diff --check` PASS。详见
  `task-rdma-batch197-legacy-dispatch-seam-report.md`。
- 本批只收束 raw dispatch 样板，不关闭 registry/allocator 并发、SRQ 全生命周期、跨
  queue/engine 并发、SQD/SQE drain/flush、legacy descriptor、外部
  ordering/error/backpressure、manager 调用窗口、Phase-1C F2 whole-plan 或最终
  ownership 审计；计划继续保持 `active`。

### Batch198：CMQ ambiguity evidence policy（已完成本批，计划仍 active）

- 新增 `src/core/rdma_cmq_ambiguity_policy.sv`，以无状态
  `rdma_cmq_ambiguity_policy::is_ambiguous()` 统一 CMQ timeout/reset、null status、
  ticket/completion 缺失与 no-submit 证明的纯值分类。
- queue/QP caller-specific evidence profile 保留原语义：queue 允许 completion 壳加
  no-submit 证明，QP 要求 completion 也为空；QP 的无 ticket/completion 纯成功确定，
  queue 保守判为 ambiguous。`rdma_cmq_engine_models_test` 新增完整差异矩阵。
- VCS53 focused PROCESS/LOGICAL PASS，UVM warning/error/fatal `0/0/0`；Python
  293/293、changed-SV style 与 `git diff --check` PASS。详见
  `task-rdma-batch198-cmq-ambiguity-policy-report.md`。
- 本批只关闭 ambiguity 纯值分类重复，不关闭 registry/allocator 并发、SRQ lifecycle、
  跨 queue/engine 并发、SQD/SQE drain/flush、legacy descriptor、外部
  ordering/error/backpressure、manager 调用窗口、Phase-1C F2 whole-plan 或最终
  ownership 审计；计划继续保持 `active`。

### Batch199：resource publication projection epoch gate（已完成本批，计划仍 active）

- `rdma_resource_publication_candidate::manager_epoch` 在第一次外部 clone/factory 投影前
  捕获 manager mutation epoch；`stage_resource_publication()` 在四类 detached projection
  完成后检查该 epoch，发现 manager 在 projection 窗口重入 mutation 时清除 candidate 并
  返回 `RDMA_SC_INVALID_STATE`，避免污染值进入 commit。
- 普通 `rdma_resource_identity_candidate` 与 Function identity candidate 同样锁存 reserve
  后 epoch；`publish_identity_candidate()`/`create_function()` 在 authoritative 构造窗口
  返回后拒绝 stale reservation，并先回滚 allocator/binding reservation。
- Function 创建的 freshness、authoritative 完整性、registry publication 与失败回滚由
  `publish_function_identity_candidate()` 统一承载，`create_function()` 不再复制第二份
  publication 骨架。
- `commit_resource_publication()` 继续执行 stage→commit stale epoch、canonical key/identity
  和 duplicate incarnation gate；manager 仍是 registry、incarnation owner/handle 与
  known-generation 四份 ledger 的唯一 owner。新增 probe epoch observation 与
  reserve→mutation→publish rollback 矩阵，保留 concurrent create、hostile candidate 和
  duplicate commit 测试。
- `rdma_resource_manager_test`、`rdma_control_plane_test`、`rdma_qp_lifecycle_test`、
  `rdma_queue_lifecycle_test` 在 VCS53 PROCESS/LOGICAL PASS，UVM WARNING/ERROR/FATAL 均为
  `0/0/0`；Python 293/293、changed-SV style、`git diff --check`、queue/profile/
  Phase-1A gates PASS。详见 `task-rdma-batch199-publication-epoch-gate-report.md`。
- 本批只关闭 publication projection 的 epoch consistency seam，不关闭 allocator/registry
  跨线程或跨进程互斥、manager 更广泛外部调用窗口、SRQ 全生命周期、跨 queue/engine 并发、
  SQD/SQE drain/flush、legacy descriptor、外部 ordering/error/backpressure、Phase-1C F2
  whole-plan 或最终 ownership 审计；计划继续保持 `active`。

### Batch200：resource allocator pure-value policy（已完成本批，计划仍 active）

- 新增 `src/core/rdma_resource_allocator_policy.sv`，集中 `valid_kind()` 和
  `local_id_limit()` 的静态资源集合/硬件宽度映射；policy 无状态，不读取 manager
  registry、free-list、generation 或外部 adapter。
- `rdma_resource_manager` 的兼容 wrapper 仅转发到 policy，manager 继续唯一拥有
  reservation、回收、serial、binding 和 publication epoch；create/release 业务顺序与
  错误优先级不变。
- `rdma_resource_manager_test` 增加合法 kind、各资源宽度、FUNCTION/CMQ fallback 与
  未知枚举 fail-closed 矩阵。详见 `task-rdma-batch200-resource-allocator-policy-report.md`。
- 本批只收缩 allocator 静态决策，不关闭跨线程/跨进程互斥、manager 外部调用窗口、SRQ
  全生命周期、跨 queue/engine 并发、SQD/SQE drain/flush、legacy descriptor、外部
  ordering/error/backpressure、Phase-1C F2 whole-plan 或最终 ownership 审计；计划继续
  保持 `active`。

### Batch201：SRQ preflight pure-value policy（2026-09-25）

- 新增 `src/core/rdma_srq_preflight_value_policy.sv`，把 SRQ `max_sge > 2` 的 SGB
  判定、depth/max_sge/14-bit limit 边界和 borrowed backing 角色集合提取为无状态纯值
  policy；`rdma_queue_lifecycle_policy::preflight()` 仍保留 common request/authority、
  PD dependency、backing clone、ring layout 和 publication 顺序。
- `rdma_queue_lifecycle_test` 增加 SGB threshold、标量边界、缺失/多余/空 slice 矩阵；
  VCS53 queue-lifecycle focused 与 dpu_common integration focused 均 PROCESS/LOGICAL
  PASS，UVM WARNING/ERROR/FATAL 为 `0/0/0`；Python `293/293`、changed-SV style、
  queue/profile/Phase-1A、`git diff --check` 均 PASS。详见
  `task-rdma-batch201-srq-preflight-value-policy-report.md`。
- 本批不关闭 SRQ 完整 create/post/recovery/destroy 组合、allocator/registry 并发、跨
  queue/engine 并发、SQD/SQE drain/flush、legacy descriptor、外部 ordering/error/
  backpressure、Phase-1C F2 whole-plan 或最终 ownership 审计；计划继续保持 `active`。

### Batch202：borrowed ring single-role policy（2026-09-25）

- 新增 `src/core/rdma_queue_borrowed_role_policy.sv`，统一 CQ、CEQ、AEQ borrowed
  backing 的 null spec、null slice、错误 role、空 slice 和重复合法 role 判定；policy
  只消费 detached backing 值，不读取 manager、runtime、authority、lock 或外部
  Host-memory/PCIe backing。
- `rdma_queue_lifecycle_policy` 删除重复的 `backing_role_count()`，三类 preflight
  保留各自的错误文案，并通过公共纯值策略完成单一 ring-role admission；authority、
  vector/PD dependency、ring layout、backing clone 和 publication owner 未移动。
- `rdma_queue_lifecycle_test` 增加空 spec、合法 role、错误 role 和 null slice 矩阵。
  VCS53 queue-lifecycle 与 dpu_common integration focused 均 PROCESS/LOGICAL PASS，
  UVM warning/error/fatal 为 `0/0/0`；Python `293/293`、changed-SV style、queue/
  profile/Phase-1A、`git diff --check` 均 PASS。详见
  `task-rdma-batch202-borrowed-role-policy-report.md`。
- 本批只关闭 borrowed ring 单角色纯值校验重复，不关闭 allocator/registry 并发、
  manager 外部调用窗口、SRQ 全生命周期、跨 queue/engine 全局原子性、SQD/SQE
  drain/flush、legacy descriptor、外部 PCIe ordering/error/backpressure、Phase-1C F2
  whole-plan 或最终 ownership 审计；计划继续保持 `active`。

### Batch203：queue role cardinality policy（2026-09-25）

- 新增 `src/core/rdma_queue_role_cardinality_policy.sv`，统一 detached queue plan 的
  `flush_targets`/`refs` role 计数、null 元素处理和最后命中 index 规则；policy 不读取
  registry、recovery、allocator、runtime lock 或外部 backing。
- `rdma_resource_manager` 保留 `queue_flush_role_count()`/
  `queue_ref_role_count()` 兼容 wrapper，但实现转发到公共纯值 policy；progress snapshot、
  recovery authority、前驱顺序和一次性 registry/recovery commit owner 均未移动。
- `rdma_resource_manager_test` 增加 null/empty/single/duplicate/null-element 矩阵。
  VCS53 resource-manager focused PROCESS/LOGICAL PASS，UVM warning/error/fatal 为
  `0/0/0`；随后 core regression 达到 `97/97 PROCESS`、`80/80 LOGICAL`，dpu_common
  integration regression 达到 `10/10` pristine；Python `293/293`、changed-SV style、
  queue/profile/Phase-1A 和 `git diff --check` 均 PASS。详见
  `task-rdma-batch203-role-cardinality-policy-report.md`。
- 本批只关闭 queue role-cardinality 扫描重复，不关闭 allocator/registry 并发、manager
  外部调用窗口、SRQ 全生命周期、跨 queue/engine 全局原子性、SQD/SQE drain/flush、
  legacy descriptor、外部 PCIe ordering/error/backpressure、Phase-1C F2 whole-plan 或
  最终 ownership 审计；计划继续保持 `active`。

### Batch204：publication mutation guard（2026-09-25）

- `rdma_resource_manager` 新增单一 `mutation_guard`，只覆盖已经完成 detached
  validation 且不再调用 factory/adapter 的最终 registry/recovery/epoch 写入窗口；
  `commit_resource_publication()`、`commit_qp_progress()`、`commit_queue_progress()`
  忙时返回 `RDMA_SC_RESOURCE_BUSY`，不写入半成品。
- guard 不复制 ledger、allocator 或外部 backing 所有权；stage projection、reservation、
  recovery admission 和业务错误顺序仍由 manager 原有 caller 持有。测试 probe 注入
  publication contention，验证 candidate/registry 原子不变。
- resource-manager focused、core `97/97 PROCESS` + `80/80 LOGICAL`、dpu_common
  integration `10/10` pristine、Python `293/293`、CMQ manifest `23/23`、style/queue/
  profile/Phase-1A/diff 门禁均 PASS。详见
  `task-rdma-batch204-publication-mutation-guard-report.md`。
- 本批只关闭三个 detached commit seam 的最终写入竞争窗口，不关闭完整 registry/allocator
  跨线程或跨进程互斥、SRQ 全生命周期、跨 queue/engine 全局原子性、SQD/SQE drain/flush、
  legacy descriptor、PCIe ordering/error/backpressure、Phase-1C F2 whole-plan 或最终
  ownership 审计；计划继续保持 `active`。

### Batch205：queue destroy flush transaction seam（2026-09-25）

- `rdma_queue_lifecycle_executor.sv` 新增受保护 `execute_destroy_flush_step()`，统一
  SRQ 前置和 CQ/CEQ/AEQ 删除后 OCC flush 的 descriptor 构造、单次 legacy CMQ execute、
  live binding fence、AMBIGUOUS 输出和 `record_queue_flush_complete()` 提交；task 只消费
  已完成 recipe/cardinality 校验的 detached target，不持有 plan、registry、recovery
  ledger 或 backing。
- `destroy_locked()` 的 flush-before-delete 与 delete-before-flush 两个循环改为复用
  该 task；`ambiguous_op`、`hardware_absent`、completed step、cleanup、finalize 和
  recovery 顺序保持在 caller，未改变 SRQ/CQ/CEQ/AEQ 业务语义。
- `rdma_queue_lifecycle_test` 在 VCS53 PROCESS/LOGICAL PASS，UVM WARNING/ERROR/FATAL
  为 `0/0/0`；changed-SV style、queue lifecycle checker 与 `git diff --check` 通过。详见
  `task-rdma-batch205-destroy-flush-transaction-seam-report.md`。
- 本批只关闭 queue destroy OCC flush 的重复事务 seam，不关闭 SRQ 完整
  create/post/recovery/destroy 组合、allocator/registry 并发、跨 queue/engine 全局原子性、
  SQD/SQE drain/flush、legacy descriptor、PCIe ordering/error/backpressure、manager 外部
  调用窗口、Phase-1C F2 whole-plan 或最终 ownership 审计；计划继续保持 `active`。

### Batch206：queue recovery OCC flush transaction seam（2026-09-25）

- `rdma_queue_lifecycle_executor.sv` 新增受保护 `execute_recovery_flush_step()`，统一
  recovery OCC target 的 descriptor 构造、单次 `execute_queue_command()`、generation fence
  和 `record_queue_flush_complete()`；task 返回 `execute_failed`/`progress_failed` 阶段证据，
  不修改 `queue_plan.flush_complete` 或 recovery ledger。
- `recover_locked()` 的 pre-delete barrier 与 post-delete retry 两个循环复用该 task，仍
  由 caller 独占 ambiguous ticket/role、hardware presence、completion 标志、持久化和
  下一阶段状态机；原有错误文案和 retry 顺序保留。
- `rdma_queue_lifecycle_test` 与 `rdma_queue_recovery_test` 在 VCS53 均 PROCESS/LOGICAL
  PASS，UVM WARNING/ERROR/FATAL 为 `0/0/0`；changed-SV style、queue lifecycle checker
  与 `git diff --check` 通过。详见 `task-rdma-batch206-recovery-flush-transaction-seam-report.md`。
- 本批只关闭 queue recovery OCC flush 的重复事务 seam，不关闭 SRQ 完整
  create/post/recovery/destroy 组合、allocator/registry 并发、跨 queue/engine 全局原子性、
  SQD/SQE drain/flush、legacy descriptor、PCIe ordering/error/backpressure、manager 外部
  调用窗口、Phase-1C F2 whole-plan 或最终 ownership 审计；计划继续保持 `active`。

### Batch207：queue cleanup recipe policy（2026-09-25）

- 新增 `src/core/rdma_queue_cleanup_recipe_policy.sv`，把 detached cleanup plan 的
  flush role/phase cardinality、local role 唯一性、SRQ 可选 `SRQ_SGB`、context 标记和
  reverse-release 顺序集中校验；policy 不读取 manager、registry、recovery、runtime
  lock 或外部 backing。
- `destroy_locked()` 仅保留 recipe 生成与实际 quiesce/CMQ/local cleanup/finalize 业务，
  通过一次 policy `validate()` 替换原内联重复扫描；错误码和诊断文案保持不变。
- `rdma_queue_lifecycle_test` 增加 canonical CQ plan 与 duplicate-role hostile 矩阵；VCS53
  PROCESS/LOGICAL PASS，UVM WARNING/ERROR/FATAL 为 `0/0/0`；changed-SV style、queue
  lifecycle checker 与 `git diff --check` 通过。详见
  `task-rdma-batch207-cleanup-recipe-policy-report.md`。
- 本批只收束 cleanup recipe 纯值 admission，不关闭 SRQ 完整 create/post/recovery/destroy
  组合、allocator/registry 并发、跨 queue/engine 全局原子性、SQD/SQE drain/flush、legacy
  descriptor、PCIe ordering/error/backpressure、manager 外部调用窗口、Phase-1C F2
  whole-plan 或最终 ownership 审计；计划继续保持 `active`。

### Batch208：CQ shadow replay authority policy（2026-09-25）

- 新增 `src/core/rdma_cq_shadow_replay_policy.sv`，统一 CQ shadow caller/cache 的 kind、
  Function UID、generation、reset epoch 和 object ID 校验；caller stale 保持
  `RDMA_SC_STALE_GENERATION`，cache integrity mismatch 显式映射为
  `RDMA_SC_INVALID_STATE`。
- `rdma_cq_engine::flush_shadow()` 复用该纯值 policy；canonical cache、detached replay
  clone、URC evidence、flush count 和 exactly-once owner 仍由 facade 持有，CI/arm/sequence
  继续被 canonical cache 覆盖。
- `rdma_cq_shadow_flush_test`、`rdma_cq_engine_test`、`rdma_cq_engine_resize_test` 在
  VCS53 均 PROCESS/LOGICAL PASS，UVM WARNING/ERROR/FATAL 为 `0/0/0`；changed-SV style、
  queue lifecycle checker 与 `git diff --check` 通过。详见
  `task-rdma-batch208-cq-shadow-replay-policy-report.md`。
- 本批只收束 CQ shadow replay authority 纯值门禁，不关闭跨 queue/engine 并发、SRQ
  完整 lifecycle、legacy descriptor、PCIe ordering/error/backpressure、manager 外部调用
  窗口、Phase-1C F2 whole-plan 或最终 ownership 审计；计划继续保持 `active`。
