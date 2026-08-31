# RDMA Task 14C QP Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add typed RC, UD, and URC QP create/modify/destroy control-plane transactions with authoritative SQ/RQ/URC backing, HMC QPC context, semantic QPC codecs, and exactly-once recovery.

**Architecture:** `rdma_control_plane` remains responsible for transaction IDs, the existing per-Function lock, input checks, and generation fences. A new `rdma_qp_lifecycle_executor` composes the existing host-memory, page-directory, context-backing, CMQ, and resource-manager primitives and owns QP-specific planning, semantic QPC construction, state transitions, cleanup ordering, and recovery. QP-only plan/ref classes keep the new roles out of legacy CQ/SRQ/CEQ/AEQ plan validators.

**Tech Stack:** SystemVerilog/UVM 1.2, Synopsys VCS on `ubuntu@10.11.10.53`, existing xtr_v1 QPC/CMQ codecs, existing host-memory/context-backing contracts, Python shell regression checks.

**Spec:** `docs/superpowers/specs/2026-08-31-rdma-qp-lifecycle-design.md`

## Global Constraints

- Run all SystemVerilog simulation through `scripts/run_vcs53.sh`; use a bash login shell on `ubuntu@10.11.10.53` with user `ubuntu` and password `123`.
- Do not modify pinned external `host_mem`, frozen xtr_v1 opcodes/bit fields/golden ABI, PCIe/VIP wiring, or unrelated queue behavior.
- HMC QPC context and temporary 512-byte QPC staging image are separate authorities; host virtual/backing addresses never enter QPC or PD fields.
- SQ/RQ entry size is 64 bytes; storage is checked `align_up(depth * 64, 4096)` and ordinary mode is `RDMA_OBJECT_INDIRECT_4K`, bounded by Function capability and one 2 MiB page directory.
- QPN is 21 bits; the opaque global incarnation handle is never used as QPN or QP sequence.
- QPC changes use the typed semantic model and matching xtr_v1 codec only; no raw image bit patching.
- RESET→INIT is software-only; INIT→RTR and RTR→RTS are full modify; ERROR/RESET transitions are state-only; SQD/SQE are unsupported in this task.
- A busy QP returns `RDMA_SC_RESOURCE_BUSY` before any CMQ, flush, delete, or release side effect.
- Ambiguous CMQ/context/mapping outcomes retain durable ERROR authority and are retried exactly once per completion bit.
- Do not commit build output, VCS logs, `__pycache__`, or changes to external `host_mem`; do not persist credentials or tokens.

## File Map and Interfaces

| File | Responsibility |
|---|---|
| `src/model/rdma_queue_lifecycle_models.svh` | Preserve legacy roles; add QP-only role values/predicates and checked QP backing plan/ref geometry. |
| `src/model/rdma_context_models.svh` | Add caller-owned `rdma_qp_context_attributes` deep-copy/validation. |
| `src/model/rdma_semantic_requests.svh` | Add create SQ/RQ backing/context attributes and modify valid bits. |
| `src/model/rdma_resources.svh` | Add `qp_plan` and `programmed_qpc` authority to `rdma_qp`. |
| `src/model/rdma_control_plane_models.svh` | Add independent QP recovery state with prior/candidate QPC and cleanup progress. |
| `src/adapter/rdma_context_backing_api.svh` | Retain API signatures and document QP slot requirements. |
| `tests/mocks/rdma_mock_context_backing.svh` | Add 512-byte QP slot and release/query fault injection. |
| `src/core/rdma_resource_manager.svh` | Add atomic QP mutations, 21-bit identity, and per-local-QPN sequence. |
| `src/core/rdma_qp_lifecycle_executor.svh` | New QP planner, semantic builder, CMQ transactions, cleanup, and recovery. |
| `src/core/rdma_control_plane.svh` | Configure executor and expose typed QP facade under the existing lock. |
| `src/core/rdma_core_pkg.sv` | Include the executor. |
| `tests/unit/rdma_queue_lifecycle_models_test.svh` | QP plan/ref geometry, ownership, clone isolation, and role separation. |
| `tests/unit/rdma_request_model_test.svh` | Create/modify QP request shape and valid-bit tests. |
| `tests/unit/rdma_resource_manager_test.svh` | QPN width/sequence and atomic QP mutation tests. |
| `tests/unit/rdma_context_backing_contract_test.svh` | QP context slot and exactly-once release tests. |
| `tests/unit/rdma_qp_lifecycle_test.svh` | RC/UD/URC create/modify/destroy, order, busy, and definitive failure tests. |
| `tests/unit/rdma_qp_recovery_test.svh` | Ambiguous ticket/query, stale generation, and idempotent recovery tests. |
| `tests/rdma_unit_test_pkg.sv` | Include the two QP tests. |
| `scripts/run_qp_lifecycle_regression53.sh` | Ordered VCS53 QP regression manifest. |

