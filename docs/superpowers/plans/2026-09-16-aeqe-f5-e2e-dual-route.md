# AEQE F5 End-to-End and CQ-Flush Dual-Route Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Add real non-QP AEQE publish/backing/poll coverage and a compatible explicit-secondary CQ-flush API whose poll path preserves either live route.

**Architecture:** Keep the 16-byte AEQE model and wire layout unchanged. Add a sibling publish API that supplies secondary QP caller authority only at the queue-data boundary, split resolver state into primary/secondary found bits, and materialize partial CQ-flush results through the existing result.secondary_target_h field. Build all coverage on real lifecycle resources and actual Host-memory backing.

**Tech Stack:** SystemVerilog, UVM 1.2, Synopsys VCS W-2024.09 on ubuntu@10.11.10.53, Bash regression wrappers, Python static checks.

**Spec:** docs/superpowers/specs/2026-09-16-aeqe-f5-e2e-dual-route-design.md

## Global Constraints

- Work only in /home/ryan/workspace/ryan/rdma_work/.worktrees/rdma-cmq-contract-foundation on branch feature/rdma-cmq-contract-foundation.
- Preserve the existing four-argument publish_aeqe API and every existing override/caller; add a sibling API instead of changing the signature.
- Do not add secondary authority to rdma_aeqe_model or rdma_hw_aeqe_model, and do not alter the 16-byte wire layout, reserved masks, qword coordinates, signatures, or resource-manager lifecycle state machine.
- dpu_common remains the only authority for Function identity, topology, BDF/BAR and reset epoch. Queue-data consumes frozen snapshots and never writes authority back.
- External PCIe, Host-memory and network components retain their lifecycles; this project stores non-owning references and validates complete routes at the boundary.
- Every touched SystemVerilog file must be reviewed from header to EOF. Every function/task, including constructors and test helpers, requires adjacent Chinese sections 功能 / 输入输出及副作用 / 失败边界 that match the implementation.
- Complex route transitions, partial-result behavior, reservation ordering, cleanup and reset boundaries require Chinese design comments immediately before the implementation.
- Use apply_patch for source/document edits. Do not reset, clean, checkout, stage broad paths, or overwrite unrelated dirty changes.
- The target files already contain reviewed Phase 1C changes in a shared dirty worktree. Task implementers must not stage or commit. Each task records an immutable fix-base snapshot, final SHA-256 hashes and a scoped diff package; the controller commits reviewed file groups later.
- VCS runs only through the exact `SSHPASS=123 scripts/run_vcs53.sh core` commands enumerated under each task's verification step or `SSHPASS=123 scripts/run_queue_lifecycle_regression53.sh`; both wrappers execute a login bash on ubuntu@10.11.10.53.
- Every acceptance GREEN requires wrapper exit 0, PROCESS PASS, LOGICAL PASS and strict UVM warning/error/fatal 0/0/0, with command, host, source/test hashes, full log, meta and SHA sidecars.
- Existing production behavior may be covered by a first-run GREEN; do not manufacture a RED. The only required F5-B behavior REDs are missing secondary caller authority and primary-CQ-miss/secondary-QP-hit result loss.
- Each task receives its own scoped review. Do not start the next task while Critical/Important findings remain open.

---

### Task 1: F5-A real non-QP publish/backing/poll coverage

**Files:**
- Create: tests/unit/rdma_aeqe_f5_e2e_test.sv
- Modify: tests/rdma_unit_test_pkg.sv:96-99
- Modify: scripts/run_queue_lifecycle_regression53.sh:25-34
- Test: tests/unit/rdma_aeqe_f5_e2e_test.sv

