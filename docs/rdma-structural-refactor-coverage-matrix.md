# RDMA 结构重构覆盖矩阵

本矩阵把结构重构批次、职责边界、验证入口和遗留风险放在同一张可审查的表中。
它描述的是本项目模型/仿真契约覆盖，不等价于 Linux 驱动或真实 DUT 认证；所有
外部 PCIe、Host-memory 和 dpu_common 对象仍由各自环境拥有。

## 业务与验证映射

| 业务边界 | 已落地的结构 seam | 主要验证入口 | 当前状态 | 遗留边界 |
| --- | --- | --- | --- | --- |
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
| environment/backing composition | Batch91 复审 env/config、queue backing access、responder registry 的 detached snapshot、borrowed adapter、claim/seal 和 Function-incarnation 契约；Batch105 candidate detached value-graph seal 与 hostile cross-context mutation 拒绝；Batch106 env-local reset reentrancy guard；Batch107 reset 后 registration incarnation 刷新；Batch108 coordinator↔env↔router ownership seam 只读审计；Batch109 严格一对一 lease/token、bilateral attach/detach、close 和 capability handshake；Batch110 coordinator publication guard 与同步 callback 拒绝；Batch111 legacy Host epoch callback capability seal 与 direct mutation guard；Batch112 tokenless dataplane reset admission、opaque allocate rollback、cleanup drain 与 fresh-incarnation recovery | `rdma_env_composition_test`、`rdma_queue_backing_access_test`、`rdma_responder_registry_test`、`rdma_reset_candidate_integrity_test`、`rdma_device_env_test`、`rdma_host_mem_router_test`、`rdma_reset_coordinator_lifecycle_test`、reset integration suites | Batch91 focused、Batch101/103 reset integration、Batch105/106 focused、Batch107 integration/CMQ/core regression、Batch109 focused 与 integration 10/10、Batch110 focused 6 项与 integration 10/10/CMQ/core GREEN；Batch111 focused/lifecycle、integration 10/10、CMQ 28/28+11/11、core 95/95+78/78 与 Python 292 均在当前 worktree GREEN；Batch112 focused host-router/coordinator、integration 10/10、Python 292、style/diff GREEN，UVM 0/0/0；全目录 scanner 185 `.sv`+2 `.svh`、5,387 methods、0 diagnostics，静态辅助门禁通过 | coordinator 的跨线程/跨进程全局并发锁、跨环境 callback 语义、manager 外部调用窗口补偿与更深生命周期/所有权审计仍开放 |
| SQ payload transaction | Batch92 把 receipt/Function/SGE/mapping candidate staging 前移到 refs++/Host I/O 之前，并归一化外部 null status | `rdma_sq_payload_writer_test`、queue-data post paths | Batch92 focused GREEN；Batch89–93 后 parent gate GREEN | Host-memory partial write 后的补偿语义仍由 writer/adapter 契约维护 |
| CMQ poison/recovery contract | Batch93 校正 poison 的 FIFO 清理、diagnostic staging fallback 和 fail-closed 失败边界说明 | `rdma_cmq_engine_test`、`rdma_cmq_completion_test`、CMQ gate | Batch93 focused GREEN；parent gate GREEN（28/28、11/11、UVM 0/0/0） | 尚未加入同一 poll late-final+malformed CQE 的组合 fault fixture |
| codec/profile/wire | Batch9–26、68、72–75 的 tuple/profile/mask/CQE metadata 与 hostile factory fixture；Batch100 RC inline-SGB fixed-capacity guard（512B/32 chunks）；Batch113 writer 对已编码 image/SGB signature 的 fail-closed 校验；Batch114 UD transport-aware `INLINE_SGB`/`SGE_SGB` effective mode | codec/profile/driver-field mutation tests、`rdma_defs`、`rdma_sq_codec_test`、`rdma_queue_codec_test`、`rdma_ud_urc_sqe_codec_test`、`rdma_queue_data_engine_post_test` | Batch100 focused GREEN（3/3 wrapper、PROCESS/LOGICAL PASS、UVM 0/0/0）；Batch113/114 focused GREEN；保留冻结 wire 坐标和 reserved bits | 完整公开 UD post/replay 矩阵、8-bit XOR 多点抵消限制与 Phase 1C F2 whole-plan 收口仍 OPEN；不将局部 gate 误称为 ABI/F2 全量修复 |
| Function context/binding | Batch87 候选式 build/reset/activate、identity consistency、owner handle 与 PCIe projection；Batch95 延迟 registration；Batch98 reset preflight；Batch101 跨 context prepare/commit 原子性；Batch105 candidate fingerprint/value-graph seal；Batch106 coordinator epoch staging、registration incarnation 与 router-local capacity 预检；Batch107 reset 后 stale registration 拒绝与 current baseline refresh；Batch109 三条 commit seam 的 generation/epoch provenance seal 与 leased mutation authorization；Batch110 coordinator publication guard；Batch111 coordinator/router direct mutation guard 与 opaque Host epoch publication capability；Batch112 tokenless dataplane admission 与 reset 后 fresh context recovery | `rdma_function_context_test`、`rdma_env_composition_test`、`rdma_device_env_test`、`rdma_reset_cascade_test`、`rdma_reset_candidate_integrity_test`、`rdma_reset_coordinator_test`、`rdma_reset_coordinator_lifecycle_test`、`rdma_host_mem_router_test` | Batch98/101/105/106 focused、Batch107 integration/CMQ/core regression、Batch109 focused 与 integration 10/10、Batch110 focused 6 项与 integration/CMQ/core GREEN，UVM 0/0/0；Batch101 关闭跨 context 半提交窗口，Batch106 关闭普通 scope 的部分 epoch bump 窗口，Batch107 关闭 reset 后旧 registration 快路径，Batch109 关闭 tokenless leased mutation 绕过，Batch110 关闭同步 publication callback 重入，Batch111 关闭 legacy Host epoch capability bypass；Batch112 focused host-router/coordinator 与 integration 10/10、Python/style/diff 均 GREEN | coordinator 的跨线程/跨进程全局并发锁、全目录生命周期/所有权复审、manager 外部调用窗口补偿及最终注释审查仍开放 |
| SR-IOV/PCIe allocator | Batch87 null status、pre-existing ownership guard、BAR rollback、lease factory atomicity；Batch90 清理多 VF 失败时 `discovered` 部分输出并加入 VF1 注入；当前接入 `pcie_work` main 的真实 config-proxy/SR-IOV 路径 | `rdma_sriov_enumerator_authority_test`、`rdma_sriov_enumeration_test`、`rdma_pcie_work_adapter_test`、allocator focused | core authority GREEN；依赖锁 verify GREEN；`rdma_pcie_work_adapter_test` compile/elab/link 与仿真 GREEN（UVM 4/0/0/0）；`rdma_sriov_enumeration_test` compile/elab/link 与仿真 GREEN（UVM 260/0/0/0） | pcie_work 上游缺少 root README/LICENSE/tag，需保留供应链风险；host_mem/pcie_work 完整 regression、更多 PCIe error/ordering matrix 仍开放 |
| 外部环境与门禁 | dpu_common identity authority；VCS53 wrapper；manifest/style/diff gates；全目录中文契约 scanner；Batch106 focused reset evidence；Batch107 current-source static and parent/core/integration evidence；Batch109 ownership/close/candidate evidence；Batch110 publication-guard evidence；Batch111 mutation-guard/capability evidence；Batch113 SGB writer mutation evidence；Batch114 UD effective-mode evidence；Batch118 reservation-candidate seam evidence；Batch119 recovery-action contract evidence；Batch120 device-producer replay seam evidence；Batch121 consumer recovery seam evidence；Batch122 local-resource match/projection seam evidence；Batch123 consumer-authority preflight evidence；Batch124 consumer release seam evidence；Batch125 poll candidate-staging evidence；Batch126 poll target-resolution evidence；Batch127 poll commit-candidate evidence；Batch128 event commit-candidate evidence；Batch130 private-RQ poll evidence；Batch131 staged WQ canonicalization/UD SEND poll evidence；Batch132 shared-SRQ receive poll evidence；Batch133 variant/SRFQ admission、shared-SRQ hostile poll 与 transport capability evidence；pcie_work adoption/lock/adapter/SR-IOV evidence | `scripts/run_vcs53.sh`、Python 292、manifest 22、`rdma_defs` 203、style、diff-check、current-source contract scanner、Batch111 reset/integration/CMQ/core suites、resource-manager/AEQE/recovery/post focused tests、`rdma_queue_data_engine_poll_test`、`rdma_queue_data_engine_post_test`、queue-data recovery/device-publish focused tests、`rdma_queue_event_route_consume_test`、`rdma_aeqe_route_test`、codec focused tests、`tools/check_external_dependency_lock.py` | Batch113/114 post/codec suites PROCESS/LOGICAL PASS、UVM 0/0/0；Batch118 device-publish/recovery/post PROCESS/LOGICAL PASS、UVM 0/0/0；Batch119 device-publish/recovery/post focused PROCESS/LOGICAL PASS、UVM 0/0/0；Batch120 device-publish/recovery/post focused PROCESS/LOGICAL PASS、UVM 0/0/0；Batch121 device-publish/recovery/post focused GREEN，PROCESS/LOGICAL PASS、UVM 0/0/0；Batch122 resource-manager/AEQE/recovery/post focused GREEN，PROCESS/LOGICAL PASS、UVM 0/0/0；style/keyword/diff/queue/profile/manifest/Phase-1A/Python gates GREEN；Batch123 device-publish/recovery/post focused PROCESS/LOGICAL PASS、UVM 0/0/0，全目录 scanner 185 `.sv`+2 `.svh`、5,407 methods/0 diagnostics；Batch124 device-publish/recovery/post focused PROCESS/LOGICAL PASS、UVM 0/0/0，全目录 scanner 185 `.sv`+2 `.svh`、5,408 methods/0 diagnostics；Batch125 poll/device-publish/recovery/post focused PROCESS/LOGICAL PASS、UVM 0/0/0，全目录 scanner 185 `.sv`+2 `.svh`、5,409 methods/0 diagnostics；Batch126 poll/post/recovery/device-publish focused PROCESS/LOGICAL PASS、UVM 0/0/0，全目录 scanner 185 `.sv`+2 `.svh`、5,410 methods/0 diagnostics；Batch127 poll/post/recovery/device-publish focused PROCESS/LOGICAL PASS、UVM 0/0/0，全目录 scanner 185 `.sv`+2 `.svh`、5,411 methods/0 diagnostics；Batch128 poll/event route focused PROCESS/LOGICAL PASS、UVM 0/0/0（`rdma_queue_data_engine_poll_test`、`rdma_queue_event_route_consume_test`、`rdma_aeqe_route_test`）；Batch130 poll/post/recovery/device-publish focused PROCESS/LOGICAL PASS、UVM 0/0/0，其中 poll 新增私有 RQ receive CQE 正向链；Batch131 poll/post/recovery/device-publish focused PROCESS/LOGICAL PASS、UVM 0/0/0，其中 poll 新增 UD SEND 正向链和 staged hostile canonicalization probe；Batch132 poll/post/recovery/device-publish focused PROCESS/LOGICAL PASS、UVM 0/0/0，其中 poll 新增 shared-SRQ receive CQE 正向链；Batch133 poll/post/recovery/device-publish focused PROCESS/LOGICAL PASS、UVM 0/0/0，transport E2E UVM INFO 32/WARNING 0/ERROR 0/FATAL 0；pcie_work/host_mem lock verify GREEN；adapter 与 SR-IOV focused 分别 UVM INFO 4/260、WARNING/ERROR/FATAL 全为 0；全目录 scanner 刷新为 5,431 methods/0 diagnostics，style/diff/queue/profile/manifest/keyword/Phase-1A/Python 292 GREEN | 任何 VCS 仿真必须继续在 53 主机登录 shell 执行；host_mem/pcie_work 完整 regression、coordinator 跨线程/跨进程并发、更深生命周期审计、公开 UD replay 与外部 ordering/error matrix 仍开放 |

