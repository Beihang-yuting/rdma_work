# RDMA 结构重构覆盖矩阵

本矩阵把结构重构批次、职责边界、验证入口和遗留风险放在同一张可审查的表中。
它描述的是本项目模型/仿真契约覆盖，不等价于 Linux 驱动或真实 DUT 认证；所有
外部 PCIe、Host-memory 和 dpu_common 对象仍由各自环境拥有。

## 业务与验证映射

| 业务边界 | 已落地的结构 seam | 主要验证入口 | 当前状态 | 遗留边界 |
| --- | --- | --- | --- | --- |
| CMQ 值比较与提交证据 | Batch1 value contract、Batch2 typed snapshot、Batch5 body value、Batch6 journal value、Batch7 reset proof、Batch8 binding value | `rdma_cmq_engine_models_test`、`rdma_cmq_codec_test`、`rdma_cmq_completion_test`、CMQ gate | GREEN；Batch86 gate 28/28 process、11/11 logical、UVM 0/0/0 | legacy `execute()` 的三个 Phase 1B consumer 尚未完全移除 |
| CMQ completion/route authority | Batch27–30 CQE/CEQE/AEQE publish authority；Batch31–37 handle/route/cursor predicates | `rdma_cq_engine_test`、`rdma_cq_shadow_flush_test`、`rdma_eq_engine_test`、`rdma_aeqe_route_test` | focused 与 parent gate GREEN | 更深的 recovery/MMIO 语义仍由 owner task 维护 |
| queue-data attachment/recovery | Batch40、46–47、52–54、55–66、78–86：context geometry、route/epoch、CQ identity、pending attachment、CEQE route；Batch113 SQ external-SGB writer 的 canonical mode/count、descriptor packing 与 image-signature gate；Batch114 UD effective mode 对齐；Batch115 `post_recv()` RQ/SRQ target-resolution helper；Batch116 `replay_pending()` host-producer recovery helper（SGB/WQE、doorbell、producer commit）；Batch117 `recover_queue()` claimed recovery attachment scan helper；Batch118 `recover_queue()` reservation-only candidate collection helper；Batch119 `recover_queue()` action/confirmation preflight、reservation cardinality 与 query-before-recover contract；Batch120 `replay_pending()` device-producer recovery helper（reservation/route/epoch、DEVICE_WRITE、readback、commit）；Batch121 `replay_pending()` consumer recovery helper（CQ route/QP/SRQ identity、shadow/doorbell、consumer commit、CQ→WQ release、completion）；Batch123 `replay_consumer_pending()` authority preflight（`validate_consumer_recovery_authority()` 的 pending shape、route/epoch、CQ/QP/SQ/RQ/SRQ/WQ 与 release-range 只读校验）；Batch124 `replay_consumer_pending()` recovery-only CQ→WQ release seam（`release_consumer_pending_wqe()` 的 begin/release/finish bilateral gate、frozen completion target 与 failure evidence）；Batch125 `poll_cqe_once` candidate staging（`stage_cq_poll_candidate()` 的 WQ route/release snapshot、completion/result/pending、next cursor 与 shadow/doorbell preparation，首个 `enter_recovery_prepared()` mutation 保留在 caller） | `rdma_queue_data_engine_poll_test`、`rdma_queue_data_engine_post_test`、`rdma_queue_data_engine_recovery_test`、`rdma_queue_data_engine_device_publish_test`、`rdma_queue_event_route_consume_test` | Batch86 focused 与 integration GREEN；Batch113 post-test baseline/mutation focused GREEN；Batch114 UD 1B inline/1-SGE/2-SGE writer focused GREEN；Batch115 post/recovery focused 与公开 UD post/replay probe GREEN；Batch116 recovery/post focused GREEN；Batch117 device-publish/recovery/post focused GREEN；Batch118 device-publish/recovery/post focused GREEN；Batch119 device-publish/recovery/post focused GREEN，PROCESS/LOGICAL PASS、UVM 0/0/0；Batch120 device-publish/recovery/post focused GREEN，PROCESS/LOGICAL PASS、UVM 0/0/0；Batch121 device-publish/recovery/post focused GREEN，PROCESS/LOGICAL PASS、UVM 0/0/0，style/diff/queue/profile/manifest/keyword/Phase-1A/Python 门禁 GREEN，queue-data engine/device-publish test 逐文件 method scanner 139/122、0 diagnostics，全目录 scanner 5,405 methods/0 diagnostics；Batch123 device-publish/recovery/post focused PROCESS/LOGICAL PASS、UVM 0/0/0，style/diff/queue/profile/manifest/keyword/Phase-1A/Python 门禁 GREEN，queue-data engine/device-publish test 逐文件 method scanner 140/122、0 diagnostics，全目录 scanner 5,407 methods/0 diagnostics；Batch124 device-publish/recovery/post focused PROCESS/LOGICAL PASS、UVM 0/0/0，style/diff/queue/profile/manifest/keyword/Phase-1A/Python 门禁 GREEN，queue-data engine/device-publish test 逐文件 method scanner 141/122、0 diagnostics，全目录 scanner 5,408 methods/0 diagnostics；Batch125 poll/device-publish/recovery/post focused PROCESS/LOGICAL PASS、UVM 0/0/0，style/diff/queue/profile/manifest/keyword/Phase-1A/Python 门禁 GREEN，queue-data engine/device-publish test 逐文件 method scanner 142/122、0 diagnostics，全目录 scanner 5,409 methods/0 diagnostics | query_pending 与 runtime.recover 的窄窗口并发、claimed/reservation 扫描缺少 engine-level 全局锁、host-produced SQ/RQ/SRQ reservation query 的既有 `INVALID_STATE` 边界、unclaimed admission 后重复 claimed runtime 的迁移窗口、consumer authority/release helper 只读 seam 不形成 engine-level 全局原子锁、CQ→WQ 跨队列 release 的更广泛并发、RQ/SRQ 与 UD 正向 poll、legacy descriptor 分支、CEQ/AEQ malformed retry、SRQ 全量公开 post/recovery lifecycle、device/consumer recovery 组合矩阵与最终全目录 ownership/注释审计仍开放 |
| queue runtime | Batch37、41–42、45、48、50、53–54 的 cursor/credit/identity/value seam；Batch88 收敛 route/epoch 纯比较并完成注释合规刷新 | `rdma_queue_runtime_test`、`rdma_queue_lifecycle_test`、recovery focused suites、CMQ gate | Batch88 focused GREEN；Batch89–93 后 parent gate GREEN（28/28、11/11、UVM 0/0/0） | 不复制 runtime mutable ledger；Phase 1C F2 的全局 sge_num 收口仍暂停，RC inline-SGB 容量拒绝已由 Batch100 独立关闭 |
| resource manager | Batch38–44、51、67、74、76、79 的 segment/backing/type/owner/recovery projection；Batch89 收敛 SRQ restore flush progress；Batch97 role cardinality；Batch99 context progress authority/parity；Batch102 QP/queue transient alias audit；Batch122 `lookup_local_resource()` 的 `scan_local_resource_matches()` 只读 owner/generation/local-id/cardinality seam | `rdma_resource_manager_test`、`rdma_aeqe_route_test`、`rdma_queue_recovery_test`、`rdma_queue_data_engine_post_test`、`rdma_queue_lifecycle_test`、`rdma_qp_lifecycle_test` | Batch99/102 focused GREEN；Batch104 current parent/core gate GREEN（CMQ 28/28 process、11/11 logical；core 95/95 process、78/78 logical；UVM 0/0/0）；Batch122 resource-manager/AEQE/recovery/post focused PROCESS/LOGICAL PASS、UVM 0/0/0，style/diff/queue/profile/manifest/keyword/Phase-1A/Python gates GREEN | manager-level registry scan/projection concurrency、duplicate-live fixture、跨 incarnation lifecycle 与更深 recovery/MMIO 仍开放 |
| environment/backing composition | Batch91 复审 env/config、queue backing access、responder registry 的 detached snapshot、borrowed adapter、claim/seal 和 Function-incarnation 契约；Batch105 candidate detached value-graph seal 与 hostile cross-context mutation 拒绝；Batch106 env-local reset reentrancy guard；Batch107 reset 后 registration incarnation 刷新；Batch108 coordinator↔env↔router ownership seam 只读审计；Batch109 严格一对一 lease/token、bilateral attach/detach、close 和 capability handshake；Batch110 coordinator publication guard 与同步 callback 拒绝；Batch111 legacy Host epoch callback capability seal 与 direct mutation guard；Batch112 tokenless dataplane reset admission、opaque allocate rollback、cleanup drain 与 fresh-incarnation recovery | `rdma_env_composition_test`、`rdma_queue_backing_access_test`、`rdma_responder_registry_test`、`rdma_reset_candidate_integrity_test`、`rdma_device_env_test`、`rdma_host_mem_router_test`、`rdma_reset_coordinator_lifecycle_test`、reset integration suites | Batch91 focused、Batch101/103 reset integration、Batch105/106 focused、Batch107 integration/CMQ/core regression、Batch109 focused 与 integration 10/10、Batch110 focused 6 项与 integration 10/10/CMQ/core GREEN；Batch111 focused/lifecycle、integration 10/10、CMQ 28/28+11/11、core 95/95+78/78 与 Python 292 均在当前 worktree GREEN；Batch112 focused host-router/coordinator、integration 10/10、Python 292、style/diff GREEN，UVM 0/0/0；全目录 scanner 185 `.sv`+2 `.svh`、5,387 methods、0 diagnostics，静态辅助门禁通过 | coordinator 的跨线程/跨进程全局并发锁、跨环境 callback 语义、manager 外部调用窗口补偿与更深生命周期/所有权审计仍开放 |
| SQ payload transaction | Batch92 把 receipt/Function/SGE/mapping candidate staging 前移到 refs++/Host I/O 之前，并归一化外部 null status | `rdma_sq_payload_writer_test`、queue-data post paths | Batch92 focused GREEN；Batch89–93 后 parent gate GREEN | Host-memory partial write 后的补偿语义仍由 writer/adapter 契约维护 |
| CMQ poison/recovery contract | Batch93 校正 poison 的 FIFO 清理、diagnostic staging fallback 和 fail-closed 失败边界说明 | `rdma_cmq_engine_test`、`rdma_cmq_completion_test`、CMQ gate | Batch93 focused GREEN；parent gate GREEN（28/28、11/11、UVM 0/0/0） | 尚未加入同一 poll late-final+malformed CQE 的组合 fault fixture |
| codec/profile/wire | Batch9–26、68、72–75 的 tuple/profile/mask/CQE metadata 与 hostile factory fixture；Batch100 RC inline-SGB fixed-capacity guard（512B/32 chunks）；Batch113 writer 对已编码 image/SGB signature 的 fail-closed 校验；Batch114 UD transport-aware `INLINE_SGB`/`SGE_SGB` effective mode | codec/profile/driver-field mutation tests、`rdma_defs`、`rdma_sq_codec_test`、`rdma_queue_codec_test`、`rdma_ud_urc_sqe_codec_test`、`rdma_queue_data_engine_post_test` | Batch100 focused GREEN（3/3 wrapper、PROCESS/LOGICAL PASS、UVM 0/0/0）；Batch113/114 focused GREEN；保留冻结 wire 坐标和 reserved bits | 完整公开 UD post/replay 矩阵、8-bit XOR 多点抵消限制与 Phase 1C F2 whole-plan 收口仍 OPEN；不将局部 gate 误称为 ABI/F2 全量修复 |
| Function context/binding | Batch87 候选式 build/reset/activate、identity consistency、owner handle 与 PCIe projection；Batch95 延迟 registration；Batch98 reset preflight；Batch101 跨 context prepare/commit 原子性；Batch105 candidate fingerprint/value-graph seal；Batch106 coordinator epoch staging、registration incarnation 与 router-local capacity 预检；Batch107 reset 后 stale registration 拒绝与 current baseline refresh；Batch109 三条 commit seam 的 generation/epoch provenance seal 与 leased mutation authorization；Batch110 coordinator publication guard；Batch111 coordinator/router direct mutation guard 与 opaque Host epoch publication capability；Batch112 tokenless dataplane admission 与 reset 后 fresh context recovery | `rdma_function_context_test`、`rdma_env_composition_test`、`rdma_device_env_test`、`rdma_reset_cascade_test`、`rdma_reset_candidate_integrity_test`、`rdma_reset_coordinator_test`、`rdma_reset_coordinator_lifecycle_test`、`rdma_host_mem_router_test` | Batch98/101/105/106 focused、Batch107 integration/CMQ/core regression、Batch109 focused 与 integration 10/10、Batch110 focused 6 项与 integration/CMQ/core GREEN，UVM 0/0/0；Batch101 关闭跨 context 半提交窗口，Batch106 关闭普通 scope 的部分 epoch bump 窗口，Batch107 关闭 reset 后旧 registration 快路径，Batch109 关闭 tokenless leased mutation 绕过，Batch110 关闭同步 publication callback 重入，Batch111 关闭 legacy Host epoch capability bypass；Batch112 focused host-router/coordinator 与 integration 10/10、Python/style/diff 均 GREEN | coordinator 的跨线程/跨进程全局并发锁、全目录生命周期/所有权复审、manager 外部调用窗口补偿及最终注释审查仍开放 |
| SR-IOV/PCIe allocator | Batch87 null status、pre-existing ownership guard、BAR rollback、lease factory atomicity；Batch90 清理多 VF 失败时 `discovered` 部分输出并加入 VF1 注入 | `rdma_sriov_enumerator_authority_test`、`rdma_sriov_enumeration_test`、allocator focused | core authority GREEN；`pcie_work` integration 仍被外部锁阻断 | 不修改外部 pcie_work；需获批 snapshot 后再运行真实 integration |
| 外部环境与门禁 | dpu_common identity authority；VCS53 wrapper；manifest/style/diff gates；全目录中文契约 scanner；Batch106 focused reset evidence；Batch107 current-source static and parent/core/integration evidence；Batch109 ownership/close/candidate evidence；Batch110 publication-guard evidence；Batch111 mutation-guard/capability evidence；Batch113 SGB writer mutation evidence；Batch114 UD effective-mode evidence；Batch118 reservation-candidate seam evidence；Batch119 recovery-action contract evidence；Batch120 device-producer replay seam evidence；Batch121 consumer recovery seam evidence；Batch122 local-resource match/projection seam evidence；Batch123 consumer-authority preflight evidence；Batch124 consumer release seam evidence；Batch125 poll candidate-staging evidence | `scripts/run_vcs53.sh`、Python 292、manifest 22、`rdma_defs` 203、style、diff-check、current-source contract scanner、Batch111 reset/integration/CMQ/core suites、resource-manager/AEQE/recovery/post focused tests、`rdma_queue_data_engine_poll_test`、`rdma_queue_data_engine_post_test`、queue-data recovery/device-publish focused tests、codec focused tests | Batch113/114 post/codec suites PROCESS/LOGICAL PASS、UVM 0/0/0；Batch118 device-publish/recovery/post PROCESS/LOGICAL PASS、UVM 0/0/0；Batch119 device-publish/recovery/post PROCESS/LOGICAL PASS、UVM 0/0/0；Batch120 device-publish/recovery/post PROCESS/LOGICAL PASS、UVM 0/0/0；Batch121 device-publish/recovery/post focused GREEN，PROCESS/LOGICAL PASS、UVM 0/0/0；Batch122 resource-manager/AEQE/recovery/post focused GREEN，PROCESS/LOGICAL PASS、UVM 0/0/0；style/keyword/diff/queue/profile/manifest/Phase-1A/Python gates GREEN；Batch123 device-publish/recovery/post focused PROCESS/LOGICAL PASS、UVM 0/0/0，全目录 scanner 185 `.sv`+2 `.svh`、5,407 methods/0 diagnostics；Batch124 device-publish/recovery/post focused PROCESS/LOGICAL PASS、UVM 0/0/0，全目录 scanner 185 `.sv`+2 `.svh`、5,408 methods/0 diagnostics；Batch125 poll/device-publish/recovery/post focused PROCESS/LOGICAL PASS、UVM 0/0/0，全目录 scanner 185 `.sv`+2 `.svh`、5,409 methods/0 diagnostics；pytest 因环境缺包未执行；正确 E2E 在 host_mem hash preflight 因外部依赖 drift 阻断，不能记为业务 GREEN | 任何 VCS 仿真必须继续在 53 主机登录 shell 执行；`pcie_work` 仍 OPEN；coordinator 跨线程/跨进程并发、更深生命周期审计、公开 UD replay 与外部依赖锁仍开放 |

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
- 当前源码最终静态证据位于 `evidence/final-static.meta`、`final-static-artifact-sha256.txt`、
  `final-static-python.log`、`final-static-cmq-manifest.log`、`final-static-style.log`、
  `final-static-diff-check.log`、`final-static-contract-scan.log` 和
  `final-static-rdma_defs.log`；历史 final-static scanner 覆盖 185 个 `.sv`、2 个 `.svh`、
  5,286 个 function/task，0 diagnostics；Batch109 报告中的 5,346 是其当时的旧扫描口径，
  Batch110 当前工作树以同一 API 重新计数为 5,382 个、0 diagnostics。冻结 ABI manifest 的
  摘要更新只反映当前源码字节，未改变 wire 坐标或外部依赖；Batch111 capability 改动后的
  scanner 已重计为 5,387 个 function/task、0 diagnostics，详见 `evidence/batch111.*`。
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
   完成，并在后续源码变化后重复门禁。