The only new public methods are:

```systemverilog
task create_qp(rdma_function_binding binding, rdma_create_qp_req request,
               output rdma_qp qp, output rdma_control_result result);
task modify_qp(rdma_function_binding binding, rdma_modify_qp_req request,
               output rdma_qp qp, output rdma_control_result result);
task destroy_qp(rdma_function_binding binding, rdma_destroy_resource_req request,
                output rdma_control_result result);
```

The executor exposes these lock-internal tasks:

```systemverilog
task create_locked(rdma_function_binding binding, rdma_function_handle expected_owner,
                   rdma_create_qp_req request, longint unsigned transaction_id,
                   output rdma_qp qp, output rdma_control_result result);
task modify_locked(rdma_function_binding binding, rdma_function_handle expected_owner,
                   rdma_modify_qp_req request, longint unsigned transaction_id,
                   output rdma_qp qp, output rdma_control_result result);
task destroy_locked(rdma_function_binding binding, rdma_function_handle expected_owner,
                    rdma_destroy_resource_req request, longint unsigned transaction_id,
                    output rdma_control_result result);
task recover_locked(rdma_function_binding binding, rdma_function_handle expected_owner,
                    rdma_handle resource_h, longint unsigned transaction_id,
                    output rdma_control_result result);
```

The resource-manager mutation surface is deliberately narrow:

```systemverilog
virtual function rdma_status attach_qp_programming(rdma_qp candidate);
virtual function rdma_status commit_qp_semantic_state(rdma_handle qp_h,
                                                        rdma_qp_state_e state);
virtual function rdma_status commit_qp_programmed(rdma_qp candidate);
virtual function rdma_status mark_qp_error(rdma_handle qp_h,
                                             rdma_qp_recovery_state recovery);
virtual function rdma_status record_qp_flush_complete(rdma_handle qp_h,
                                                        rdma_queue_backing_role_e role);
virtual function rdma_status record_qp_cleanup_complete(rdma_handle qp_h,
                                                          rdma_queue_backing_role_e role);
virtual function rdma_status record_qp_context_cleanup_complete(rdma_handle qp_h);
virtual function rdma_status finalize_qp_release(rdma_handle qp_h);
virtual function rdma_status qp_sequence(rdma_function_handle owner,
                                           int unsigned local_qpn,
                                           output bit [7:0] sequence);
```

### Task 1: Add QP value objects and request contracts

**Files:**
- Modify: `src/model/rdma_queue_lifecycle_models.svh`
- Modify: `src/model/rdma_context_models.svh`
- Modify: `src/model/rdma_semantic_requests.svh`
- Modify: `src/model/rdma_resources.svh`
- Modify: `src/model/rdma_control_plane_models.svh`
- Modify: `tests/unit/rdma_queue_lifecycle_models_test.svh`
- Modify: `tests/unit/rdma_request_model_test.svh`

**Interfaces:** Consumes existing queue/QPC/handle/mapping models; produces `rdma_qp_context_attributes`, QP-only roles, `rdma_qp_backing_plan`, `rdma_qp_recovery_state`, and the request/resource fields used by all later tasks.