| queue-data device-producer publish admission | Batch158 将 `publish_cqe()`、`publish_ceqe()` 与 `publish_aeqe_common()` 重复的 `reserve_device_producer()`/expected-polarity 检查提取为 `reserve_device_publish_checked()` 与 `check_device_publish_polarity()`；CQE/CEQE 继续 reservation→polarity→codec，AEQE 继续 image staging→reservation→route/epoch recheck→polarity→commit | `rdma_queue_data_engine_device_publish_test`、`rdma_queue_data_engine_poll_test`、`rdma_aeqe_route_test`、`rdma_aeqe_f5_e2e_test` | Batch158 四项 VCS53 最终源码边界均 wrapper rc=0、PROCESS/LOGICAL PASS，UVM `INFO=220/3/3/115`、WARNING/ERROR/FATAL 全为 0；`git diff --check`、changed-SV style、queue/profile/Phase-1A/Python 292 与全目录 scanner 5,485 methods/0 diagnostics GREEN | authority/codec 顺序、AEQE reservation 后 route/epoch 窗口、write/commit recovery、跨队列并发、SRQ lifecycle、legacy descriptor、外部 PCIe ordering/error、engine-level 全局锁和最终 ownership 审计仍 OPEN |

| CMQ shared transport envelope decode | Batch159 将 observed submit 与 recovery submit 重复的 transport envelope 解码提取为 `decode_transport_envelope()`；统一输出 detached operation status、observation code/message 与 raw submission effect，保留 observed/recovery context 的文案差异和 malformed effect 覆盖规则；observer arm、effect fold、分类、journal/CAS mutation 仍留在 caller | `rdma_cmq_engine_test`（18-process logical runner） | Batch159 VCS53 wrapper rc=0，18/18 PROCESS PASS、1/1 LOGICAL PASS，18 个 UVM report 均 pristine（WARNING/ERROR/FATAL 全为 0）；静态 gates、Python 292/292 与全目录 scanner 5,488 methods/0 diagnostics GREEN | malformed observed/recovery 组合的更广泛矩阵、跨队列/跨线程并发、engine-level 全局锁、SRQ lifecycle、legacy descriptor、外部 ordering/error、完整 CMQ/core regression、typed URC factory 与最终 ownership/Phase-1C F2 审计仍 OPEN |

> 当前口径更新（2026-09-23）：上表“外部环境与门禁”行末的 5,431 methods 是
> Batch133 历史边界，不是当前总数。Batch159 当前 scanner 为 189 文件（187 `.sv`、
> 2 `.svh`）、5,488 methods（`.sv` 5,486、`.svh` 2）、0 diagnostics；当前刷新了
> CMQ engine 的 18-process shared-decoder focused 与相关静态门禁，完整 CMQ/core gate 仍未重跑。表中
> 早期行使用的“当前 worktree”均指对应批次当时的源码边界，不指 Batch159 当前源码边界。

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
