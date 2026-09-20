# SDD ledger — plan: docs/superpowers/plans/2026-09-14-rdma-phase1c-abi-fixes.md

Identity: Phase 1C implementation ledger for the feature worktree.
Plan: docs/superpowers/plans/2026-09-14-rdma-phase1c-abi-fixes.md
Spec: /tmp/phase1c-spec.md (plus the pinned 0.1.34 driver evidence recorded in the task reports)
Status: Phase 1C F5 is committed and verified; the broader F2 `sge_num` canonical-authority/final verification remains paused while the structural-refactor plan is active. Batch100 independently closed the RC raw `INLINE_SGB` fixed-capacity rejection gap.
Constraint: do not mark a task complete from an agent report alone; preserve the original driver coordinates and keep unrelated dirty work isolated.

## Pre-flight task/interface scan

| Tasks | Shared output/input | Finding | Ruling |
|---|---|---|---|
| 0 → 1–7 | CQC/CQE baseline tests and codecs | Task 0 changes only assertions; later tasks must preserve the baseline. | Run the two CQC baseline tests after every later task; no CQC production-field edits. |
| 1 ↔ 2 | `rdma_queue_codecs.sv`, `rdma_queue_codec_test.sv` | Both touch RQE/CQE-adjacent codec code and a common test; a broad rewrite could hide wire-coordinate regressions. | Keep Task 1's CQE base-offset change isolated, then Task 2's RQE field; review each diff against the previous raw masks. |
| 1 ↔ 3 | `rdma_queue_codecs.sv`, CQE tests | Task 3 consumes Task 1's profile-relative header API. | Task 3 may not change the base-offset rule; add fields through the established relative view only. |
| 2 ↔ 3 | `rdma_queue_codecs.sv`, queue tests | Both alter model/copy/validate helpers and reserved masks. | Preserve RQE qword3/qword5–7 strict masks while extending only documented CQE bits. |
| 3 ↔ 4 ↔ 5 | `rdma_queue_codecs.sv`, queue/EQ tests | CEQE/AEQE additions share helper and mask patterns; later work can accidentally widen earlier profiles. | Each task owns its model and exact qword masks; no whole-qword fallback; run prior focused tests before commit. |
| 4 ↔ 5 | EQ/final-fix tests | Both propagate detached event snapshots through the same engines. | Add independent RC/URC and abnormal fixtures; retain existing event ownership and no shared mutable payload. |
| 6 ↔ 0/1/3 | doorbell codec vs CQ/CQE coordinates | Doorbell flags are independent but CQ engine tests consume CI/arm fields. | Keep BAR offset and existing CI coordinates unchanged; test raw bit 63/62/61 explicitly. |
| 7 ↔ 1–5 | QPC codec vs queue codecs | No source-file overlap; shared final verification can mask regressions. | Require CQC/CQE/queue tests plus QPC test before Phase 1C completion. |

| Task | Internal consistency check | Ruling |
|---|---|---|
| 0 | Baseline assertions are test-only and do not alter codec behavior. | Proceed; fail if a proposed “baseline” changes production fields. |
| 1 | 128B header requirement agrees with profile-relative API and tests. | Reject any implementation that decodes qword0 for 128B. |
| 2 | `sgb_pa` semantic width and 512B alignment agree with raw `[63:9]`. | Encode only shifted aligned PA; reject misalignment/overflow. |
| 3 | CQE field list and profile masks agree with driver `wr.h`. | Unknown/profile-inapplicable bits remain rejected. |
| 4 | CEQE URC/abnormal overlays coexist with RC CI coordinates. | Use explicit variant masks; do not merge overlays into one permissive mask. |
| 5 | AEQE split high/low fields and shift 6 are retained. | Preserve wire split and expose only a documented recombination helper. |
| 6 | Invalid flags are independent of existing arm/CI fields. | Add bits 63/62 without moving offset or variant coordinates. |
| 7 | Runtime shadow is readback-only. | Permit observation on decode; encode/create/modify must zero or reject nonzero shadow. |

