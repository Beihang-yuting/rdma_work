# RDMA XTR v1 Queue Data Plane Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement deterministic XTR v1 SQE/RQE/CQE/CEQE/AEQE codecs, a real host-memory transaction adapter, and a UVM host-side SQ/RQ/SRQ/CQ/CEQ/AEQ engine with PI/CI, wrap, credits, doorbells, and fail-closed recovery.

**Architecture:** Keep generic queue/request models as the semantic layer and add XTR-v1 subclasses for fixed hardware fields.  A low-level submitter owns opaque host-memory allocation capabilities and performs check-access/write/readback transactions; a queue data engine owns slot reservation, ledgers, cursor commits, completion routing, and doorbell sequencing.  Device-produced completion entries remain external and are consumed through the same backing-access abstraction.

**Tech Stack:** SystemVerilog/UVM 1.2, existing `rdma_codec_base`/registry, `rdma_host_mem_api`, `rdma_dma_mapping.check_access`, `rdma_doorbell_scheduler`, VCS53 simulation host, Python definition checks.

**Spec:** `docs/superpowers/specs/2026-09-02-rdma-queue-data-codecs-host-mem-design.md`

## Global Constraints

- Preserve every frozen coordinate, mask, opcode, endian convention, CMQ envelope, and generated constant in `src/codec/xtr_v1/rdma_xtr_v1_defs.svh`.
- Use `RDMA_ENDIAN_BIG`, `XTR_V1_HW_VERSION`, 64-byte SQE/RQE/CQE alignment 64, and 16-byte CEQE/AEQE alignment 16.
- Queue codec registry keys are exactly `xtr_v1|<image-kind>|<object>|<variant>|00`; unsupported variants must fail lookup.
- Host-memory access always uses the injected `rdma_host_mem_api` and an authoritative `rdma_dma_mapping.check_access()` call; never fabricate an adapter or expose a raw backing CPU address.
- Posting order is reserve → encode → host write → immediate readback compare → doorbell submit → producer/ledger commit; polling order is read → owner check → decode → route → CI doorbell → consumer commit.
- A failed post/poll never advances PI/CI/used or publishes outputs; ambiguous MMIO or potentially partial writes enter `RECOVERY_REQUIRED`.
- Use existing status codes and return a non-null `rdma_status` from every public method.
- Do not add synthesizable RTL, cycle-accurate PCIe/DMA/network BFMs, generated logs, wrappers, caches, or workflow reports.
- Verify simulation work on `ubuntu@10.11.10.53` using a bash login shell; the required credentials are user `ubuntu`, password `123`.

---

### Task 1: Extend semantic receive request and define XTR-v1 queue models

**Files:**
- Modify: `src/model/rdma_semantic_requests.svh` (`rdma_post_recv_req`)
- Test: `tests/unit/rdma_request_model_test.svh`, `tests/unit/rdma_xtr_v1_queue_model_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

**Interfaces:**
- Add `rdma_handle completion_qp_h` to `rdma_post_recv_req`, default null, clone it in `do_copy`, and validate it only for SRQ targets as specified by the design.
- Restrict this task to the semantic `completion_qp_h` extension; the registered XTR-v1 subclasses are created in Task 2 inside the codec package after the model package has been compiled.

- [ ] **Step 1: Write failing tests** for `completion_qp_h` cloning/validation and ensure the future XTR-v1 model test has explicit construction/copy cases.
- [ ] **Step 2: Run the focused VCS test** with `PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 scripts/run_vcs53.sh core rdma_request_model_test`; confirm the new expectations fail because the field/classes are absent.
- [ ] **Step 3: Implement `completion_qp_h` and its validation without changing generic field semantics.
- [ ] **Step 4: Re-run focused and existing request/model tests** and check no UVM warnings/errors/fatals.
- [ ] **Step 5: Commit** with `git add src/model tests && git commit -m "feat: add shared srq completion qp request field"`.

### Task 2: Implement fixed-format XTR-v1 queue codecs and registry bootstrap

**Files:**
- Create: `src/codec/xtr_v1/rdma_xtr_v1_queue_codecs.svh`
- Modify: `src/codec/rdma_codec_pkg.sv`
- Create: `tests/unit/rdma_xtr_v1_queue_codec_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