- [ ] **Step 1: Write failing tests.** Before adding fields, create an RC request with `sq_depth=128`, `rq_depth=128`, `max_send_sge=4`, `max_recv_sge=4`, owned SQ/RQ specs, and non-null context attributes; create a modify request with `destination_qpn_valid=1`; create a QP plan with one 8 KiB SQ ring and `RDMA_OBJECT_INDIRECT_4K`. Assert valid objects pass, null refs fail with `RDMA_SC_INVALID_STATE`, borrowed/owned clone graphs do not alias, URC internal caller addresses must be zero, RC+SRQ requires an empty RQ spec and matching SRQ depth, and UD rejects all PSN valid bits.

- [ ] **Step 2: Confirm red.** Run `scripts/run_vcs53.sh core rdma_queue_lifecycle_models_test` and `scripts/run_vcs53.sh core rdma_request_model_test`. Expected: compilation fails on missing QP fields/types.

- [ ] **Step 3: Implement the model contracts.** Widen `rdma_queue_backing_role_e` to `bit [4:0]` without changing values 0–12; assign QP roles 13–19 (`QP_SQ_RING`, `QP_RQ_RING`, `QP_SQ_PD`, `QP_RQ_PD`, `QP_URC_RSQ`, `QP_URC_RDSQ`, `QP_URC_DSQ`). Add `rdma_qp_role_is_payload()` and `rdma_qp_role_is_pd()`; leave legacy `rdma_queue_role_is_payload()/is_pd()` unchanged so old plans reject QP roles. Add `rdma_qp_ring_layout`, `rdma_qp_backing_ref`, and `rdma_qp_backing_plan` with constructors, deep `do_copy()`, and subtraction-style offset/end checks. The plan requires one SQ ring/ref/PD, a private RQ ring/ref/PD only without SRQ, `rq_source_h` only with SRQ, exactly three URC internal refs only for URC, a QP context ref, 64-byte WQEs, and 4 KiB/2 MiB geometry.

  Add `rdma_qp_context_attributes` with exactly `path_mtu_bytes`, `pkey`, `access`, `address_vector`, `signature_enable`, `tx_flow_control`, `rx_flow_control`, `behavior`, and `transport_ext`; clone nested objects and validate the transport match without identity/backing/state fields. Add `sq_backing`, `rq_backing`, and `context_attrs` to `rdma_create_qp_req`; initialize/deep-copy them and validate depth, SGE range, transport/SRQ combinations, and canonical URC addresses. Add `destination_qpn_valid`, `send_psn_valid`, and `recv_psn_valid` to `rdma_modify_qp_req`; valid bits govern patching and are illegal for UD. Add `qp_plan` and `programmed_qpc` to `rdma_qp`; PROGRAMMED/ACTIVE/QUIESCING/ERROR require both and reject generic `backing_refs`/`hmc_refs`. Extend `rdma_recovery_record` with a `rdma_qp_recovery_state` containing intent, prior/candidate QPCs, plan/context, staging/query mapping, opcode keys, ambiguous ticket/operation, and per-role progress.

- [ ] **Step 4: Run green.** Run both focused tests and `git diff --check`. Expected: zero UVM warning/error/fatal and mutation of caller requests/nested extensions after cloning leaves snapshots unchanged.

- [ ] **Step 5: Commit.**

```bash
git add src/model/rdma_queue_lifecycle_models.svh src/model/rdma_context_models.svh \
  src/model/rdma_semantic_requests.svh src/model/rdma_resources.svh \
  src/model/rdma_control_plane_models.svh tests/unit/rdma_queue_lifecycle_models_test.svh \
  tests/unit/rdma_request_model_test.svh
git commit -m "feat: define QP lifecycle value contracts"
```

### Task 2: Extend QP context backing and resource-manager identity

**Files:**
- Modify: `src/adapter/rdma_context_backing_api.svh`
- Modify: `tests/mocks/rdma_mock_context_backing.svh`
- Modify: `src/core/rdma_resource_manager.svh`
- Modify: `tests/unit/rdma_context_backing_contract_test.svh`
- Modify: `tests/unit/rdma_resource_manager_test.svh`

**Interfaces:** Consumes Task 1 models; produces QP-capable context operations, 21-bit QPN allocation, per-local-QPN sequence, and the atomic manager methods in the interface block.