Ruling: the plan is internally consistent and has a reachable spec; proceed in numeric
order, with each task's RED/GREEN evidence and a scoped review before the next task.
Cost if wrong: a shared helper or mask regression will be caught by the mandatory
prior-task focused tests and can require rework before advancing.

Task 0: implementation and raw-coordinate assertion fixes are present in `571266e`,
`a449b57`, and `8ede5e7`; the source-level review findings for CQ state/size,
independent literals, and CQE-size offsets are addressed. The original review's
RED/GREEN evidence finding was later superseded by the `349a757`-pinned evidence
files, which include host, command, exit code, summary counts, and digests; recheck
the files before claiming the task complete.

Task 1: 128B CQE header base is implemented in `58fc94c` plus follow-up codec/model
changes in the dirty worktree. The profile-relative rule is byte 0 for 32/64B and
byte 64 (qword 8) for 128B; do not alter this while adding overlays.

Task 2: RQE SGB_PA and strict external-SGB checks are implemented in `c981182` and
the current dirty worktree. `RDMA_MAX_WQ_SGE=32` is now a shared ruling across request,
codec, and queue-data layers. A remaining SQE issue is that `make_sqe()` may expose
raw SGE count while the wire uses filtered nonzero count; add a RED before changing it.

Task 3–5: CQE, CEQE, and AEQE field/overlay implementations are present in the current
dirty codec/model changes. Their exact raw masks still require fresh focused tests and
an independent audit against the 0.1.34 headers; inactive overlays must remain
detached/read-only rather than silently canonicalized.

Task 6–7: CQ doorbell invalid flags and QPC runtime-shadow readback policy are present
in commits `d2cbb1d` and `3e664da`/follow-ups. Re-run their focused tests after the
remaining queue changes; write paths must not publish shadow bytes.

Ruling: the decoded external-SGB RQE is a read-only detached snapshot unless a future
API supplies an explicit raw external-SGB authority. Re-encoding such a snapshot
without that authority must fail closed rather than inventing a host-memory pointer.

Ruling: CQ facade operations must validate live Function UID, binding generation, and
reset epoch on every configure/poll/publish/flush-shadow entry, including replay of a
cached shadow. Cost if wrong: a stale CI/arm snapshot could be replayed after reset.

Ruling: all status-returning engine/delegate boundaries normalize a null `rdma_status`
to `RDMA_SC_INVALID_STATE`; callers must never dereference a null status. Add focused
RED tests before touching SQ/EQ/RQ/CQ implementations.

Ruling: readability work is behavior-preserving and staged after each functional fix;
split dense declarations/branches and add the required Chinese three-part comments,
without wholesale reformatting unrelated files.

## Independent ABI review follow-up

The queue-mask review was rechecked against the pinned 0.1.34 C data flow rather
than accepted from source shape alone.  Detailed evidence is in
`verify-wqe-cqe-abi.md` and `verify-event-abi.md`.

Ruling: fix the verified WQE/CQE defects before Phase 1C acceptance: external-SGB
RQE signatures must include the exact descriptor bytes; RQE opcode is fixed 0x9;
direct-SGE length bit31, unknown SQ opcode, SQ SIGN_EN=0, and atomic local length
other than 8 are rejected; CQE SIGN_EN conditionally authenticates the complete
32/64/128-byte entry.  Cost if wrong: a model-produced WQE or accepted CQE can pass
local masks while the real driver/hardware rejects its signature or fixed field.

Ruling: retain CQE qword2 as a physical union with detached raw authority.  The
driver unconditionally extracts every overlapping view and supplies no inactive-
overlay reserved-zero contract; the typed canonical encoder still rejects a caller
that authors fields outside its chosen semantic variant.  Cost if wrong: accepting
an actually reserved non-overlapping bit would weaken fail-closed behavior, so the
three truly unnamed qword2 bits remain rejected and raw round-trip tests stay in the
gate.