**Interfaces:**
- Provide registered XTR-v1 model subclasses and codec classes for SQE RC/UD/URC, RQE, CQE, CEQE, and AEQE implementing the `rdma_codec_base` methods (`encode`, `decode`, `validate_model`, `validate_image`, `serialized_equal`, `hardware_endian`, `describe_fields`).
- Provide a bootstrap function/class that registers exact keys `sqe/rc`, `sqe/ud`, `sqe/urc`, `rqe/default`, `cqe/default`, `ceqe/default`, `aeqe/default` with opcode `8'h00` and rejects duplicate/unsupported keys.

- [ ] **Step 1: Add golden-vector tests** for boundary SQE/RQE and error CQE/CEQE/AEQE, round trips, wrong metadata, width overflow, reserved bits, owner/polarity, and output atomicity.
- [ ] **Step 2: Run `scripts/run_vcs53.sh core rdma_xtr_v1_queue_codec_test`** and verify the new tests fail before the codec include/classes exist.
- [ ] **Step 3: Implement codecs using only generated `XTR_V1_*_WORD_BYTE_OFFSET`, `_LSB`, and `_WIDTH` constants, qword builder serialization, strict reserved-bit masks, and fresh decode objects.
- [ ] **Step 4: Register codecs from package bootstrap and run the focused suite plus `tools/check_xtr_v1_defs.py`.
- [ ] **Step 5: Commit** with `git add src/codec tests && git commit -m "feat: add xtr v1 queue codecs"`.

### Task 3: Add opaque host-memory queue submitter

**Files:**
- Create: `src/adapter/rdma_xtr_v1_queue_host_mem_submitter.svh`
- Modify: `src/adapter/rdma_adapter_pkg.sv`
- Create: `tests/unit/rdma_xtr_v1_queue_host_mem_submitter_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

**Interfaces:**
- Implement `rdma_xtr_v1_queue_host_mem_target` and `rdma_xtr_v1_queue_host_mem_submitter` with the exact allocate/write/read/release signatures in the spec.
- Keep mapping, request identity, and release-authority snapshots private in a target ledger keyed by capability; release exactly once and leave failed releases retryable.

- [ ] **Step 1: Write mock-adapter tests** for allocation cleanup, identity/generation checks, offset overflow, direction/permission denial, write/readback mismatch, malformed completion decode, foreign/duplicate release, and output atomicity.
- [ ] **Step 2: Run `scripts/run_vcs53.sh core rdma_xtr_v1_queue_host_mem_submitter_test`** and observe expected missing-implementation failures.
- [ ] **Step 3: Implement allocation validation, `check_access`, detached codec transactions, immediate byte-for-byte readback, fresh completion decode, and authority-aware release.
- [ ] **Step 4: Run focused submitter tests and the pinned host-memory adapter contract test; confirm no direct backing address leaks in public objects.
- [ ] **Step 5: Commit** with `git add src/adapter tests && git commit -m "feat: add xtr v1 queue host memory submitter"`.

### Task 4: Implement runtime cursor, ring credit, slot ledger, and recovery state

**Files:**
- Create: `src/core/rdma_queue_runtime.svh`
- Modify: `src/core/rdma_core_pkg.sv`
- Create: `tests/unit/rdma_queue_runtime_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

**Interfaces:**
- Define `rdma_queue_recovery_action_e` with retry-pending and abort-detach values, runtime attachment states, ring cursor/geometry helpers, slot ledger records, and post/completion/event result objects.
- Expose reservation/commit/release methods that enforce `available = depth - used`, exact wrap toggles, contiguous unsignaled completion release, and retained pending transaction state during recovery.

- [ ] **Step 1: Write failing unit tests** for power-of-two geometry, PI/CI wrap, full/empty, unsignaled release, shared-SRQ QPN routing, generation fences, and retry-vs-abort recovery permissions.
- [ ] **Step 2: Run `scripts/run_vcs53.sh core rdma_queue_runtime_test`** and verify red failures.
- [ ] **Step 3: Implement runtime classes with one semaphore per runtime and deterministic lock-order keys `(resource kind, object ID, generation)`; clone request snapshots before waits.
- [ ] **Step 4: Run focused runtime tests, including concurrent shared-CQ access and atomic output checks.
- [ ] **Step 5: Commit** with `git add src/core tests && git commit -m "feat: add queue runtime cursors and ledgers"`.

