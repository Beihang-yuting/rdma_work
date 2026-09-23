# RDMA CMQ contract foundation 验证记录

> 本记录只描述已实现的 CMQ contract foundation 和 gate 证据，不宣称已经接入
> Linux 内核驱动或真实 DUT。所有 wire 坐标仍以锁定的 0.1.34 驱动归档为准。

## 固定基线

| 项目 | 固定值 |
| --- | --- |
| driver archive | `dpu_kernel_rdma-version_0.1.34.tar(1).gz` |
| `RDMA_ARCHIVE_SHA256` | `c9d9286dde389f681f9bd1c29fff14f52c4c1ce11fa5f73a5f1f57da9f827522` |
| archive size | `289668` bytes |
| member count / list SHA-256 | `74` / `d27331088fff104e4f101357b7a0b490b1d33e66396cb060ec421cc94ab68797` |
| source manifest SHA-256 | `76bed8a53ace52a5a010347982904f0c6e2b251be6e611d518c24a862dbdbfe3` |
| C compiler | `/usr/bin/gcc`, `gcc 9.4.0`, `x86_64-linux-gnu`, 64-bit little-endian |
| Phase 1A approval | plan commit `00ac20e8db79a92a9bd7bc7700355e6b8f4cc1d1`, blob `c521b5fe81473d922d1a466d8ecc885bf3b1c899086e9543b4445518e526280b`, approver `ryan`, `2026-09-12T14:34:29Z` |
| approved decisions | `TASK8_FOUR_STATE_EFFECT=APPROVED`; `TASK9_EXECUTION_AND_DIGEST=APPROVED`; `TASK17_RESET_ORDER=APPROVED`; `TASK18_LEGACY_SEAM=APPROVED` |

外部依赖只按 `hw/rdma/external_dependencies.tsv` 中的 approved snapshot 使用。
当前 `pcie_work` 已按用户指定上游快照批准并固定为 commit
`1a80801e7d336ceeb492e7cdf57ba26ef27c2456`（闭包 tree SHA-256
`8a9853c2cb618b5f73f4d2fed2167fad3a7b08bce37298cfef9ea159b1c5feb1`）；`host_mem` 固定为
commit `365b7553fc7dac6b4ad55886a8e4869153607c28`（tree SHA-256
`b9cd7d686c954823bdeafcea2f02013908fed51db5a8f4d39e96e5e877f6c770`）。依赖闭包 lock
verify 已通过；历史记录中的 `UNAPPROVED`/阻断文字仅描述批准前的时间点，不代表当前状态。

## 实现链与冻结语义

`rdma_cmq_engine_port_adapter` 将 production 请求路由到
`rdma_cmq_engine::execute_observed()`。每个调用返回 detached value；
`observation_status` 与普通 command status 分离，不能由空 ticket 或错误码推导
`attempt_effect`。跨 retry 的 `submission_effect` 按冻结 fold 规则累计，旧的
`HOST_VISIBLE`/`MMIO_VISIBLE`/`UNOBSERVED` 证据不能被后续
`PRE_SUBMIT_REJECTED` 覆盖。timeout ticket 进入 quarantine，迟到完成只产生诊断
而不返还信用；reset 使用 mutation-free candidate、failure-atomic backing release、
allocation-free journal commit 和 READY proof 顺序。

锁序固定为 `engine_lock -> scheduler Function transport lock`。MMIO observer 只能
更新预分配的 journal/index/cursor，不分配、等待、取锁、调用外部 service 或重入
engine。恢复映射必须重新认证 adapter-owned opaque allocation capability，公开
mapping 字段或 digest 相同也不足以证明同一次分配。

legacy `execute()` 仍暂时维护 `last_execute_no_submit_proven`，仅供以下三个尚未
迁移的 Phase 1B consumer 使用：

- `src/core/rdma_control_plane.sv`
- `src/core/rdma_queue_lifecycle_executor.sv`
- `src/core/rdma_qp_lifecycle_executor.sv`

production `execute_observed()` 不读写任何共享 `last_*` 字段；三处 consumer 完成
独立迁移后才允许删除 legacy accessor。

## CMQ gate 清单

`sim/cmq_gate.list` 的非注释行必须按以下顺序 exact-once 执行：

```text
rdma_cmq_engine_models_test
rdma_cmq_codec_test
rdma_cmq_completion_test
rdma_cmq_profile_test
rdma_doorbell_codec_test
rdma_doorbell_scheduler_test
rdma_queue_data_engine_post_test
rdma_cmq_engine_test
rdma_cmq_port_test
rdma_control_plane_cmq_engine_test
rdma_cmq_driver_field_mutation_test
```

`rdma_cmq_engine_test` 通过统一 logical runner 展开为十八个物理 process：base leaf
只承载 fixture 0–7，紧随的 base-suffix leaf 承载 fixture 8–15；capacity leaf 随后
从 fixture 16 开始。matrix leaf 仅承载 fixture 22–25，profile-wide CQE fixture
仍独占下一 process，retention-prefix 仍独占 rows 0..2，continuation 再承接 rows
3..14 与 fixture 28–29，随后 submission-profile leaf 独立承载 fixture 30–32。任一
process 的 simulator、summary 或日志检查失败都会使
logical gate 失败。mutation gate 还必须保持 `CQC_CREATE` request unsupported，并报告
其固定的 static/dynamic closed-evidence 计数。

## 记录的验收证据与刷新规则

所有 VCS 命令只通过 53 主机的 login-shell `scripts/run_vcs53.sh` 执行。以下表格按
各自记录的源码边界保留命令、exit code、日志路径和 `UVM_WARNING/ERROR/FATAL`；除非
条目明确标为当前批次，否则都属于历史证据。缺少摘要、出现 warning 或 VCS crash
都是 blocker，源码变化后不能用旧日志替代当前验收。