**Interfaces:**
- Consumes: rdma_queue_event_route_consume_test inheritance; setup_event_publish_topology(), cleanup_event_publish_topology(), read_queue_backing_slot(), count_host_mem_calls(), count_pcie_calls(), create_transport_qp_for_cq(), destroy_lifecycle_owned_queue(), destroy_lifecycle_owned_qp(), track_fixture(), cleanup_tracked_fixtures().
- Produces: class rdma_aeqe_f5_e2e_test; create_attached_srq_route(); destroy_lifecycle_owned_srq(); run_non_qp_positive(); reusable CQ/CEQ/AEQ/SRQ lifecycle topology for Tasks 2 and 3.

- [ ] **Step 1: Freeze the task base and create the new test shell**

Record SHA-256 for `tests/rdma_unit_test_pkg.sv`,
`scripts/run_queue_lifecycle_regression53.sh`,
`tests/unit/rdma_queue_data_engine_post_test.sv`,
`tests/unit/rdma_queue_data_engine_device_publish_test.sv` and
`tests/unit/rdma_queue_event_route_consume_test.sv` before editing. Create the
file with its directory/responsibility/dependency/ownership header, then define:

~~~systemverilog
typedef enum int unsigned {
  RDMA_AEQE_F5_SRQ,
  RDMA_AEQE_F5_CQ,
  RDMA_AEQE_F5_CEQ,
  RDMA_AEQE_F5_AEQ
} rdma_aeqe_f5_positive_e;

class rdma_aeqe_f5_e2e_test
    extends rdma_queue_event_route_consume_test;
  `uvm_component_utils(rdma_aeqe_f5_e2e_test)

  function new(string name = "rdma_aeqe_f5_e2e_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction
endclass
~~~

Give the enum-adjacent design block and constructor their own concrete Chinese comments. Do not copy a generic three-line template.

- [ ] **Step 2: Register the test without changing unrelated manifest order**

Insert exactly this include after rdma_queue_event_route_consume_test.sv and before rdma_aeqe_route_test.sv:

~~~systemverilog
  `include "unit/rdma_aeqe_f5_e2e_test.sv"
~~~

Insert exactly this logical test after rdma_queue_event_route_consume_test in CORE_TESTS:

~~~bash
  rdma_aeqe_f5_e2e_test
~~~

Update only the adjacent runner comment so it states that device publish, route-consume and real AEQE E2E share the lifecycle fixture.

- [ ] **Step 3: Add a real SRQ-backed route helper**

Implement this task in the new class:

~~~systemverilog
task automatic create_attached_srq_route(
  string label,
  rdma_queue_data_engine_fixture fixture,
  rdma_cq target_cq,
  output rdma_srq srq,
  output rdma_qp srq_qp,
  output bit srq_created,
  output bit srq_qp_created,
  output bit srq_qp_attached,
  output rdma_status status
);
~~~

The body must perform these exact actions in order:

1. Reject null fixture/binding/PD/CQ/executors.
2. Create rdma_create_srq_req with owner=fixture.binding.make_handle(), depth=16, max_sge=4, limit_threshold=16, detached pd_h=fixture.pd.handle, and payload_backing.mode=RDMA_QUEUE_BACKING_OWNED.
3. Call fixture.queue_executor.create_locked(), cast the returned resource to rdma_srq, and set srq_created only after successful creation.
4. Build an RC rdma_create_qp_req whose send/recv CQ are target_cq, whose srq_h is a detached clone of the new SRQ handle, and whose context attributes are assigned by `fixture.make_transport_attrs({label, "_attrs"}, RDMA_TRANSPORT_RC)`.
5. Call fixture.qp_executor.create_locked(), cast to rdma_qp, then fixture.engine.attach_qp(srq_qp.handle). Set created/attached flags only after each successful public operation.
6. Leave every output deterministic on failure so the unconditional epilogue can destroy QP before SRQ.

Add the exact SRQ cleanup interface below. Its body creates `rdma_destroy_resource_req`, assigns `owner=fixture.binding.make_handle()` and `target_h=srq_h`, then calls `fixture.queue_executor.destroy_locked(fixture.binding, fixture.binding.make_handle(), request, transaction_id, control_result)`. It is idempotent when created=0 and never mutates manager internals.