- [ ] **Step 1: Write failing tests.** Call `acquire(binding, RDMA_RESOURCE_QP, 17, ref)` and assert a 512-byte slot, 512-byte-aligned shadow base, QP owner/local ID, and one release after completion. Add manager tests for QPN `2^21-1` accepted, `2^21` rejected, sequence increment on reuse, generic backing authority rejected, and failed candidate leaving registry unchanged.

- [ ] **Step 2: Confirm red.** Run `scripts/run_vcs53.sh core rdma_context_backing_contract_test` and `scripts/run_vcs53.sh core rdma_resource_manager_test`; expect missing QP context/sequence/mutation behavior.

- [ ] **Step 3: Implement.** Keep the four `rdma_context_backing_api` signatures unchanged. Extend the mock role switch, slot lookup, bounds, read/write/release/query, and role-specific fault injection for QP. QP slots are 512 bytes, 512-byte aligned, control-plane-owned, and use an opaque completion authority. Change only QP `local_id_limit()` to `21'h1f_ffff`; maintain a protected sequence table keyed by owner generation and local QPN. Implement `qp_sequence()` and all mutation methods by projecting into built-in objects, validating complete replacements, checking expected registry state, and assigning the registry once. Persist the cloned recovery state before marking ERROR. Record duplicate progress as an error; return the QPN to the free list only in `finalize_qp_release()`.

- [ ] **Step 4: Verify and commit.** Run the two focused tests and `git diff --check`; expect pristine UVM summaries. Commit:

```bash
git add src/adapter/rdma_context_backing_api.svh tests/mocks/rdma_mock_context_backing.svh \
  src/core/rdma_resource_manager.svh tests/unit/rdma_context_backing_contract_test.svh \
  tests/unit/rdma_resource_manager_test.svh
git commit -m "feat: add QP context and manager authority"
```

### Task 3: Add executor skeleton, backing plan materialization, and semantic QPC builder

**Files:**
- Create: `src/core/rdma_qp_lifecycle_executor.svh`
- Modify: `src/core/rdma_core_pkg.sv`
- Create: `tests/unit/rdma_qp_lifecycle_test.svh`

**Interfaces:** Consumes Task 1/2 contracts, `rdma_queue_backing_planner` allocation/release authority, queue-PD codec, QPC codec registry, and CMQ body models; produces `configure()`, `build_qpc_model()`, `encode_qpc_staging()`, and the four locked tasks.

- [ ] **Step 1: Write failing test.** Build an active Function, dependencies, mock host memory/context/CMQ, and an RC request; call `executor.configure()` and `create_locked()`. Assert distinct QPC context/staging addresses, payload IOVA distinct from PD IOVA, `sq_backing/rq_backing` equal PD bases, and a successful codec round-trip. Add RC+SRQ and URC geometry assertions.

- [ ] **Step 2: Confirm red.** Run `scripts/run_vcs53.sh core rdma_qp_lifecycle_test`; expected compile failure at the missing executor include/type.

- [ ] **Step 3: Implement plan materialization.** Construct/register the existing RC/UD/URC codecs during `configure()`. Materialize 64-byte SQ/private-RQ rings with checked 4 KiB rounding and control-plane-owned PDs using the existing planner's mapping authority; zero payloads and encode PD pages with `rdma_xtr_v1_queue_pd_codec`. Borrowed mappings are cloned/detached but never released. For URC allocate owned 4 KiB RSQ, 4 KiB RDSQ, and contiguous 8 KiB DSQ; reject caller nonzero internal addresses. For RC+SRQ require empty RQ backing, matching SRQ depth, and only `rq_source_h`. Acquire one QP context ref with local QPN; reject QPN overflow before side effects.

- [ ] **Step 4: Implement semantic builder and staging.** Add:

```systemverilog
function rdma_status build_qpc_model(rdma_function_binding binding,
  rdma_qp qp_snapshot, rdma_create_qp_req request, rdma_qp_backing_plan plan,
  output rdma_qpc_model model);
function rdma_status encode_qpc_staging(rdma_function_binding binding,
  rdma_qpc_model model, output rdma_dma_mapping staging,
  output rdma_hw_image image);
```