Ruling: 128-byte CQE qword12..15 remain opaque, not reserved-zero.  The driver has no
zero contract for those bytes, but its SIGN_EN check covers the complete entry; fix
the stale comment and authenticate opaque bytes when signing is enabled.  Cost if
wrong: a future hardware definition could require a typed tail, in which case an
explicit model/profile extension is needed rather than silently discarding it.

Ruling: split CEQE/AEQE raw observation from canonical event authorship.  CEQE
canonical profile authority comes from the routed CQ attachment, while wire
URC_FLAG is checked as observed evidence; AEQE owner/route comes from the pinned
ecode class table (QP, CQ, SRQ, or EQ), not from an unconditional QP handle and not
from SRFQ_EN.  Inactive raw fields stay observable until producer evidence proves a
zero rule, but ordinary canonical encode cannot claim them.  Cost if wrong: raw
hardware events could be falsely rejected or a model-produced event could be routed
to the wrong resource and consume the wrong queue cursor.

## Task 18 remediation pointer

Task 18 remediation is implemented in the CMQ engine/adapter and its observed-envelope
tests. The detailed authority, malformed-envelope, legacy-seam, inventory, and fresh VCS
evidence is recorded in
`.superpowers/sdd/2026-09-11-rdma-cmq-contract-foundation/task-18-report.md`.
The current working tree deliberately keeps Task 1/2 queue codec files out of this
remediation scope. Fresh 53-host checks cover the CMQ port, fifteen-leaf engine logical
gate, control-plane CMQ route, control-plane consumer, queue lifecycle, and QP lifecycle;
the report records each command, summary, and log digest.

## Current follow-up evidence

- CEQE raw-overlay authority is now explicit: canonical encode uses the routed CQ
  transport profile, while raw qword1 replay requires an explicit detached-authority
  seam. A fresh 53-host `rdma_queue_codec_test` run reports
  `UVM_WARNING=0`, `UVM_ERROR=0`, `UVM_FATAL=0`.
- SQE/RQE wire-contract checks now reject the driver-forbidden direct-SGE length bit,
  non-eight-byte atomic local lengths, unknown SQ opcodes, and non-0x9 RQE opcodes;
  a fresh `rdma_sq_codec_test` run reports a pristine UVM summary. The RQE focused
  suite is kept separate from the CEQE overlay matrix.
- Four hostile null-status boundaries are fail-closed: queue transaction evidence
  capture, semantic-request capture, queue backing attach and QP backing attach.
  They return `RDMA_SC_INVALID_STATE` before mutating snapshots, attachments or
  Host-memory state; details are in `docs/rdma-queue-null-status-hardening-report.md`.
- `prepare_consumer_doorbell()` keeps the public legacy seam but returns
  `RDMA_SC_UNSUPPORTED_OPCODE` before descriptor construction for CQ. The unreachable
  historical CQ case has been removed; CQ consumer CI remains exclusively a CQC
  context-shadow write.
- CMQ engine simulator-lifetime isolation is now an eighteen-leaf all-of gate: the
  base fixtures are split 0..7 / 8..15, profile-wide and retention-prefix remain
  isolated, and all sixty-eight logical fixtures preserve their original order.
  On 2026-09-16 the fresh VCS53 command
  `SSHPASS=123 scripts/run_vcs53.sh core rdma_cmq_engine_test` exited 0 with
  `LOGICAL PASS ... processes=18`; every leaf had strict warning/error/fatal 0/0/0.
  The scoped re-review closed all findings; the evidence boundary and review fixes
  are recorded in `task-cmq-profile-isolation-report.md` and
  `task-cmq-review-fix-report.md`. VCS's internal SIGSEGV mechanism remains unknown.
- AEQE class/owner authority remains the active follow-up until its raw-observation
  versus canonical-authoring tests and fresh VCS evidence are green. No reserved mask
  is widened without a direct 0.1.34 `defs.h`/`event.c` coordinate check.

## AEQE canonical field-authority continuation (2026-09-16)