~~~systemverilog
task automatic destroy_lifecycle_owned_srq(
  rdma_queue_data_engine_fixture fixture,
  rdma_handle srq_h,
  bit created,
  longint unsigned transaction_id,
  output rdma_status status
);
~~~

- [ ] **Step 4: Implement the literal qword and lifecycle success oracle**

Add a big-endian 8-byte-to-qword helper and run_non_qp_positive() with this interface:

~~~systemverilog
task automatic run_non_qp_positive(
  string label,
  rdma_aeqe_f5_positive_e positive_kind,
  rdma_queue_data_engine_fixture fixture,
  rdma_aeq event_aeq,
  rdma_resource owner_resource,
  output rdma_status status
);
~~~

Construct only these canonical models:

~~~systemverilog
case (positive_kind)
  RDMA_AEQE_F5_SRQ: begin
    model.ecode = 8'h79;
    model.srfq_en = 1'b0;
    model.srfqn = srq.local_srq_id;
    model.srfqe_idx = 16'h1357;
  end
  RDMA_AEQE_F5_CQ: begin
    model.ecode = 8'hf4;
    model.packet_opcode = 8'h00;
    model.qpn = '0;
  end
  RDMA_AEQE_F5_CEQ: begin
    model.ecode = 8'hf7;
    model.qpn = '0;
  end
  RDMA_AEQE_F5_AEQ: begin
    model.ecode = 8'hfb;
    model.qpn = '0;
  end
endcase
~~~

At task entry, cast `owner_resource` to exactly one of `rdma_srq`, `rdma_cq`,
`rdma_ceq` or `rdma_aeq` according to `positive_kind`; reject a null or wrong-type
owner before reading its local ID or handle. Set `model.target_h` from a detached
clone of that typed owner's handle.

For CQ/CEQ/AEQ, check the full local ID before packed assignment, then assign high=id>>6 and low=id&6'h3f. SRQ requires local_srq_id<=12'hfff. CQ requires local_cq_id<=19'h7ffff; CEQ/AEQ require local IDs within both their manager width and the 19-bit split.

For every case, assert all of the following:

- Pre-publish used=0 and pending=0; capture PI/PW, CI/CW, producer polarity and MMIO count.
- publish_aeqe succeeds with a 16-byte result at the captured PI/PW and occupancy=1.
- The actual RDMA_QUEUE_ROLE_AEQ_RING slot at published.index is byte-equal to published.image.bytes.
- qword0[31:24] is ecode and qword0[17:0] is zero for non-QP cases.
- SRQ qword0[59] is zero, qword1[27:16] is the exact SRQ ID, and split bits are zero.
- CQ/CEQ/AEQ qword0[52:40] and qword0[23:18] reconstruct the exact owner ID with (high<<6)|low; qword1[27:16] is zero; CQ opcode low five bits are not 5'h1d.
- Publish advances PI exactly once, preserves CI, sets used=1/pending=0 and emits no consumer MMIO.
- `fixture.engine.poll_aeqe(event_aeq.handle, 0, event_result, poll_status)` returns operation OK, a non-null event status with hardware_code_valid=1 and hardware_code[7:0]=ecode, and a detached target of the expected kind/instance/Function/generation.
- Returned raw qwords equal the backing qwords and secondary_target_h is null.
- Poll preserves PI, advances CI exactly once, changes used 1->0, leaves pending=0 and increments MMIO exactly once.
- A second zero-timeout poll returns RDMA_SC_QUEUE_EMPTY and result=null.

Do not assert event_status.ok() for nonzero hardware ecodes.

- [ ] **Step 5: Run the four positives with unconditional reverse-order cleanup**

In run_phase, create and track a real event topology, then run SRQ, CQ, CEQ and AEQ cases one at a time, draining the event AEQ after each case. Use lifecycle_aeq as the AEQ owner and the fixture AEQ as the event carrier.