| Scope | Command / log | Result |
| --- | --- | --- |
| focused queue/device publish | `SSHPASS=<runtime-only> ./scripts/run_vcs53.sh core rdma_queue_data_engine_device_publish_test`; `/tmp/rdma_engine_regression_20260916/02_rdma_queue_data_engine_device_publish_test.log` | PASS; `UVM_WARNING=0`, `UVM_ERROR=0`, `UVM_FATAL=0` |
| focused AEQE route | `SSHPASS=<runtime-only> ./scripts/run_vcs53.sh core rdma_aeqe_route_test`; `/tmp/rdma_engine_regression_20260916/03_rdma_aeqe_route_test.log` | PASS; `UVM_WARNING=0`, `UVM_ERROR=0`, `UVM_FATAL=0` |
| focused CQ/EQ/RQ/SQ facades | logs `/tmp/rdma_engine_regression_20260916/04_rdma_cq_engine_test.log` through `07_rdma_sq_engine_test.log` | PASS; each `UVM_WARNING=0`, `UVM_ERROR=0`, `UVM_FATAL=0` |
| pcie_work adapter | `PCIE_WORK_ROOT=<approved snapshot> HOST_MEM_ROOT=<approved snapshot> make pcie_work TEST=rdma_pcie_work_adapter_test` on `ubuntu@10.11.10.53` login bash | PASS; exit `0`, `UVM_INFO=4`, `UVM_WARNING/ERROR/FATAL=0/0/0` |
| pcie_work SR-IOV config-proxy | same approved roots, `make pcie_work TEST=rdma_sriov_enumeration_test` on `ubuntu@10.11.10.53` login bash | PASS; exit `0`, `UVM_INFO=260`, `UVM_WARNING/ERROR/FATAL=0/0/0` |
| host_mem candidate regression | `make host_mem TEST=regression` on `ubuntu@10.11.10.53` login bash | PASS; adapter/queue-data/UMEM `UVM_INFO=17/17/4`, warning/error/fatal all zero, leak checks zero |
| queue/control-plane/QP execution seams | `SSHPASS=<runtime-only> ./scripts/run_vcs53.sh core rdma_queue_lifecycle_test`, `rdma_queue_recovery_test`, `rdma_control_plane_cmq_engine_test`, `rdma_control_plane_test`, `rdma_qp_lifecycle_test`, and `rdma_qp_recovery_test` | PASS at the recorded source boundary; each compile/elab/link and PROCESS/LOGICAL PASS with `UVM_INFO=3`, `UVM_WARNING/ERROR/FATAL=0/0/0`; Batch136–140 deduplicate rollback/create/destroy/control-plane/QP/KEY_ALLOC raw dispatch while retaining legacy compatibility |
| Batch157 focused CQ shadow/replay | `scripts/run_vcs53.sh core rdma_cq_engine_test`; `rdma_cq_engine_resize_test`; `rdma_cq_shadow_flush_test` | Current source boundary: all wrapper rc=0, PROCESS/LOGICAL PASS, UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0`, pristine; complete wrapper hashes are recorded in the Batch157 section below |
| local static gates | `git diff --check`; `python3 tools/check_changed_sv_style.py --base 8b8ad4e`; queue/profile/Phase-1A checks; manifest/keyword/ownership tests; Python discover | Batch157 current boundary PASS; combined log `/tmp/batch157-static-fix.log`, SHA-256 `73e0e60ee02883bcdda68f52e72e54f07760844a1e5db3c501376e782997d13a`; full-tree scanner is recorded below |
| final CMQ gate | `scripts/run_vcs53.sh rdma_defs rdma_cmq_driver_contract_test`; `scripts/run_vcs53.sh cmq_gate regression` | Historical source-boundary evidence: CMQ 28/28 process, 11/11 logical, UVM 0/0/0; Batch157 后尚未刷新全量 gate |
| compatibility/full core | host_mem, integration, focused consumers and `scripts/run_vcs53.sh core regression` | Historical source-boundary evidence: core 95/95 process, 78/78 logical, UVM 0/0/0; Batch157 仅刷新三项 CQ focused，完整 core 与更广 PCIe ordering/error 组合仍开放 |

### Batch138 current source boundary

`rdma_control_plane.sv` now uses `execute_control_command()` for the MR rollback,
deregister and recovery hardware-step call sites that share the same
`cmq.execute()` → `checked_status()` contract. The helper clears the current
ticket/completion, performs one legacy execution, clones the status, and rejects a
missing CMQ or command before dispatch. KEY_ALLOC remains a separate legacy path
because its success and timeout recovery branches have a different status-object
contract. This is compatibility normalization only; it does not migrate the
consumer to `execute_observed()` or establish detached ticket/completion ownership.

The focused VCS runs for this boundary are:

```text
SSHPASS=123 scripts/run_vcs53.sh core rdma_control_plane_cmq_engine_test
SSHPASS=123 scripts/run_vcs53.sh core rdma_control_plane_test
```

Both completed with PROCESS/LOGICAL PASS and UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0`.
The remaining consumer direct call is KEY_ALLOC (control-plane). Queue, control-plane and
QP each retain one helper-internal compatibility dispatch; helper-internal calls are not
counted as consumer sites.

Batch139 also applied the same raw-dispatch seam to QP lifecycle. The QP helper does not
move pre/post generation fences, ambiguity classification, completion checks, timeout
handling or recovery publication; those remain at each call site. The focused QP lifecycle
and recovery runs completed with PROCESS/LOGICAL PASS and UVM `INFO=3/WARNING=0/ERROR=0/
FATAL=0`.