Project local IDs, host/VF/generation, stat index, manager sequence, plan PD bases, payload IOVAs, and context shadow base. Copy only context attributes and set RESET. Select `rc`, `ud`, or `urc`, validate, encode 512 bytes, decode with the same codec, and require `serialized_equal()`. Allocate/write a separate 512-byte aligned staging mapping with a derived DMA request context and fence after the write. Never search or patch raw image bytes.

- [ ] **Step 5: Verify and commit.** Run `scripts/run_vcs53.sh core rdma_qp_lifecycle_test`, `scripts/run_vcs53.sh core rdma_xtr_v1_qpc_codec_test`, and `git diff --check`; expect unchanged QPC golden vectors. Commit:

```bash
git add src/core/rdma_qp_lifecycle_executor.svh src/core/rdma_core_pkg.sv \
  tests/unit/rdma_qp_lifecycle_test.svh
git commit -m "feat: add QP plan and semantic QPC builder"
```

### Task 4: Implement QP create transaction and typed create facade

**Files:**
- Modify: `src/core/rdma_qp_lifecycle_executor.svh`
- Modify: `src/core/rdma_resource_manager.svh`
- Modify: `src/core/rdma_control_plane.svh`
- Modify: `tests/unit/rdma_qp_lifecycle_test.svh`
- Modify: `tests/unit/rdma_control_plane_test.svh`

**Interfaces:** Consumes Task 3 helpers; produces ACTIVE+RESET create, definitive rollback, ambiguous recovery, and public `create_qp()`.

- [ ] **Step 1: Write failing tests.** Cover successful RC, UD, URC, RC+SRQ, same CQs, owned/borrowed SQ/RQ, each allocation/context/write/codec/CMQ/activation failure, terminal failure, no-submit proof, timeout, reset-cancel, post-lock rebind, held-gate rebind, and staging live-count baseline. Assert completed steps in order: `RESOURCE_RESERVED`, `BACKING_ATTACHED`, `HMC_ATTACHED`, `HW_CONTEXT_CREATED`, `REGISTRY_PROGRAMMED`, `REGISTRY_ACTIVE`.

- [ ] **Step 2: Confirm red.** Run `scripts/run_vcs53.sh core rdma_qp_lifecycle_test`; expected no create CMQ/publication and failed assertions.

- [ ] **Step 3: Implement `create_locked()`.** Under the facade-held lock, fence and validate binding/request/dependencies, call `manager.create_qp()`, materialize plan, acquire context, build/encode RESET QPC, attach plan/QPC, and execute xtr_v1 QPC_CREATE using projected QPN/send CQN/recv CQN and staging IOVA. Fence after every adapter/CMQ operation. On terminal success release staging, activate, and return a detached ACTIVE snapshot with `qp_state=RESET`. On definitive failure reverse-release context, URC refs, PDs, owned payload, and identity; borrowed refs detach only. If activation fails after hardware success, run the complete destroy recipe before local finalization. For timeout/reset-cancel/missing ticket or completion, persist `rdma_qp_recovery_state`, retain staging/ticket/query descriptors, mark ERROR, and return `RDMA_SC_RECOVERY_REQUIRED` with `qp=null` and `result.resource_h` set. Preserve the first failure in `primary_status`.

- [ ] **Step 4: Implement `create_qp()` and verify.** Use the existing transaction-ID and per-Function lock helpers; the executor does not create locks or IDs. Validate detached type/state after `create_locked()`. Run:

```bash
scripts/run_vcs53.sh core rdma_qp_lifecycle_test
scripts/run_vcs53.sh core rdma_control_plane_test
scripts/run_vcs53.sh core rdma_control_plane_cmq_engine_test
```

Expected: all create variants/failures pass and existing queue/MR tests remain green. Commit:

```bash
git add src/core/rdma_qp_lifecycle_executor.svh src/core/rdma_resource_manager.svh \
  src/core/rdma_control_plane.svh tests/unit/rdma_qp_lifecycle_test.svh \
  tests/unit/rdma_control_plane_test.svh
git commit -m "feat: implement QP create transaction"
```

### Task 5: Implement semantic QP modify state machine