The epilogue always executes:

~~~systemverilog
fixture.destroy_lifecycle_owned_qp(
  srq_qp == null ? null : srq_qp.handle,
  srq_qp_created, srq_qp_attached, transaction_id++, cleanup_status);
destroy_lifecycle_owned_srq(
  fixture, srq == null ? null : srq.handle,
  srq_created, transaction_id++, cleanup_status);
cleanup_event_publish_topology(
  fixture, lifecycle_ceq, wrong_ceq, lifecycle_aeq, lifecycle_cq,
  event_qp, foreign_qp,
  lifecycle_ceq_created, lifecycle_ceq_attached,
  wrong_ceq_created, wrong_ceq_attached,
  lifecycle_aeq_created, lifecycle_aeq_attached,
  lifecycle_cq_created, lifecycle_cq_attached,
  event_qp_created, event_qp_attached,
  foreign_qp_created, foreign_qp_attached);
reset_device_publish_factory_state();
cleanup_tracked_fixtures(cleanup_status);
~~~

Report cleanup failures independently and drop the objection only after all cleanup paths run.

- [ ] **Step 6: Run F5-A verification and archive first-run evidence**

Run:

~~~bash
SSHPASS=123 scripts/run_vcs53.sh core rdma_aeqe_f5_e2e_test
SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_event_route_consume_test
SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_data_engine_device_publish_test
~~~

The new test is allowed to pass on its first run. Record it as coverage GREEN rather than inventing a mutation. Any production failure is a finding; Task 1 must not edit production files.

Archive full logs, wrapper rc, strict counts, command, host, final source hashes and SHA sidecars. Run scoped git diff --check and the changed-SV style checker. Review all three touched files from header to EOF.

- [ ] **Step 7: Produce the Task 1 checkpoint**

Write the task report with the four literal cases, actual-backing evidence, cleanup result and final hashes. Do not stage or commit. The controller creates a fix-base/current scoped diff package and dispatches review.

### Task 2: F5-B CQ-flush explicit secondary authority and partial poll

**Files:**
- Modify: tests/unit/rdma_aeqe_f5_e2e_test.sv
- Modify: src/core/rdma_queue_data_engine.sv:906-1127
- Modify: src/core/rdma_queue_data_engine.sv:2873-3090
- Modify: src/core/rdma_queue_data_engine.sv:5316-5460
- Modify: src/core/rdma_queue_data_engine.sv:7394-7602
- Test: tests/unit/rdma_aeqe_f5_e2e_test.sv

**Interfaces:**
- Consumes: Task 1 lifecycle topology/backing/oracle helpers and existing result.secondary_target_h.
- Produces: virtual publish_aeqe_with_secondary(); protected publish_aeqe_common(); `resolve_aeqe_routes(rdma_hw_aeqe_model, output rdma_aeqe_event_class_e, output rdma_handle, output rdma_handle, output bit primary_found, output bit secondary_found)`; CQ-flush partial-result behavior used by Tasks 3 and 4.

- [ ] **Step 1: Write the two behavior REDs before production edits**

Add two named checks:

- AEQE_F5_LEGACY_FLUSH_SECONDARY_REQUIRED: create live primary CQ and secondary QP, set ecode=8'hf4, packet_opcode=8'h1d, split CQ ID, QPN and model.target_h=primary CQ; call legacy publish_aeqe(). Expect RDMA_SC_INVALID_ARGUMENT, result=null, no reservation, and byte/cursor/used/pending/Host-memory/MMIO state unchanged.
- AEQE_F5_PRIMARY_MISS_SECONDARY_HIT: before the sibling exists, use the currently accepted legacy publish to commit a legal CQ-flush entry, read and validate the actual slot, publicly detach/destroy primary CQ while leaving a secondary QP on a different CQ, then poll. Expect OK, non-null result, event_model.target_h=null, secondary_target_h equal to the live QP, preserved raw qwords/ecode/split/QPN/opcode, and normal CI/used/MMIO commit.