4. Batch114 已关闭 UD codec 与通用 model/writer 对非零 inline/1–2 SGE 的 effective
   mode 对齐缺口；Batch115 已用临时 focused probe 补充公开 `post_send()`/
   `replay_pending()` 的 UD 1B inline/1–2 SGE 与 SGB failure recovery 证据；Batch116
   将 host-producer recovery 阶段独立为 helper 并重跑 recovery/post focused，但完整
   SRQ/跨队列 lifecycle 矩阵、device/consumer recovery 全阶段组合仍需独立证据；
   Batch117 只读拆出 claimed scan，Batch118 只读拆出 reservation-only candidate scan；
   两批均未覆盖 reservation-only 查询/abort 的所有 hostile 组合，且不能通过放宽 writer
   gate 掩盖新的 transport authority 缺口。Batch123 已在当前源码边界重新运行全目录
   scanner，当前 method/comment 计数以 5,407 methods/0 diagnostics 为准，不把 Batch111/Batch122 的旧
   计数冒充当前源码结果。
5. `pcie_work` external lock 仍为 OPEN；覆盖矩阵不替代真实外部依赖批准，在 lock 获批前
   SR-IOV integration 只能报告已知阻断，不能伪造 GREEN。

因此矩阵当前是“持续更新、计划 active”，不能据此把整份结构重构计划标记为完成。