**Files:**
- Modify: `src/core/rdma_qp_lifecycle_executor.svh`
- Modify: `src/core/rdma_resource_manager.svh`
- Modify: `src/core/rdma_control_plane.svh`
- Create: `tests/unit/rdma_qp_recovery_test.svh`
- Modify: `tests/unit/rdma_qp_lifecycle_test.svh`

**Interfaces:** Consumes a successful QP and its programmed QPC; produces `modify_locked()` and public `modify_qp()`.

- [ ] **Step 1: Write failing tests.** Exercise RESET→INIT→RTR→RTS, ERROR, RESET; every invalid/same-state/jump/SQD/SQE request; RC destination/PSN valid-bit patches; URC sequence projection; UD valid-bit rejection; outstanding busy; stale generation; definitive and ambiguous CMQ outcomes. Assert RESET→INIT has no CMQ call and leaves resource `qp_state=INIT` while `programmed_qpc.state=RESET`.

- [ ] **Step 2: Confirm red.** Run `scripts/run_vcs53.sh core rdma_qp_lifecycle_test` and `scripts/run_vcs53.sh core rdma_qp_recovery_test`; expected missing/no-op modify behavior.

- [ ] **Step 3: Implement `modify_locked()`.** Lookup ACTIVE QP under the lock, reject dependents/outstanding IDs before side effects, clone `programmed_qpc`, apply only valid fields to typed RC/URC extensions, and validate with the transport codec. Map only RESET→INIT (semantic-only), INIT→RTR and RTR→RTS (full image), INIT/RTR/RTS→ERROR and INIT/RTR/RTS/ERROR→RESET (state-only); return `RDMA_SC_INVALID_STATE` for all other transitions and `RDMA_SC_UNSUPPORTED_OPCODE` for SQD/SQE. Full modify allocates/writes a new staging image and uses the codec's transport WBE template; state-only has zero staging/WBE/patch pairs. On definitive failure preserve prior state; on ambiguous outcome persist prior/candidate/staging/ticket/query as ERROR recovery.

- [ ] **Step 4: Implement `modify_qp()` and verify.** Use the same transaction/lock/fence pattern as create; return a detached snapshot only on success. Run:

```bash
scripts/run_vcs53.sh core rdma_qp_lifecycle_test
scripts/run_vcs53.sh core rdma_qp_recovery_test
scripts/run_vcs53.sh core rdma_control_plane_test
```

Expected: state, valid-bit, CMQ-mode, WBE, busy, stale, and staging-accounting assertions pass. Commit:

```bash
git add src/core/rdma_qp_lifecycle_executor.svh src/core/rdma_resource_manager.svh \
  src/core/rdma_control_plane.svh tests/unit/rdma_qp_lifecycle_test.svh \
  tests/unit/rdma_qp_recovery_test.svh
git commit -m "feat: implement QP modify state machine"
```

### Task 6: Implement ordered QP destroy and typed destroy facade

**Files:**
- Modify: `src/core/rdma_qp_lifecycle_executor.svh`
- Modify: `src/core/rdma_resource_manager.svh`
- Modify: `src/core/rdma_control_plane.svh`
- Modify: `tests/unit/rdma_qp_lifecycle_test.svh`

**Interfaces:** Consumes Task 5 authority; produces `destroy_locked()` and public `destroy_qp()`.

- [ ] **Step 1: Write failing tests.** For RESET/INIT/RTR/RTS/ERROR record the mock trace and require `QPC_MODIFY(ERROR if needed)`, QPN OCC flush, SQ-PD OCC flush, optional private-RQ-PD OCC flush, QPC_DELETE, context release, URC/PD/payload cleanup, and finalization in that order. For RC+SRQ assert no RQ-PD or SRQ backing flush/release. Add dependent/outstanding busy tests requiring an empty trace and ACTIVE state.

- [ ] **Step 2: Confirm red.** Run `scripts/run_vcs53.sh core rdma_qp_lifecycle_test`; expected missing destroy behavior.