Run only rdma_aeqe_f5_e2e_test on VCS53. The run must compile and fail only at these new contract IDs; archive RED log/meta/SHA and the exact pre-fix production/test hashes.

- [ ] **Step 2: Add the compatible publish API and one shared implementation**

Keep the old signature exactly. Add:

~~~systemverilog
virtual task publish_aeqe_with_secondary(
  rdma_handle aeq_h,
  rdma_hw_aeqe_model model,
  rdma_handle secondary_target_h,
  output rdma_queue_device_publish_result result,
  output rdma_status status
);
~~~

Move the existing body into:

~~~systemverilog
protected task publish_aeqe_common(
  rdma_handle aeq_h,
  rdma_hw_aeqe_model model,
  rdma_handle secondary_target_h,
  output rdma_queue_device_publish_result result,
  output rdma_status status
);
~~~

The old task calls common with null. The sibling passes its caller handle. Define is_cq_flush only from event_class==RDMA_AEQE_EVENT_CQ and model.packet_opcode[4:0]==5'h1d.

Before clone/codec/reservation, enforce:

~~~systemverilog
if (is_cq_flush) begin
  if (model.target_h == null || secondary_target_h == null) begin
    status = bad("AEQE CQ flush requires primary and secondary caller authority",
                 RDMA_SC_INVALID_ARGUMENT);
    return;
  end
  if (!primary_found || !secondary_found ||
      primary_route_h == null || secondary_route_h == null ||
      model.target_h.kind != RDMA_RESOURCE_CQ ||
      secondary_target_h.kind != RDMA_RESOURCE_QP ||
      !primary_route_h.same_instance(model.target_h) ||
      !secondary_route_h.same_instance(secondary_target_h)) begin
    status = bad("AEQE CQ flush caller authority does not match live routes",
                 RDMA_SC_INVALID_STATE);
    return;
  end
end
else if (secondary_target_h != null) begin
  status = bad("AEQE non-flush event cannot carry secondary caller authority",
               RDMA_SC_INVALID_ARGUMENT);
  return;
end
~~~

Also verify both caller handles against current Function UID/generation. New sibling route/caller/generation mismatches return RDMA_SC_INVALID_STATE. Do not change unrelated legacy primary status codes in this task. Complete 16-byte encode before reserve and preserve the existing post-reservation epoch/polarity cancel paths.

- [ ] **Step 3: Split resolver presence into two explicit bits**

Change the resolver tail to:

~~~systemverilog
output bit primary_found,
output bit secondary_found
~~~

Initialize both to zero. Set primary_found after a successful primary clone and secondary_found after a successful CQ-flush secondary clone. Diagnostic and TX-flush Function routes set primary_found=1 before returning. Only INVALID_ARGUMENT/STALE_GENERATION local lookup results are route misses; null status and every other manager error remain fail-closed.

Update publish and poll call sites. Publish requires primary_found for ordinary events and both bits for CQ flush.

- [ ] **Step 4: Permit only CQ-flush partial candidates**

Refactor prepare_event_result_candidate_ex() input admission so queue_h, decoded_event and event_status are always required, but routed_target_h may be null only for a decoded CQ-flush whose secondary_target_h is a QP.

For CQ flush:

- Require at least one live route.
- Clone primary only when non-null and require CQ kind.
- Clone secondary only when non-null and require QP kind.
- Leave aeqe_candidate.target_h explicitly null when primary is missing.
- Freeze profile_class=RDMA_AEQE_EVENT_CQ and profile_owner_kind=RDMA_RESOURCE_CQ from ecode even when only the QP is live.
- Preserve raw qwords and all typed wire fields.

All non-flush AEQE and every CEQE still require a non-null primary and reject any secondary.

- [ ] **Step 5: Gate poll delivery with the OR of found bits**