- Fresh VCS53 device-publish RED is archived at
  `/tmp/aeqe-device-publish-red-vcs53.log` with meta
  `/tmp/aeqe-device-publish-red-vcs53.meta`: wrapper exit 2, strict UVM
  warning/error/fatal `0/1/0`, and the sole ID is `EVENT_PUBLISH_AEQE`.
  The failure occurs before the expected readback-recovery state because the old
  `ecode=0x5a` QP fixture still authors split CQ/EQ, SRQ, and unrelated common raw
  fields after the canonical class allowlist became active.
- Ruling: unconditional `event.c` `FIELD_GET` is raw-observation evidence, not
  canonical cross-class write authority. Canonical `qp_state` belongs only to QP,
  `srfq_en` only to SRQ (while routing remains independent of its value),
  `cq_invalid_flag` only to CQ, and `overflow_flag` remains raw-only for all classes.
  Other classes must author zero; explicit raw decode/replay remains unchanged.
  Cost if wrong: a hardware producer may legitimately generate one of these bits in
  another class, in which case the canonical authoring matrix needs new producer/spec
  evidence and a narrow extension, while raw observation will continue to preserve it.
- The resumed implementer requirements are frozen in
  `task-aeqe-authority-device-publish-brief.md`; the next required evidence is a
  test-only RED for the four single-field rejects followed by codec/device-publish
  strict GREEN and scoped independent review.

## AEQE F5 end-to-end gap ruling (read-only reconnaissance)

- Production already has the basic non-QP route pipeline:
  `publish_aeqe()` validates/resolves before reservation and commits a 16B device
  entry; `poll_aeqe_once()` reads/decode/resolves that Host-memory entry and commits
  CI. `resolve_aeqe_routes()` uses ecode + `srfqn` for SRQ without reading
  `srfq_en`, split `(high<<6)|low` for CQ/EQ, and maps `0xf7/0xf8` to CEQ and
  `0xfb` to AEQ. Existing end-to-end tests exercise only QP.
- Ruling: add SRQ (`srfq_en=0`), CQ (`qpn=0`), CEQ and AEQ publish→actual 16B
  backing→poll positive cases first and accept that they may be GREEN immediately;
  do not manufacture a RED where the implementation already satisfies the contract.
  Each case must check route kind/instance, Function/generation, ring cursor/used/MMIO
  commit, and literal split/SRQ route coordinates.
- A real CQ-flush dual-route defect is present: canonical publish resolves but does
  not require or validate `secondary_route_h`; poll derives `route_found` only from
  the primary CQ, so primary-miss/secondary-QP-hit acknowledges the entry but drops
  the available secondary result. Ruling: write focused REDs for both-owner publish
  authority and the three partial/miss poll combinations before changing production;
  at least one route hit must return the hit handle(s), while every non-ambiguous miss
  combination still consumes/commits the raw entry. Cost if wrong: a CQ flush can be
  silently published without its QP authority or lose the only live QP side-effect
  route during polling.
- Remaining F5 coverage after the dual-route fix: table-drive single-owner route miss
  for SRQ/CQ/CEQ/AEQ/Function classes and add non-QP target/ID/width rejection
  atomicity before reservation/Host-memory write. Exact reconnaissance coordinates
  were reported by `/root/recon_tests` on 2026-09-16 and must be copied into the F5
  task brief before dispatch.

## SQE persisted-slot evidence completion (2026-09-16)

- Task SQE persisted-slot evidence: complete (uncommitted test snapshot
  `ccf0dcb97e4b41efbf60abe528d90b9a6263402b3bffc236f779614d878fa7e2`,
  scoped review clean). Direct `[zero-prefix, valid, zero-tail]` proves actual-slot
  compaction; external SGB proves actual 64B header plus actual 512B backing and their
  joint signature.
- Mutation RED remains precise at strict UVM `0/10/0`. Fresh shared-tree VCS53 GREEN
  passes `rdma_queue_data_engine_post_test` and `rdma_sq_codec_test`, each wrapper
  exit 0, PROCESS/LOGICAL PASS and strict UVM `0/0/0`; all log/meta SHA sidecars pass
  `sha256sum -c`.