### Task 5: Normalize queue backing spans and DMA access

**Files:**
- Create: `src/core/rdma_queue_backing_access.svh`
- Modify: `src/core/rdma_core_pkg.sv`
- Create: `tests/unit/rdma_queue_backing_access_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

**Interfaces:**
- Implement a backing-access object that accepts lifecycle queue plans and QP plans, validates ownership/role/contiguity, maps logical entry offsets to one or more mapping-relative ranges, calls `check_access` for every range, and invokes injected host-memory read/write without releasing borrowed mappings.

- [ ] **Step 1: Write tests** for primary/additional segments, boundary-crossing entries, overflow/alignment, role mismatch, stale generation, read/write permission, and no-release ownership behavior.
- [ ] **Step 2: Run `scripts/run_vcs53.sh core rdma_queue_backing_access_test`** and confirm failures.
- [ ] **Step 3: Implement span normalization and transactional multi-range reads/writes with exact image lengths and status propagation.
- [ ] **Step 4: Run focused backing tests and existing queue lifecycle backing tests.
- [ ] **Step 5: Commit** with `git add src/core tests && git commit -m "feat: normalize queue backing DMA access"`.

### Task 6: Implement queue data engine posting and attach/detach

**Files:**
- Create: `src/core/rdma_queue_data_engine.svh`
- Modify: `src/core/rdma_core_pkg.sv`
- Create: `tests/unit/rdma_queue_data_engine_post_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

**Interfaces:**
- Implement `configure`, `attach_qp`, `attach_cq`, `attach_ceq`, `attach_aeq`, `detach`, `post_send`, and `post_recv` with the exact signatures in the spec.
- Enforce Function/generation ownership, private-RQ versus shared-SRQ `completion_qp_h`, QPN generation, slot snapshots, and the posting order/atomicity contract.

- [ ] **Step 1: Write failing tests** for attach validation, SQ/private-RQ/SRQ posting, queue-full behavior, readback mismatch recovery, request mutation isolation, and `completion_qp_h` routing requirements.
- [ ] **Step 2: Run `scripts/run_vcs53.sh core rdma_queue_data_engine_post_test`** and verify red failures.
- [ ] **Step 3: Implement facade configuration, runtime creation from lifecycle plans, backing access, codec submitter calls, slot ledger commits, and generation fences.
- [ ] **Step 4: Run focused post tests plus existing queue lifecycle regression tests.
- [ ] **Step 5: Commit** with `git add src/core tests && git commit -m "feat: implement queue data engine posting"`.

### Task 7: Add CQ/CEQ/AEQ polling and doorbell integration

**Files:**
- Modify: `src/core/rdma_queue_data_engine.svh`
- Create: `tests/unit/rdma_queue_data_engine_poll_test.svh`
- Create: `tests/unit/rdma_queue_data_engine_doorbell_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`

**Interfaces:**
- Implement `poll_cqe`, `poll_ceqe`, and `poll_aeqe` with absolute-deadline behavior (`timeout == 0` is one non-blocking attempt), owner/valid checks, deterministic QPN/CQN routing, completion status propagation, and CI commit only after successful doorbell.
- Build scheduler descriptors using relative offsets `0x100`, `0x10`, `0x40`, `0x18`, `0x20`, `0x28`, barriers `RDMA_DB_BARRIER_DMA_MMIO` for producers and `RDMA_DB_BARRIER_MMIO` for consumers, and no duplicate `notify_base` addition.

- [ ] **Step 1: Write failing polling/doorbell tests** for empty rings, malformed/mismatched CQEs, unsignaled release, RC/UD/URC CQ variants, CEQ/AEQ valid ownership, frozen offsets, payload fields, barriers, and scheduler failure atomicity.
- [ ] **Step 2: Run `scripts/run_vcs53.sh core rdma_queue_data_engine_poll_test`** and `... rdma_queue_data_engine_doorbell_test`; confirm failures.
- [ ] **Step 3: Implement polling loops, decode/routing, descriptor construction, scheduler calls, and post-commit cursor/ledger updates.
- [ ] **Step 4: Run focused suites and the full core regression.
- [ ] **Step 5: Commit** with `git add src/core tests && git commit -m "feat: poll queue completions and ring doorbells"`.