Batch140 moved the remaining control-plane KEY_ALLOC call through the same helper while
preserving its legacy raw-status identity and the original timeout-ticket and
recovery/rollback branches. Batch141 then made that ownership explicit: the KEY_ALLOC
caller invokes `execute_control_command_raw_status()`, while the other control-plane
callers use `execute_control_command()` to receive a detached status. The three Phase 1B
consumer files still have no direct `cmq.execute()` call site; each keeps one
helper-internal compatibility dispatch. The two control-plane focused runs at the
Batch140 boundary remained PROCESS/LOGICAL PASS with UVM
`INFO=3/WARNING=0/ERROR=0/FATAL=0`.

### Batch141 current source boundary

`src/core/rdma_control_plane.sv` (SHA-256
`c50b305eb0a3da0489870c3496056fe381f0cf7248fd5956149befd7947de0b5`) separates the raw and detached status ownership seams.
`execute_control_command_raw_status()` performs the CMQ/command fail-closed checks,
ticket/completion initialization and exactly one legacy dispatch while preserving backend
status identity. `execute_control_command()` reuses that seam and applies
`checked_status()` to publish a detached status for MR rollback, deregistration and
recovery hardware-step paths. KEY_ALLOC keeps raw status until its existing null-status,
timeout-ticket, recovery/rollback and generation checks run; dispatch count and failure
priority are unchanged. This is a compatibility ownership clarification, not an
`execute_observed()` or detached ticket/completion migration.

The fresh 53-host login-shell runs were:

```text
SSHPASS=123 scripts/run_vcs53.sh core rdma_control_plane_cmq_engine_test
SSHPASS=123 scripts/run_vcs53.sh core rdma_control_plane_test
```

Both compiled/elaborated/linked and reported PROCESS/LOGICAL PASS with UVM
`INFO=3/WARNING=0/ERROR=0/FATAL=0`. `git diff --check`, changed-SV style,
profile naming, queue lifecycle checks and the 292 Python unit tests also passed.
The remaining boundaries are full `execute_observed()` migration, detached
ticket/completion ownership, legacy descriptor handling, cross-component concurrency and
the broader parent/core/integration regression.

### Batch142 current source boundary

At the Batch142 source boundary, `src/core/rdma_queue_data_engine.sv` had SHA-256
`b651f42066610ad7bdc844b1094e2a5471199648f9510710f06e814fe83d5876`; it staged the failure-prone AEQE image preparation
before producer reservation in `prepare_aeqe_publish_image()`. The helper clones the
caller model, replaces the encode target with a cloned live primary route, applies profile
authority, performs registry/type checks and codec encoding in the existing order, and
accepts only a complete 16-byte image. On failure it clears `encode_model` and `image`
without touching attachment, runtime, cursor, backing, pending, Host-memory or MMIO;
`publish_aeqe_common()` still owns reservation, post-reservation epoch/polarity checks,
cancel/recovery and commit ordering. CQE/CEQE reserve-before-encode behavior is unchanged.

The fresh 53-host login-shell focused runs all compiled/elaborated/linked and passed:

| Entry | Result |
| --- | --- |
| `rdma_queue_data_engine_device_publish_test` | PROCESS/LOGICAL PASS; UVM `INFO=220/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_aeqe_route_test` | PROCESS/LOGICAL PASS; UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_aeqe_f5_e2e_test` | PROCESS/LOGICAL PASS; UVM `INFO=115/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_queue_event_route_consume_test` | PROCESS/LOGICAL PASS; UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |

The same static gates and Python 292/292 unit tests passed. The remaining boundaries are
AEQE malformed retry and poll/recovery combinations, SRQ lifecycle, legacy descriptor
paths, cross-queue concurrency and the finer-grained registry null/type-fault atomicity
evidence; the plan remains `active`.

At the Batch142 source boundary, the full-tree Chinese contract scan used the shared
`sanitize_source`/`method_ranges`/`check_method_comments`/`check_file_header` logic over
`src/`, `tests/` and `sim/` SystemVerilog plus the two codec headers: 185 `.sv` files and
2 `.svh` files (187 files), 5,436 methods (`.sv` 5,434; `.svh` 2), and 0 diagnostics. This
Batch142 count excludes the `prepare_event_poll_continuation()` helper introduced by the
following batch.

### Batch143 current source boundary

At the Batch143 source boundary, `src/core/rdma_queue_data_engine.sv` had SHA-256
`20b260200fb20c41074678cfe48c27c2a628fce1988d6ef70867ef2d5754f6ab`. The batch extracted
`prepare_event_poll_continuation()` from the duplicated tail of `poll_ceqe_once()` and
`poll_aeqe_once()`: after each caller has decoded the image, resolved owner/route and built
the detached result candidate, the helper prepares pending state, the consumer doorbell
descriptor and no-allocation status. It does not perform attachment lookup, peek/read,
decode, route resolution or result cloning; it does not write Host-memory/MMIO, advance
CI/used, enter recovery, or commit runtime state. CEQ keeps `route_found`, AEQ keeps
`deliver_found`, route misses still acknowledge the event while discarding its payload, and
`commit_event_poll_candidate()` remains the sole runtime mutation/consumer-commit boundary.

The fresh 53-host login-shell focused runs were:

| Entry | Result |
| --- | --- |
| `rdma_queue_event_route_consume_test` | PROCESS/LOGICAL PASS; UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_aeqe_route_test` | PROCESS/LOGICAL PASS; UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |

`rdma_queue_data_engine_final_fix_test` is not present in the current core factory/manifest;
its invalid entry produced the expected UVM `INVTST` and was not counted as a source result.
The static gates (`git diff --check`, changed-SV style, profile naming, queue lifecycle
checker and Python 292/292) also passed. The final full-tree contract scan reported 185
`.sv` files, 2 `.svh` files (187 files), 5,437 methods (`.sv` 5,435; `.svh` 2), and
0 diagnostics. CEQ/AEQ malformed retry, doorbell-failure recovery exactly-once, CQ→WQ
release, SRQ lifecycle, legacy descriptor paths, cross-queue concurrency, an engine-level
global lock and final ownership audit remain open; the plan remains `active`.

### Batch144 current source boundary

At the Batch144 source boundary, `src/core/rdma_queue_data_engine.sv` had SHA-256
`1dfe2bf1038d2fe847e801e4f5eaad837b649c00f0efd9733427b5c448af7388`. The batch extracted
`complete_host_producer_tail()` from the duplicated reservation-success tail of
`post_send()` and `post_recv()`. After the caller has reserved a producer cursor and
encoded its WQE (with SQ-only `write_sgb_and_verify()` still remaining in `post_send()`),
the helper performs `write_and_verify()`, computes the next cursor, submits the producer
doorbell, commits the producer ledger, and constructs the detached post result. Write or
readback failure keeps `NO_SUBMIT` pending; doorbell or producer-commit failure keeps
`AMBIGUOUS` recovery evidence; pending clone failure returns `RESOURCE_EXHAUSTED`, and a
recovery-call failure cannot overwrite the first stage status. The helper does not acquire
queue/backing/request/handle lifetime ownership.

The helper consumes caller-frozen attachment, queue handle, runtime kind, cursor, image,
semantic request, `wr_id`/`signaled`, optional SQ doorbell image and local id. It does not
re-run reservation, authority or route/epoch admission. `post_recv()` retains its explicit
attachment route/epoch check before reservation; this batch does not add an independent
route/epoch check to `post_send()`, so the helper precondition must not be reported as a
completed send-path gate.

The fresh 53-host login-shell focused runs were:

| Entry | Result |
| --- | --- |
| `rdma_queue_data_engine_post_test` | PROCESS/LOGICAL PASS; UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_queue_data_engine_recovery_test` | PROCESS/LOGICAL PASS; UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_queue_data_engine_poll_test` | PROCESS/LOGICAL PASS; UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_queue_data_engine_device_publish_test` | PROCESS/LOGICAL PASS; UVM `INFO=220/WARNING=0/ERROR=0/FATAL=0` |

Changed-SV style, `git diff --check`, profile naming, queue lifecycle, Phase-1A checks and
Python 292/292 also passed. The final full-tree contract scan reported 185 `.sv` files,
2 `.svh` files (187 files), 5,438 methods (`.sv` 5,436; `.svh` 2), and 0 diagnostics.
Host-producer write/doorbell/commit hostile combinations, explicit send route/epoch
revalidation, SRQ lifecycle, legacy descriptors, cross-queue concurrency, an engine-level
global lock and final ownership audit remain open; the plan remains `active`.

### Batch145 current source boundary

At the Batch145 source boundary, `src/core/rdma_queue_data_engine.sv` has SHA-256
`dde548fb979c0dd1e694651031edc2acb469766e57d2d9f221673001016bb431`. The batch adds
`reserve_host_producer_cursor()`, which performs the frozen attachment route/epoch check and
the host-producer `reserve_producer()` call as one admission seam. `post_send()` invokes it
after SQE authority validation, while `post_recv()` invokes it after target/owner validation;
the helper returns a detached cursor only on success and has no Host-memory, MMIO, ledger or
pending side effect. A null runtime status also clears the cursor before returning its normalized
`RDMA_SC_INVALID_STATE`, so a malformed reservation implementation cannot leak a partial output.
A failed route/epoch check therefore stops a direct `post_send()` before
it can encode, write or notify an old attachment.

`rdma_queue_data_engine_post_test` adds a stale-epoch fixture that advances the binding epoch
before calling `post_send()`. It observes `RDMA_SC_STALE_GENERATION`, a null result, unchanged
SQ producer/consumer cursor and used/pending state, and unchanged Host-memory/PCIe call
counts. Fresh 53-host login-shell focused runs were:

| Entry | Result |
| --- | --- |
| `rdma_queue_data_engine_post_test` | PROCESS/LOGICAL PASS; UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_queue_data_engine_recovery_test` | PROCESS/LOGICAL PASS; UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_queue_data_engine_poll_test` | PROCESS/LOGICAL PASS; UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_queue_data_engine_device_publish_test` | PROCESS/LOGICAL PASS; UVM `INFO=220/WARNING=0/ERROR=0/FATAL=0` |

The local static gates (`git diff --check`, changed-SV style, profile naming, queue
lifecycle, Phase-1A and Python 292/292) passed. The full-tree contract scan reported 185
`.sv` files, 2 `.svh` files (187 files), 5,440 methods (`.sv` 5,438; `.svh` 2), and
0 diagnostics. This batch closes the direct send stale-epoch admission seam and the duplicated
route-check→reserve orchestration; reservation-after-route-change windows, hostile producer
fault combinations, SRQ lifecycle, legacy descriptor paths, cross-queue concurrency, an
engine-level global lock and final ownership audit remain open, so the plan remains `active`.

### Batch148 current source boundary

At the Batch148 source boundary, `src/core/rdma_queue_data_engine.sv` has SHA-256
`ca11b30a716b7672b8a648457475dc45cd122f33107b879e0c40738bddb1b509`. The batch continues
the queue-data contraction with `snapshot_attachment_route_epoch()`,
`reserve_host_producer_cursor()`, `validate_host_producer_reservation_window()` and
`commit_host_producer_ledger()`. These helpers keep route/reset-epoch evidence adjacent to
producer admission, revalidate the narrow post-reservation window before the first external
side effect, and leave PI/used/slot ownership in `attachment.runtime`.