- Fix round 1: 2 addressed, 0 open. Scoped re-review is
  `/tmp/review-sqe-slot-evidence-rereview.md` (SHA-256
  `73600b892cec03351e37d5f7ad6d645ab6d2af82e44ff5d255e820cd7bc64cd1`).
- Deferred minor: the earlier disposable mutation RED did not persist its outer
  wrapper rc in a meta sidecar; its observed rc=2 and strict failure are recorded,
  while both acceptance GREEN runs have complete rc/log digest evidence.

## AEQE F1/F4 task review — complete

- Independent review `/tmp/review-aeqe-f1f4.md` found 2 Critical, 2 Important and
  1 Minor; both spec and quality verdicts are Needs fixes. Open load-bearing findings:
  raw `QP_ST=6/7` is incorrectly rejected by decode/replay; `packet_opcode` lacks
  class/subtype canonical ownership; `publish_aeqe()` encodes class authority only
  after a transient device reservation; and the original 0/21/0 RED lacks immutable
  source provenance.
- Fix round 1 requirements are frozen in `task-aeqe-f1f4-fix-round1.md`. Required
  order is test-only RED, minimal codec/publish fix, four focused strict GREEN runs,
  then a scoped re-review of these findings.
- Task F1/F4: minor (deferred): `rdma_hw_aeqe_model::logical_cqn_eqn()` has one stale
  failure-boundary phrase `high|(low<<6)` although implementation and preceding
  comment correctly use `(high<<6)|low`. Final whole-branch review must triage it if
  no later directly related task synchronizes that comment.
- Task F1/F4: fix round 1/5 (4 addressed, 0 open; uncommitted fix snapshot hashes
  codec `f157392c7d39`, engine `5ef594521532`, codec test `8483c383068b`,
  device-publish test `55992b49ac9b`). Test-first RED was strict `0/16/0` and
  `0/2/0`; all four focused GREEN runs were PROCESS/LOGICAL PASS with strict
  `0/0/0`; the reproducible replacement mutation RED was strict `0/50/0` and
  explicitly replaces rather than authenticates the historical provenance gap.
- Task F1/F4: complete (uncommitted fix snapshot, scoped review clean). Every
  Critical/Important finding is ADDRESSED and the fix diff introduced no new
  Critical/Important breakage. Re-review:
  `/tmp/review-aeqe-f1f4-fix-round1.md` (SHA-256
  `765984d49cad7112831ffb8f5289ce9121cb2a4a3beb715b0bf30e4ba0c5c0be`).

## Phase 1C recovery ruling and F2 start

- The codec-level X/Z-ingress finding is `FALSE_POSITIVE` for this phase: the public
  `rdma_hw_image.bytes`, Host-memory transport, and deserialize ABI are intentionally
  two-state bytes. If this ruling is wrong, an upstream simulator unknown may already
  be collapsed to zero before this layer; correcting that would require an end-to-end
  four-state transport contract, not a local field-type substitution. Existing direct
  tests of four-state helpers remain valid.
- CQC `local[0..55] -> final[8..63]` per-byte sentinel coverage and independent CQ
  doorbell raw-slice assertions for bit 61, RC `[46:24]`, and URC `[54:40]/[38:24]`
  are `DEFERRED_MINOR`. Production ABI behavior is currently correct, so neither item
  enters the implementation fix loop; final whole-plan review must triage both.
- F2 is inserted before final whole-plan review because `rdma_hw_sqe_model::validate()`
  does not own `sge_num` consistency while the RC codec independently derives and
  writes a wire count. The ruling is that model `sge_num` is canonical and must match
  one shared derivation: empty 0; inline `ceil(payload_bytes/16)` with zero bytes 0;
  direct/external SGE count after null/zero-length filtering; fixed atomic 1. Mismatch
  must fail with no image, and semantic-request construction must populate the same
  value. If wrong, model/wire split-brain remains possible or legal empty, inline,
  filtered, external, or atomic requests could be over-constrained.
