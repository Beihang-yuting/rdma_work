# Phase 1C ABI fixes progress

Identity: documentation/planning phase; no implementation tasks started.
Plan: 2026-09-14-rdma-phase1c-abi-fixes
Spec: 2026-09-14-rdma-phase1c-abi-fixes-design
Status: Task 0 (CQC baseline) pending; Tasks 1-7 pending.
Constraint: source and test files are intentionally untouched by this docs commit.

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

Task 0: implementation complete at `571266e`; report `task-0-report.md` records
RED (`CQC_RAW_PI` assertion) and focused GREEN for CMQ/CQE-size tests. Scoped review
found Important gaps: CQ state/size and independent raw oracle coverage were
incomplete, CQE-size raw evidence was weak, and RED/GREEN logs were not auditable.
Fix round 1 dispatched to the original implementer; unrelated Task 18 changes remain
unstaged.

## Task 18 remediation pointer

Task 18 remediation is implemented in the CMQ engine/adapter and its observed-envelope
tests. The detailed authority, malformed-envelope, legacy-seam, inventory, and fresh VCS
evidence is recorded in
`.superpowers/sdd/2026-09-11-rdma-cmq-contract-foundation/task-18-report.md`.
The current working tree deliberately keeps Task 1/2 queue codec files out of this
remediation scope. Fresh 53-host checks cover the CMQ port, fifteen-leaf engine logical
gate, control-plane CMQ route, control-plane consumer, queue lifecycle, and QP lifecycle;
the report records each command, summary, and log digest.