`admit_host_producer_recovery()` and `install_host_producer_recovery()` now provide the
single recovery admission/install path for WQE, readback, SGB, doorbell and producer-commit
failures. `complete_host_producer_tail()` owns the common write/readback → next cursor →
doorbell → ledger commit → detached result sequence. Nonfatal raw factories and the
fail-closed pending-handle clone preserve the first stage status and prevent a post-commit
factory failure from fabricating a second mutation. Pending evidence always retains the
reservation-frozen route/epoch; SQ external-SGB gate failure is represented as `NO_SUBMIT`
through the same installer.

The fresh 53-host login-shell focused runs were:

| Entry | Result |
| --- | --- |
| `rdma_queue_data_engine_post_test` | PROCESS/LOGICAL PASS; UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_queue_data_engine_recovery_test` | PROCESS/LOGICAL PASS; UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_queue_data_engine_poll_test` | PROCESS/LOGICAL PASS; UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_queue_data_engine_device_publish_test` | PROCESS/LOGICAL PASS; UVM `INFO=220/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_queue_host_producer_failure_final_fix_test` | PROCESS/LOGICAL PASS; UVM `INFO=27/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_queue_host_producer_commit_failure_test` | PROCESS/LOGICAL PASS; UVM `INFO=8/WARNING=0/ERROR=0/FATAL=0` |

The recovery fixture additionally flips reset epoch after SGB staging and confirms stale
replay is rejected without new I/O; the commit-fault fixture confirms WQE/readback and
doorbell success followed by ledger-commit failure leaves `AMBIGUOUS` pending evidence,
unchanged PI/CI/used and only public abort convergence. Local style/diff/profile/queue/
Phase-1A/manifest/keyword gates and all 292 Python unit tests passed. The full-tree Chinese
contract scan reports 185 `.sv`, 2 `.svh`, 5,460 methods (`.sv` 5,458; `.svh` 2), and
0 diagnostics. The queue-lifecycle 53-host regression was launched separately and its final
core/integration aggregate remains a required gate; focused GREEN does not substitute for it.

Reservation-after-route-change concurrency, unclaimed/admission failure evidence,
cross-queue release, SRQ full lifecycle, legacy descriptors, external PCIe error/ordering
combinations, an engine-level global lock and final ownership audit remain open; the plan
continues to be `active`.

### Batch149 current source boundary

Batch149 extracts `resolve_reservation_only_recovery()` from the `recover_queue()`
found==null branch. The helper collects every attachment with the target queue's complete
incarnation, queries each runtime reservation before any detach, rejects multiple valid
reservations without cancellation, and permits only a unique
`RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH`. A retry without an image remains
`RDMA_SC_RECOVERY_REQUIRED`; no-reservation returns `handled=0` so the caller retains its
original `queue has no pending recovery` diagnostic. The unclaimed admission-failure path
still owns its stricter ACTIVE-state and pending-cursor match, so the extraction does not
weaken that evidence boundary.

The fresh 53-host login-shell focused runs were:

| Entry | Result |
| --- | --- |
| `rdma_queue_data_engine_device_publish_test` | PROCESS/LOGICAL PASS; UVM `INFO=220/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_queue_data_engine_recovery_test` | PROCESS/LOGICAL PASS; UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |

The device-publish lifecycle fixture covers reservation-only next-cursor failure, multiple
matching reservations, detach-lock busy, cancel failure and final public abort/reconfigure;
the unclaimed fixture continues to cover its separate admission-failure abort path. The
current source SHA-256 is
`adf49cd8f64b94fc7f0426637df9869688e76333401f08727ce353f9b679c322`; the full-tree scan
reports 185 `.sv`, 2 `.svh`, 5,461 methods (`.sv` 5,459; `.svh` 2), and 0 diagnostics.
Changed-SV style, diff, profile, queue, Phase-1A and Python 292/292 gates passed. Integration
aggregate, reservation-after-route-change concurrency, cross-queue release, SRQ full
lifecycle, legacy descriptors, external PCIe error/ordering combinations, an engine-level
global lock and final ownership audit remain open; the plan remains `active`.

### Batch150 current source boundary

Batch150收束 `src/codec/rdma/rdma_cmq_codecs.sv` 中两个 CMQ consumer 重复的
`context_key()`/`is_context_opcode()`。新增 package-scope
`rdma_cmq_context_codec_key()` 与 `rdma_cmq_is_context_opcode()`，并保留
`rdma_hw_cmq_body_encoder`、`rdma_hw_cmq_request_composer` 原 protected 方法作为薄
转发。六个 context opcode 的 key 字段与未知 opcode 的 `RDMA_IMAGE_NONE`/invalid
fail-closed 结果逐值保持；本批只收束两个 consumer 的重复，不改变显式 registry
registration 表或宣称全局唯一映射。测试侧删除了无调用的旧 `context_key()` fixture，
没有把它改为调用 DUT helper。

最终文件 SHA-256 为：codec
`07fd199219f2ec8ce57e90a8e863cb259d3e02da8543970c7e3bc41c17ac3ac7`，codec test
`5f6c14ce8fa0b34c8d89a38ed5f9d88bd1c782120021f4e8e5b74dd958b9103d`，frozen ABI manifest
`cac560ed8225ae163fa1641fa2a9b470fc0828d6184411eef21abeeddf634caa`。生产 codec 与
测试文件合计净减少 53 行。

最终 53 机登录 bash 验证如下：

| Entry | Result |
| --- | --- |
| `rdma_cmq_codec_test` | PROCESS/LOGICAL PASS；UVM `INFO=4/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_context_body_codec_test` | PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_context_cmq_regression_test` | PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `cmq_gate regression` | PROCESS 28/28、LOGICAL 11/11、UVM pristine 28/28、wrapper rc=0 |