- F2 brief: `task-sqe-sge-num-authority-brief.md`. The initial three-file scope was
  expanded after two independent read-only audits proved it would leave the shared
  RC/UD/URC model and queue-data facade inconsistent. Allowed shared-tree SV files are
  the codec and two initial tests plus `src/core/rdma_queue_data_engine.sv`,
  `tests/unit/rdma_ud_urc_sqe_codec_test.sv`,
  `tests/unit/rdma_queue_host_mem_submitter_test.sv`, and
  `tests/unit/rdma_queue_data_engine_post_test.sv`; the implementer must not stage or
  commit. Null SGEs remain invalid even though the numerical derivation excludes them.
- Frozen pre-edit snapshot: `/tmp/phase1c-sge-num-base.qbpSWF`. SHA-256: codec
  `700743c04a3d7f745abe5996cd56f81640621ac08f80ee906e308d8439a75a08`, SQ test
  `4ca47dc68c343facd5c27ed291974f935749c1cb72f095006c0f4cab0b88bce0`, queue test
  `8483c383068bc09dc7cee662ce66698b6cc517c3de684cc6b2e690c584627f01`.
- Scope-expansion snapshot: `/tmp/phase1c-sge-num-scope2.CJISpE`. SHA-256: engine
  `1b5b8091fe2d7b1d44533a2e778dda3122c21611f73575da612415504e10964c`, UD/URC test
  `f0298f3d60730052868fe021b20d06eb140501edb63c57df4e650bd1ca0f8633`, submitter test
  `14a8ad4e3834bbdd9dc56a2e0d30d328bd1d4f0155bd2bbbe89e2637820aa76c`, post test
  `ccf0dcb97e4b41efbf60abe528d90b9a6263402b3bffc236f779614d878fa7e2`.

## User-directed pause for structural refactor (2026-09-17)

- The user explicitly stopped the active Phase 1C F2 closeout and switched the main
  priority to `docs/superpowers/plans/2026-09-17-rdma-structural-refactor.md`. F2 is
  **paused, not complete**; no current source, test, report, or evidence change was
  rolled back.
- The latest frozen F2 source/test snapshot is
  `/tmp/phase1c-sge-num-fix1-final.r940Is`. The fresh code review
  `/tmp/review-sqe-sge-num-fix1-code.md` (SHA-256
  `6af7f1c238f53964ba8534256337ed5590567eccde06cf775498ce915e002ef1`)
  found all functional findings I-1..I-5 and M-1 addressed, with no open
  Critical/Important, but left the content-level comment/readability finding M-2 open.
- Batch100 subsequently closed the previously observed RC raw `INLINE_SGB` fixed-
  capacity gap for `TPL=513` / `SGE_NUM=33`: the codec now rejects payloads above
  the fixed 512-byte/32-chunk SQ-SGB slot before projecting a detached model. The
  focused `rdma_sq_codec_test`, `rdma_queue_codec_test`, and
  `rdma_ud_urc_sqe_codec_test` runs are recorded as wrapper/PROCESS/LOGICAL PASS
  with strict UVM `0/0/0` in `task-cmq-batch100-phase1c-f2-report.md` and the
  corresponding `batch100-*` evidence. This closes only that local capacity defect;
  the broader F2 `sge_num` canonical-authority and whole-plan final verification
  remain paused and must not be marked as Phase 1C/F2 complete.
- Final five-test verification was interrupted. Only the frozen-source
  `rdma_sq_codec_test` was confirmed wrapper rc 0, PROCESS/LOGICAL PASS and strict
  UVM `0/0/0`. `rdma_queue_codec_test` was in progress when stopped; it and the
  remaining three runs are not acceptance evidence.
- Resume F2 from `task-sqe-sge-num-fix-round1.md` and the preserved worktree. The
  structural-refactor takeover snapshot is
  `/tmp/rdma-structural-refactor-baseline.T5YFuc`; its `interrupted-state.md` records
  the exact recovery boundary.