- [ ] **Step 3: Implement `destroy_locked()`.** Validate owner/generation/kind, call `manager.begin_quiesce()`, and return immediately on `RDMA_SC_RESOURCE_BUSY`. In QUIESCING issue ERROR state-only modify when needed; execute OCC patterns for QPN EIRQ/ORQ/UAQ, SQ PD, and private RQ PD, recording each completion. Build QPC_DELETE from authoritative local QPN/send CQN/recv CQN. Release context only after delete, then reverse-release URC refs, owned PDs, and owned payload; borrowed mappings detach only. Persist progress after each physical completion and call `finalize_qp_release()` once all required steps are complete. Definitive or ambiguous failures remain ERROR with a NORMAL_DESTROY recovery record; no recovery path restores ACTIVE after an ERROR/flush side effect.

- [ ] **Step 4: Implement `destroy_qp()` and verify.** Use the existing destroy facade pattern with expected kind QP. Run:

```bash
scripts/run_vcs53.sh core rdma_qp_lifecycle_test
scripts/run_vcs53.sh core rdma_queue_lifecycle_test
scripts/run_vcs53.sh core rdma_resource_manager_test
```

Expected: zero-side-effect busy, exact order, SRQ ownership, borrowed mapping, and leak assertions pass. Commit:

```bash
git add src/core/rdma_qp_lifecycle_executor.svh src/core/rdma_resource_manager.svh \
  src/core/rdma_control_plane.svh tests/unit/rdma_qp_lifecycle_test.svh
git commit -m "feat: implement ordered QP destroy"
```

### Task 7: Implement QP recovery and generic recovery dispatch

**Files:**
- Modify: `src/core/rdma_qp_lifecycle_executor.svh`
- Modify: `src/core/rdma_control_plane.svh`
- Modify: `tests/unit/rdma_qp_recovery_test.svh`
- Modify: `tests/unit/rdma_qp_lifecycle_test.svh`

**Interfaces:** Consumes durable QP recovery state, CMQ reconcile, QPC query, host-memory read/release, and Task 6 progress bits; produces idempotent QP `recover_locked()`.

- [ ] **Step 1: Write failing tests.** Inject ambiguous create/modify/delete/OCC/context-release/host-release. Return query images equal to candidate, prior, and neither; assert candidate publication, prior restoration, or continued ERROR. Repeat recovery and assert no second release for completed bits. Add stale-generation-after-side-effect coverage.

- [ ] **Step 2: Confirm red.** Run `scripts/run_vcs53.sh core rdma_qp_recovery_test`; expected QP recovery dispatch/query assertions fail.

- [ ] **Step 3: Implement reconcile/query.** Dispatch QP in `recover_locked()`. Reconcile an ambiguous ticket first; if unknown, allocate a separate aligned 512-byte query mapping, execute QPC_QUERY, read exactly 512 bytes with `host_mem.read()`, validate/decode with the transport codec, and compare via `serialized_equal()` to prior/candidate. Candidate equality publishes candidate, prior equality restores prior, neither stays ERROR. Create rollback absent performs local cleanup; present runs destroy. Destroy absent skips duplicate delete and resumes the first incomplete flush/release; present resumes the first incomplete step.

- [ ] **Step 4: Implement exactly-once fences.** Query opaque completion authority before every context/host release. If complete, record only the manager bit. After each physical release, record progress before the next operation. A stale generation before side effect returns `RDMA_SC_STALE_GENERATION`; after side effect, record against the old ERROR authority and never publish to the new generation. Preserve `primary_status`; append reconcile/cleanup failures to `rollback_statuses`.

- [ ] **Step 5: Verify and commit.** Run:

```bash
scripts/run_vcs53.sh core rdma_qp_recovery_test
scripts/run_vcs53.sh core rdma_qp_lifecycle_test
scripts/run_vcs53.sh core rdma_control_plane_test
git diff --check
```

Expected: all query/presence/retry/generation/leak assertions pass with zero UVM warning/error/fatal. Commit:

```bash
git add src/core/rdma_qp_lifecycle_executor.svh src/core/rdma_control_plane.svh \
  tests/unit/rdma_qp_recovery_test.svh tests/unit/rdma_qp_lifecycle_test.svh
git commit -m "feat: add QP recovery reconciliation"
```

### Task 8: Register tests, add VCS53 runner, and run complete verification