最终 codec/gate 日志 SHA-256 分别为
`313facdf59b5fd7f4e76c8b57842cc020f1673afd82d0b5eefe5e07388792ff6` 和
`36b186526a80bc240d3e7f2ab236c989c48f36c57e48ad3bb2bbb4167bd2ef23`；context-body 与
context-CMQ 日志 SHA-256 为
`de934f4f41f534a2307147abfcdcb99202d5d486e1b50b5d875ea3b428c295f9` 和
`484fae5e3b85e6d9c78347fe89e24e018d3c2b198f6a62aa10adc38c7043707d`。CMQ gate 与 codec
日志中既有 report catcher 会显示 caught UVM_FATAL=1，但最终 severity summary 的
warning/error/fatal 均为 0，wrapper 判定仍为 PASS。

本地 `git diff --check`、changed-SV style、queue lifecycle frozen ABI、profile naming、
Phase-1A、manifest/keyword tests 和 Python 292/292 均通过；全目录复审覆盖 187 个文件
（185 `.sv`、2 `.svh`），5,462 methods（`.sv` 5,460、`.svh` 2），0 diagnostics。
本批 focused/gate 不关闭跨队列并发、SRQ 全生命周期、legacy descriptor、外部 PCIe
error/ordering、engine-level 全局锁或最终 ownership 审计，计划继续保持 `active`。

### Batch151：facade live-authority helper

Batch151 新增 `src/model/rdma_authority_validation.sv`，把 CQ/EQ/RQ/SQ facade 中相同
的 configured/delegate/binding、Function incarnation、ACTIVE 和 `validate()` 失败顺序
集中为 `rdma_validate_live_authority()`；四个 protected facade 方法保留为薄转发，
不改变 runtime、ledger、Host-memory 或 MMIO 所有权。Batch151 的四个 facade focused
均在 53 机登录 bash PROCESS/LOGICAL PASS，UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0`。
该边界的源码与扫描指纹、逐分支审计见
`task-cmq-batch151-authority-validation-helper-report.md`；当时全目录为 188 个文件
（186 `.sv`、2 `.svh`）、5,463 methods、0 diagnostics。

### Batch152：SQ/RQ/EQ configuration admission helper

Batch152 新增 `src/core/rdma_queue_facade_configuration.sv`，把 SQ/RQ/EQ
`configure()` 中重复的依赖非空、shared-engine 五引用一致性、binding.validate() 和
`RDMA_BIND_ACTIVE` admission 集中起来。one-shot `configured` 门禁与
delegate/authority/timeout 快照写入仍由各 facade 保持；CQ 的 URC/shared 专属配置路径
没有被泛化。三项 focused 结果如下：

| Entry | Result |
| --- | --- |
| `rdma_sq_engine_test` | PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_rq_engine_test` | PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |
| `rdma_eq_engine_test` | PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0` |

`git diff --check`、changed-SV style、queue/profile/Phase-1A gates 和 Python 292/292
均通过；最新全目录 scanner 为 189 个文件（187 `.sv`、2 `.svh`）、5,464 methods
（`.sv` 5,462、`.svh` 2）、0 diagnostics。Batch152 只关闭 SQ/RQ/EQ 配置 admission
重复 seam，不覆盖 CQ 特殊配置、SRQ 全生命周期、跨队列并发、legacy descriptor、
外部 PCIe error/ordering、engine-level 全局锁或最终 ownership 审计；计划继续保持
`active`。详见 `task-cmq-batch152-facade-configuration-shrink-report.md`。

### Batch153：CQ configuration admission 收缩

Batch153 将 `src/core/rdma_cq_engine.sv` 的普通 `configure()` 接入
`rdma_validate_queue_facade_configuration()`，使 CQ 与 SQ/RQ/EQ 共用依赖非空、
shared-engine 五引用一致性、binding validation 和 ACTIVE admission；CQ
`configure_shared()` 的 URC completion-QP、shadow、shared delegate 约束仍保持在
facade 内，one-shot 与 authority/delegate/timeout 写入也未移动。`rdma_cq_engine_test`、
`rdma_cq_engine_resize_test`、`rdma_cq_shadow_flush_test` 在 53 机登录 bash 均
PROCESS/LOGICAL PASS，UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0`，wrapper 日志分别为：

- `9ca824a37424758d49660518690e25de8bafa557a99d10b00c29e569c188418c`
- `78ff5aab925e9f0bc41ed88ba992c646098f290282ca85c4a715ed0fed0c9c0a`
- `15e6595cea0fe6d3fe0642b6e4dfc35c5772379f783c50c8ea36f9dee05b6cba`

本地 `git diff --check`、changed-SV style、queue/profile/Phase-1A gates 和 Python
292/292 均通过；全目录 scanner 仍为 189 个文件（187 `.sv`、2 `.svh`）、5,464
methods（`.sv` 5,462、`.svh` 2）、0 diagnostics。Batch153 只关闭普通 CQ 配置
admission 的重复 seam，不覆盖 CQ shadow flush、跨队列并发、SRQ 全生命周期、legacy
descriptor、外部 PCIe error/ordering、engine-level 全局锁或最终 ownership 审计；计划
继续保持 `active`。详见 `task-cmq-batch153-cq-configuration-admission-report.md`。

### Batch154：CEQ/AEQ timeout wrapper 收缩