In poll_aeqe_once(), compute:

~~~systemverilog
bit is_cq_flush;
bit deliver_found;

is_cq_flush = event_class == RDMA_AEQE_EVENT_CQ &&
              aeqe.packet_opcode[4:0] == 5'h1d;
deliver_found = is_cq_flush ?
  (primary_found || secondary_found) : primary_found;
~~~

Use deliver_found both when preparing event_status/result_candidate and in the final result assignment. Both-miss remains OK+ack+result null. Manager/binding/reset/factory errors still return before pending admission and do not ack.

Update the adjacent Chinese state-transition comments; do not change the doorbell→recovery-evidence→CI commit sequence.

- [ ] **Step 6: Convert partial setup to the sibling and cover the full matrix**

After the RED is captured, publish CQ-flush entries through publish_aeqe_with_secondary(). Keep the legacy missing-secondary negative unchanged. Add:

- CQ hit / QP miss: result primary CQ, secondary null, ack.
- CQ miss / QP hit: result primary null, secondary QP, ack.
- both miss: result null, ack.

Every case first reads actual backing and checks split CQ ID, QPN, opcode and polarity, then uses only public lifecycle destroy. Each case uses an independent topology so destroyed owners cannot affect another row.

- [ ] **Step 7: Run F5-B GREEN and compatibility regressions**

Run:

~~~bash
SSHPASS=123 scripts/run_vcs53.sh core rdma_aeqe_f5_e2e_test
SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_event_route_consume_test
SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_data_engine_device_publish_test
SSHPASS=123 scripts/run_vcs53.sh core rdma_aeqe_route_test
~~~

Require strict 0/0/0 and archive full evidence. Run scoped static checks and review the entire new test and queue-data engine from header to EOF, including all method comments, ownership, reset, reservation/cancel/recovery and formatting.

- [ ] **Step 8: Produce the Task 2 checkpoint**

Report both REDs, the two existing/matrix behaviors, exact API/status rules, all GREEN hashes and final source hashes. Do not stage or commit. The controller dispatches scoped review before Task 3.

### Task 3: F5-C lifecycle stale/miss and atomic negative matrix

**Files:**
- Modify: tests/unit/rdma_aeqe_f5_e2e_test.sv
- Test: tests/unit/rdma_aeqe_f5_e2e_test.sv

**Interfaces:**
- Consumes: Tasks 1 and 2 topology helpers, sibling publish API, public lifecycle destroy helpers, state capture/oracles and factory reset seam.
- Produces: single-owner miss, Function fail-closed, target/ID/width atomic coverage; no planned production change.

- [ ] **Step 1: Add four single-owner lifecycle-miss cases**

For SRQ, ordinary CQ, CEQ and owner AEQ, each case uses a fresh topology:

1. Canonically publish a live entry and read its actual 16-byte slot.
2. Destroy the owner through the public executor path. For SRQ, destroy its attached QP first.
3. Confirm manager lookup reports stale/released authority.
4. Poll the carrier AEQ.
5. Require operation OK, result=null, unchanged PI, CI+1, used 1->0, pending=0 and MMIO+1.
6. Confirm the saved raw route coordinate is still the released ID.

Do not call rewrite_event_route_field() and do not mutate registry, allocator cursors, attachments or decoded models.

- [ ] **Step 2: Add Function control and stale-binding fail-closed cases**

Publish a legal diagnostic or TX-flush Function event and prove the live control returns a Function primary with secondary null and normal ack.

In a separate fixture, publish first, then advance/reset the public binding epoch so the event AEQ attachment is stale. Poll must return non-OK, result=null and preserve CI/used/MMIO exactly. Do not classify this as route miss and do not consume the entry.

- [ ] **Step 3: Add target and wire-ID mismatch table rows**

For SRQ/CQ/CEQ/AEQ, build a legal baseline then change exactly one authority input per row:

~~~systemverilog
typedef enum int unsigned {
  RDMA_AEQE_F5_TARGET_KIND_MISMATCH,
  RDMA_AEQE_F5_TARGET_INSTANCE_MISMATCH,
  RDMA_AEQE_F5_WIRE_ID_MISMATCH
} rdma_aeqe_f5_negative_e;
~~~

Each row records backing, PI/PW, CI/CW, used, Host-memory read/write count and MMIO count before calling publish. Expect RDMA_SC_INVALID_STATE for live route/caller mismatch, result=null, no reservation and no state/call-count changes.

Add Function wrong-target with RDMA_SC_INVALID_STATE and Function object-field pollution with RDMA_SC_CODEC_ERROR as separate rows.

- [ ] **Step 4: Add wire-width authority rows and prove factory reset**

Use the existing test-only width-manager/factory pattern to create:

- SRQ local ID starting at 12'h1000, still manager-valid but too wide for SRFQN.
- CQ local ID starting at 19'h80000, still manager-valid but too wide for split CQN.
- CEQ and AEQ raw split ID 19'h01000, which is beyond their 12-bit manager kind width.

Each row carries the full wide handle in model.target_h and verifies that low-bit aliasing never publishes. SRQ and CQ wide lifecycle rows expect RDMA_SC_INVALID_STATE because the packed low bits cannot resolve to the caller's full live instance. CEQ and AEQ raw split 19'h01000 rows also expect RDMA_SC_INVALID_STATE because no owner of that kind/ID exists. The separate Function object-field pollution row remains the RDMA_SC_CODEC_ERROR case.

Immediately call reset_device_publish_factory_state() after every override and run one normal non-QP positive smoke. No override may leak into later package tests.

- [ ] **Step 5: Run F5-C acceptance without editing production**

Run:

~~~bash
SSHPASS=123 scripts/run_vcs53.sh core rdma_aeqe_f5_e2e_test
SSHPASS=123 scripts/run_vcs53.sh core rdma_resource_local_lookup_test
SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_data_engine_device_publish_test
~~~

These are expected coverage GREENs. If a failure is a genuine production defect outside Task 2, stop this task with DONE_WITH_CONCERNS and an exact new finding; do not silently edit production under the test-only task.

Archive evidence, run scoped static checks, and review the complete test file from header to EOF.

- [ ] **Step 6: Produce the Task 3 checkpoint**

Report every table row, exact expected status, public destroy/reset evidence, cleanup/factory-smoke result and final hash. Do not stage or commit. The controller dispatches scoped review before Task 4.

### Task 4: F5-D EQ facade, stale comment and acceptance closeout

**Files:**
- Modify: src/core/rdma_eq_engine.sv:252-296
- Modify: tests/unit/rdma_eq_engine_test.sv:13-112 and facade publish cases
- Modify: src/codec/rdma/rdma_queue_codecs.sv:949-960
- Test: tests/unit/rdma_eq_engine_test.sv
- Test: tests/unit/rdma_aeqe_f5_e2e_test.sv

**Interfaces:**
- Consumes: Task 2 queue-data publish_aeqe_with_secondary() and Task 1/2 CQ-flush topology behavior.
- Produces: non-virtual facade publish_aeqe_with_secondary(), hostile-delegate normalization coverage, corrected logical_cqn_eqn() comment, final focused/regression evidence.

- [ ] **Step 1: Write the facade API RED**

Extend rdma_eq_null_status_delegate with:

~~~systemverilog
int unsigned publish_aeqe_with_secondary_calls;

virtual task publish_aeqe_with_secondary(
  rdma_handle aeq_h,
  rdma_hw_aeqe_model model,
  rdma_handle secondary_target_h,
  output rdma_queue_device_publish_result result,
  output rdma_status status
);
  result = rdma_queue_device_publish_result::type_id::create(
    "eq_untrusted_aeqe_secondary_publish_result");
  publish_aeqe_with_secondary_calls++;
  status = inject_failure_status ?
    rdma_status::make(
      RDMA_SC_UNKNOWN_HW_ERROR,
      "injected EQ AEQE secondary publish failure") : null;