**Files:**
- Modify: `tests/rdma_unit_test_pkg.sv`
- Create: `scripts/run_qp_lifecycle_regression53.sh`
- Verify: `sim/filelists/core.f`, `sim/Makefile`, existing Task 14A/14B runners

**Interfaces:** Consumes all QP model/manager/executor/facade/recovery tests; produces a reproducible VCS53 regression manifest.

- [ ] **Step 1: Register tests and create runner.** Include `unit/rdma_qp_lifecycle_test.svh` and `unit/rdma_qp_recovery_test.svh`. Follow `scripts/run_queue_lifecycle_regression53.sh` exactly: support `--list`, reject other arguments, run sequentially through `scripts/run_vcs53.sh core`, and use the ordered list `rdma_queue_lifecycle_models_test`, `rdma_request_model_test`, `rdma_context_backing_contract_test`, `rdma_resource_manager_test`, `rdma_xtr_v1_qpc_codec_test`, `rdma_qp_lifecycle_test`, `rdma_qp_recovery_test`, `rdma_control_plane_test`, `rdma_control_plane_cmq_engine_test`, `rdma_queue_lifecycle_test`, `rdma_queue_recovery_test`.

- [ ] **Step 2: Run static checks.**

```bash
python3 -m pytest -q tests/unit/test_check_xtr_v1_defs.py tests/unit/test_check_queue_lifecycle.py
python3 tools/check_queue_lifecycle.py
git diff --check
git status --short --branch
```

Expected: Python tests/checkers pass, frozen ABI is unchanged, and only intended files are tracked.

- [ ] **Step 3: Run QP VCS53 regression.** Run `scripts/run_qp_lifecycle_regression53.sh`. Expected: every command exits zero and `scripts/check_uvm_summary.sh` reports `WARNING=0 ERROR=0 FATAL=0`; successful paths have zero staging/context/owned-resource leaks.

- [ ] **Step 4: Run existing guards.**

```bash
scripts/run_queue_lifecycle_regression53.sh
scripts/run_vcs53.sh xtr_defs regression
HOST_MEM_ROOT=/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/host_mem \
  scripts/run_vcs53.sh host_mem rdma_host_mem_adapter_test
```

Expected: Task 14A/14B queue, recovery, control-plane, frozen ABI, and host-memory tests remain green on VCS53 using the bash-login wrapper.

- [ ] **Step 5: Final scope check and commit.**

```bash
git diff --check
git status --short --branch
rg -n "(build/|\\.log$|__pycache__|host_mem_manager\\.sv|host_mem_pkg\\.sv)" \
  --glob '!docs/superpowers/**' --glob '!*.md'
```

Confirm no build output/VCS log/cache/external host_mem change is staged. Commit only the package/runner registration:

```bash
git add tests/rdma_unit_test_pkg.sv scripts/run_qp_lifecycle_regression53.sh
git commit -m "test: add QP lifecycle regression manifest"
```

## Plan Self-Review

- **Spec coverage:** Task 1 covers request/plan/context/recovery value contracts; Task 2 covers QP context and identity; Task 3 covers 64-byte/4 KiB/PD/IOVA separation and semantic codec round-trip; Task 4 covers create/facade and all create failure classes; Task 5 covers every supported/unsupported modify transition and valid-bit patch; Task 6 covers busy-gated destroy order and SRQ ownership; Task 7 covers query-based ambiguity and exactly-once recovery; Task 8 covers VCS53, Python, frozen ABI, Task 14A/14B, and host_mem regressions.
- **Placeholder scan:** No step uses TBD/TODO/“implement later” or unspecified edge-case handling; each task names files, interfaces, tests, commands, expected output, and a commit.
- **Type consistency:** Public and locked task signatures are identical everywhere. Manager methods consistently consume `rdma_qp`, `rdma_qp_recovery_state`, `rdma_queue_backing_role_e`, and `rdma_handle`. QP role predicates are separate from legacy predicates, preventing old plans from accepting QP roles.
- **Scope check:** SQE/RQE/CQE data plane, doorbells/SQD handshake, dynamic dependencies, CQ cleanup, QP resize, huge-page/direct/L3 backing, frozen ABI, and external host_mem changes remain excluded exactly as approved.