Batch154 在 `src/core/rdma_queue_data_engine.sv` 新增受保护
`poll_event_with_timeout()`，统一 `poll_ceqe()`/`poll_aeqe()` 的 deadline、
`QUEUE_EMPTY` 重试、null-status 归一化和 timeout 返回；两条 `*_once` task 的
decode/route/pending/doorbell/commit/recovery 仍保持分离，原 virtual public 入口不变。
`rdma_queue_data_engine_poll_test`、`rdma_queue_event_route_consume_test` 和
`rdma_aeqe_route_test` 以及覆盖非零 timeout 的 `rdma_eq_engine_test` 在 53 机登录 bash 均 PROCESS/LOGICAL PASS，UVM
`INFO=3/WARNING=0/ERROR=0/FATAL=0`，日志 SHA-256 分别为：

- `5bf97a648b71b314e05b9e4c595f1621e772164b581c918f6f059681c5e53972`
- `32c982ee588c92f64183c8c684674909b7280c7ff521fec89301f3b7b49c6ce7`
- `57003654df1bee58cca4fb0053a2da9a7fa379a98dab106deac5d10113cf6e24`
- `74989ebace70c5f205f1a3cc5d80c36bbd0e099779466c8794be63453ef5d461`

本地 `git diff --check`、changed-SV style、queue/profile/Phase-1A gates 和 Python
292/292 均通过；全目录 scanner 更新为 189 个文件（187 `.sv`、2 `.svh`）、5,465
methods（`.sv` 5,463、`.svh` 2）、0 diagnostics。Batch154 只关闭 event poll
timeout 外壳的重复 seam，不覆盖 CEQ/AEQ malformed retry、跨队列并发、SRQ 全生命周期、
legacy descriptor、外部 PCIe error/ordering、engine-level 全局锁或最终 ownership 审计；
计划继续保持 `active`。详见 `task-cmq-batch154-event-poll-timeout-shrink-report.md`。

### Batch155：EQ facade operation envelope 收缩

Batch155 在 `src/core/rdma_eq_engine.sv` 新增受保护、非 virtual 的
`validate_operation_authority()` 与 `normalize_delegate_status()`，统一五个 public
task 的配置/Function authority 拒绝顺序和 delegate null-status 归一化。五条 typed
delegate 调用仍分别保留，CEQ/AEQ route、timeout retry、producer/consumer 副作用、
runtime/backing/cursor、MMIO、recovery 与 CQ-flush secondary authority 均未合并。

`rdma_eq_engine_test` 新增/加强五个未配置入口的 sentinel 清理与固定消息、五条
null-status 精确消息，以及五条非空失败 status 对象身份和夹带 result 清理。生产源码
由 327 行降至 272 行。EQ facade、queue-data poll、event-route consume 与 AEQE route
四项最终源码边界 VCS53 均 wrapper rc=0、PROCESS/LOGICAL PASS、UVM
`INFO=3/WARNING=0/ERROR=0/FATAL=0` 且 pristine；日志 SHA-256 分别为：

- `97e0fa12529ac91ed5eaaed9781684788b89a98e4d3eb2a0cb34dd12f43ed342`
- `dd6ec3926973da702823ccdd9059882aaf2cc5591ee8374b02f4b9aa2413539e`
- `418b230e399ef41c83138803a2066cffc9f7ae74e31866e00f03875751e81a03`
- `4c0225f48f77789414f741b9be9a15fa8f7eaec8eb87e98dcd1483f335567a08`

`git diff --check`、changed-SV style、queue/profile/Phase-1A gates 与 Python 292/292
均通过；全目录 scanner 更新为 189 个文件（187 `.sv`、2 `.svh`）、5,467 methods
（`.sv` 5,465、`.svh` 2）、0 diagnostics。Batch155 只关闭 EQ facade operation
envelope 的重复 seam，不覆盖 CEQ/AEQ malformed retry、SRQ 全生命周期、legacy
descriptor、跨队列并发、外部 PCIe error/ordering、engine-level 全局锁或最终
ownership 审计；计划继续保持 `active`。详见
`task-cmq-batch155-eq-facade-operation-envelope-report.md`。

### Batch156：CQ facade operation envelope 收缩

Batch156 在 `src/core/rdma_cq_engine.sv` 新增受保护、非 virtual 的
`validate_operation_authority()` 与 `normalize_delegate_status()`，统一 `poll_cqe()`、
`publish_cqe()`、`resize()` 的配置/Function authority 拒绝顺序和 delegate null-status
归一化。三条 typed virtual seam 保持独立；`flush_shadow()` 因 shared-only 配置、
conditional live-authority、inout caller shadow 和 replay 顺序不同而明确排除。

`rdma_cq_engine_test` 新增/加强三个未配置入口的固定消息、poll/publish sentinel 清理、
三条 null-status 精确消息、三条非空失败 status 对象身份，以及 reset epoch 漂移后的三组
delegate counter 不变断言。`configure()` 禁止 zero timeout，所以空 CQ 的 facade 结果是
`TIMEOUT`，不把 delegate 单次 `QUEUE_EMPTY` 写成可达外部契约。生产源码由 500 行降至
498 行，剥离注释/空行后的生产语句行由 373 降至 344。

三项最终源码边界 VCS53 均 wrapper rc=0、PROCESS/LOGICAL PASS、UVM
`INFO=3/WARNING=0/ERROR=0/FATAL=0` 且 pristine；日志 SHA-256 分别为：

- `rdma_cq_engine_test`：
  `6bbb677a7d6ab116e36318154fc15c613b08318070073db51939ed0c3944bbcb`
- `rdma_cq_engine_resize_test`：
  `6253e6c9a27b35b8cf634a7e72f25963f075e74f1b88c0fd179087ab2b583e77`