endtask
~~~

Initialize the counter in new(). Add tests for unconfigured facade, hostile null status, explicit failure, reset-epoch drift without delegate call, and one real direct-engine versus facade CQ-flush publish equivalence.

Run rdma_eq_engine_test. Before the facade method exists, the expected RED is a compile error naming the missing publish_aeqe_with_secondary member; archive the source hashes, command, wrapper rc and compile log. Do not treat it as a UVM-summary RED.

- [ ] **Step 2: Implement the transparent facade sibling**

Add a non-virtual task immediately after publish_aeqe():

~~~systemverilog
task publish_aeqe_with_secondary(
  rdma_handle aeq_h,
  rdma_hw_aeqe_model model,
  rdma_handle secondary_target_h,
  output rdma_queue_device_publish_result result,
  output rdma_status status
);
~~~

Mirror the existing facade sequence exactly:

1. Clear result/status.
2. Reject unconfigured/null delegate with RDMA_SC_INVALID_STATE.
3. Call validate_live_authority("EQ AEQE secondary publish").
4. Normalize null validation status to RDMA_SC_INVALID_STATE.
5. Delegate only through `delegate.publish_aeqe_with_secondary(aeq_h, model, secondary_target_h, result, status)`.
6. Normalize null delegate status to RDMA_SC_INVALID_STATE and clear result.
7. Preserve explicit non-OK status but clear result.

Do not inspect ecode, opcode, secondary kind or route in the facade.

- [ ] **Step 3: Correct only the stale split-formula comment**

In rdma_hw_aeqe_model::logical_cqn_eqn(), change the failure-boundary text from high|(low<<6) to:

~~~text
(cqn_eqn_high << 6) | cqn_eqn_low
~~~

Do not change the function body, constants, codec masks or any test oracle. Review the whole codec file because project policy treats comment/implementation divergence as a defect.

- [ ] **Step 4: Run all focused F5 and compatibility gates**

Run each separately and archive logs/meta/SHA:

~~~bash
SSHPASS=123 scripts/run_vcs53.sh core rdma_aeqe_f5_e2e_test
SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_event_route_consume_test
SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_data_engine_device_publish_test
SSHPASS=123 scripts/run_vcs53.sh core rdma_aeqe_route_test
SSHPASS=123 scripts/run_vcs53.sh core rdma_resource_local_lookup_test
SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_aeqe_codec_final_fix_test
SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_codec_test
SSHPASS=123 scripts/run_vcs53.sh core rdma_eq_engine_test
~~~

Every run must be wrapper 0, PROCESS/LOGICAL PASS and strict 0/0/0.

- [ ] **Step 5: Run the queue-lifecycle and local static gates**

Run:

~~~bash
SSHPASS=123 scripts/run_queue_lifecycle_regression53.sh
python3 -m unittest discover -s tests/unit -p 'test_*.py' -v
python3 tools/check_queue_lifecycle.py
python3 tools/check_changed_sv_style.py --base 5b86b10
git diff --check 5b86b10
~~~

The VCS regression must include rdma_aeqe_f5_e2e_test in the parsed CORE_TESTS list. Preserve every log and wrapper return code.

- [ ] **Step 6: Complete the full-file review and final task report**

Review every touched SV file from header to EOF: new F5 test, queue-data engine, EQ facade/test, queue codec and unit package. Review the shell runner completely. Check Chinese three-part comments for every function/task, authority/lifetime ownership, CQ-flush partial state, reset epoch, pre-reservation atomicity, cleanup/factory state and formatting.

Record final hashes, all RED/GREEN evidence and any deferred Minor. Do not stage or commit. The controller dispatches Task 4 review, then a broad whole-branch review and only afterward forms small reviewed commits.