### Task 8: Add recovery paths and real host-memory integration regression

**Files:**
- Modify: `src/core/rdma_queue_data_engine.svh`
- Create: `tests/unit/rdma_queue_data_engine_recovery_test.svh`
- Create: `tests/integration/rdma_queue_data_engine_host_mem_test.svh`
- Modify: `tests/rdma_unit_test_pkg.sv`
- Modify: `sim/filelists/core.f`, `sim/filelists/host_mem.f` only if the existing lists do not pick up package includes

**Interfaces:**
- Implement `recover_queue(queue_h, action, caller_confirmed_no_submit)` so retry is legal only for known-no-MMIO pending work and explicit caller confirmation; timeout/reset/missing completion/ambiguous MMIO permit only abort-and-detach, retaining pending authority until teardown.
- Add a real-adapter integration test that writes SQ/RQ entries, simulates device CQE/CEQE/AEQE writes, polls/decodes them, rings CI doorbells, and releases resources.

- [ ] **Step 1: Write failing recovery/integration tests** for ambiguous submit, retry rejection, abort detach, stale generation, actual host-memory writes/readback, and zero-warning/error/fatal accounting.
- [ ] **Step 2: Run focused recovery test locally and the integration test on VCS53; capture the expected red state before implementation.
- [ ] **Step 3: Implement recovery state transitions, pending descriptor/image retention, generation fences before/after adapter operations, and integration harness wiring.
- [ ] **Step 4: Run `PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 scripts/run_vcs53.sh host_mem rdma_queue_data_engine_host_mem_test`, then `... core regression`, and `python3 tools/check_xtr_v1_defs.py`.
- [ ] **Step 5: Commit** with `git add src tests sim && git commit -m "feat: add queue engine recovery and host mem integration"`.

### Task 9: Whole-branch verification and handoff

**Files:**
- No production-file changes expected; update only plan/ledger artifacts if needed.

- [ ] **Step 1: Run `git diff --check` and scan for `TODO`, `TBD`, placeholder fatal messages, generated logs, wrappers, caches, and raw host backing address fields in public request/target classes.
- [ ] **Step 2: Run full VCS53 core and host-memory regressions with the required login-shell command and verify `UVM_WARNING=0`, `UVM_ERROR=0`, `UVM_FATAL=0`.
- [ ] **Step 3: Review all changed files against the spec, confirm no frozen definition or unrelated lifecycle file changed, and record exact test outputs.
- [ ] **Step 4: Commit any documentation-only verification update separately if required; otherwise leave the tree ready for the user's integration/push decision.

## Plan self-review

| Check | Result |
|---|---|
| Spec coverage | Tasks 1–2 cover semantic extension, all five image profiles, generated-field ownership, reserved bits, registry keys, and golden vectors. Tasks 3–5 cover opaque host-memory allocation, `check_access`, backing spans, ownership, and atomic read/write transactions. Tasks 6–8 cover attach/post/poll, SQ/RQ/SRQ and CQ/CEQ/AEQ routing, PI/CI/credit, all seven doorbell variants, lock ordering, generation fences, and recovery. Task 9 covers frozen-definition and full-regression acceptance gates. |
| Placeholder scan | No implementation placeholder such as TODO/TBD or “implement later” appears in task instructions; the only `TODO` text is the final verification command that scans for such artifacts. |
| Type/signature consistency | `completion_qp_h` is introduced before `post_recv` engine use; XTR model classes are introduced before codec/submitter use; runtime result and recovery types precede engine methods; backing access precedes engine implementation. Public method signatures match the approved spec. |
| Shared-file conflicts | Task 1 owns semantic requests; Task 2 owns codec package; Task 4 owns runtime includes; Task 5 owns backing-access include; Tasks 6–8 share only the engine file in sequential order. Test-package registration is additive in every task. |
| Scope check | No task modifies frozen definitions, external host-memory implementation, unrelated lifecycle code, or generated artifacts. |