- `rdma_cq_shadow_flush_test`：
  `0843be3677d04d3ae33ae1bceea5ca29b58af5f22d5350c9355a1fa43a7c0877`

`git diff --check`、changed-SV style、queue/profile/Phase-1A gates 与 Python 292/292
均通过；全目录 scanner 更新为 189 文件（187 `.sv`、2 `.svh`）、5,469 methods
（`.sv` 5,467、`.svh` 2）、0 diagnostics。`flushed_shadow` 只写不读、replay 不回填缓存
快照的问题保留为独立后续；本批不声称关闭跨队列并发、SRQ 全生命周期、legacy
descriptor、外部 PCIe error/ordering、engine-level 全局锁或最终 ownership 审计。
计划继续保持 `active`。详见
`task-cmq-batch156-cq-facade-operation-envelope-report.md`。

### Batch157：CQ shadow canonical replay 与 factory 原子性

Batch157 删除 `src/core/rdma_cq_engine.sv` 的可变 `shadow_flush_result`，并新增 raw UVM
factory 创建、手工 handle clone 和 detached shadow snapshot clone。普通
`configure()+configure_shared()` 组合拒绝跨 Function UID/generation，并在补齐 shared
shadow 前复用 live binding admission；首次
`flush_shadow()` 在 URC evidence capture 前分别 staging caller 输出与内部 cache；
replay 先验证冻结 authority，再从 cache 重建新的 snapshot/status，因此 caller 篡改不
会污染 cache，replay 不重复 evidence 或 `shadow_flush_count`。`configure_shared()` 的
两次 handle clone、首次 snapshot/cache 分配和 replay 分配均失败原子地返回
`RDMA_SC_RESOURCE_EXHAUSTED`，不发布部分配置、caller、cache、count 或 evidence。
queue-data engine 的 URC evidence candidate 也通过 raw factory/cast 创建，null/错误
动态类型和 null capture status 在发布 `last_urc_evidence` 前失败。

`rdma_cq_shadow_flush_test` 新增 null/错误动态类型 override，覆盖 shared 配置、首刷
(含 URC evidence candidate)、replay 的失败/重试；`rdma_cq_engine_test` 覆盖 ordinary
`configure()+configure_shared()` 的跨 UID/generation 拒绝与 live reset-epoch gate。
注意 `configure_shared()`-only facade 没有 live binding，只能验证冻结字段，不能独立
认证外部 reset，这项能力仍为 OPEN。

最终源码边界的 VCS53 证据（均通过登录 bash 的 `scripts/run_vcs53.sh` 执行）为：

| Entry | Result | Complete wrapper SHA-256 |
| --- | --- | --- |
| `rdma_cq_engine_test` | rc=0；PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0`；pristine | `2b3ed52478718459184ac64ed03b75a52b4a8d443624a4469517c50f26e700ca` |
| `rdma_cq_engine_resize_test` | rc=0；PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0`；pristine | `7110ebc081a9ca2e41c2242d13ed6b554eddda586b3d8c9fae19e16bc353d4af` |
| `rdma_cq_shadow_flush_test` | rc=0；PROCESS/LOGICAL PASS；UVM `INFO=3/WARNING=0/ERROR=0/FATAL=0`；pristine | `36581453cab2e5d2284146de8b515c1c582820f53b3ee47029ae99bc0057e8c8` |

保留的前置 RED 日志 `/tmp/batch157-red-rdma_cq_shadow_flush_test.log`（旧 alias 断言，
不是当前契约）wrapper rc=2，UVM `INFO=3/WARNING=0/ERROR=2/FATAL=0`，SHA-256 为
`ee2286c3dc692d752f0b36c6ab8126a633f012ba7beb0f616798134e42dbf4c8`。

当前静态门禁合并日志 `/tmp/batch157-static-fix.log` 的 SHA-256 为
`73e0e60ee02883bcdda68f52e72e54f07760844a1e5db3c501376e782997d13a`；`git diff --check`、
changed-SV style、queue/profile/Phase-1A、CMQ manifest 22/22、SV keyword 3/3、multivf
manifest 4/4、field ownership 61/61 和 Python 292/292 均通过。全目录
`sanitize_source`/`method_ranges`/`check_method_comments`/`check_file_header` 扫描覆盖
189 个文件（187 `.sv`、2 `.svh`），5,483 methods（`.sv` 5,481、`.svh` 2），0
diagnostics；摘要 `/tmp/batch157-contract-scan-final.log` 的 SHA-256 为
`30f48cc7d65cb1f2be3b8a8c3da4bee093f9487655e48f0d31c5eae9f9bf46c3`。

Batch157 仍不关闭 shared-only live reset 认证、跨队列并发、SRQ 生命周期、legacy
descriptor、外部 PCIe ordering/error、engine-level 全局锁、完整 CMQ/core regression、
全目录最终 ownership 审计或广义 Phase 1C F2；计划继续保持 `active`。详见
`task-cmq-batch157-cq-shadow-replay-atomicity-report.md`。

## Explicit follow-up boundaries

本记录不把以下工作混入 CMQ contract foundation：

- MR control-plane、queue lifecycle、QP lifecycle 的 Phase 1B legacy consumer 迁移；
- CQC embed-at-8、OCC、AEQ/CEQ/CQE/RQE/QPC 等 wire 修复和其他 engine 重构；
- snapshot、ring、ledger 的物理抽取（CMQ Phase 2）；
- queue-data、queue-runtime、resource-manager、control-plane 和 lifecycle engine 的
  独立 spec/plan；
- Linux uverbs/ioctl/libibverbs 或真实 DUT 接入。

这些边界必须另立设计、测试和 approval，不得为了让本 gate 通过而放宽原始驱动
reserved mask、改变字段坐标或删除失败测试。
