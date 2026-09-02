# Task 2 implementation and fix-round report

## Outcome

Task 2 adds QP context backing, 21-bit local-QPN identity and sequence
tracking, and the nine QP-specific resource-manager mutation/finalization
methods.  Fix round 1 makes those methods the exclusive ordinary QP mutation
authority, binds ERROR recovery to the registry snapshot and opaque adapter
capabilities, orders cleanup progress, and makes programmed-QP publication a
single authoritative projection.

The original Task 2 implementation is commit `64c0a6a` (`feat: add QP context
and manager authority`).  This report accompanies the fix-round commit.

## Original Task 2 evidence

The initial RED runs recorded in `progress.md` were:

- `scripts/run_vcs53.sh core rdma_context_backing_contract_test`: QP context
  acquisition was rejected.
- `scripts/run_vcs53.sh core rdma_resource_manager_test`: compilation failed
  because the nine QP manager methods were absent.

The implementation then passed both focused tests on VCS53.  During the first
manager convergence, the resource-manager test moved from 33 errors to 14
after the Task 1 local/global QP identity correction, to 7 after migrating
dependency-QP release, and to 0 after migrating the all-kind QP paths to the
QP-specific publication/error APIs.  A progress-test compile-order issue was
also corrected by keeping declarations before procedural statements; this was
a fixture correction, not behavioral RED evidence.

## Fix round 1 behavior

- Generic stage/program/error/reserved-error entry points reject QPs before
  mutation; the QP-specific methods remain the ordinary publication authority.
- `mark_qp_error()` binds MODIFY/NORMAL_DESTROY prior QPCs and CREATE_ROLLBACK
  candidate QPCs to the authoritative programmed QPC.  The only ERROR-record
  replacement is an ambiguity resolution that preserves all other retained
  authority and cleanup progress.
- Flush progress precedes context cleanup.  Opaque context completion precedes
  owned backing cleanup.  Duplicates and failed predecessors are atomic.
- Finalization requires resolved ambiguity, matching and opaquely complete
  resource/recovery context authority, complete retained staging/query
  mappings, complete owned backing release, and no live dependents.
- Both ordinary and reconciliation programmed commits project the registry QP
  first and overlay only `programmed_qpc`, its corresponding semantic
  `qp_state`, and the required ACTIVE resource state.  Reconciliation accepts
  only the exact retained prior or candidate QPC; prior restores the pre-error
  semantic state and candidate derives semantic state from its retained QPC.

`release_function()` remains unchanged as the privileged whole-generation
teardown path.

## Focused RED/GREEN evidence

Every entry below used
`scripts/run_vcs53.sh core rdma_resource_manager_test` on VCS53.

| Behavior | RED evidence | GREEN evidence |
| --- | --- | --- |
| Generic QP mutation bypasses | 8 errors | 0/0/0 |
| Authoritative prior/candidate QPC binding | 9 errors | 0/0/0 |
| Controlled unresolved-to-resolved ERROR replacement | 2 errors | 0/0/0 |
| Cleanup ordering and opaque completion proof | 14 errors | 0/0/0 |
| Unresolved ambiguity blocks finalization | targeted failure during gate removal | 0/0/0 |
| Retained staging finalization | `QP_FINALIZE_RETAINED_STAGING_INCOMPLETE`, 0/1/0 | 0/0/0 |
| Retained query finalization | `QP_FINALIZE_RETAINED_QUERY_INCOMPLETE`, 0/1/0 | 0/0/0 |
| Reconciliation query retirement | `QP_RESTORE_QUERY_COMPLETION_REQUIRED`, 0/1/0 | 0/0/0 |
| Reconciliation staging retirement | `QP_RESTORE_STAGING_COMPLETION_REQUIRED`, 0/1/0 | 0/0/0 |
| Reconciliation ambiguity/ticket retirement | `QP_RESTORE_AMBIGUITY_RESOLUTION_REQUIRED`, 0/1/0 | 0/0/0 |
| Exact-prior semantic restoration | `QP_PRIOR_SEMANTIC_RESTORE`, 0/1/0 | 0/0/0 |
| Reconciliation preserves unrelated QP fields | `QP_PRIOR_SEMANTIC_RESTORE`, 0/1/0 | 0/0/0 |
| Candidate semantic state comes from retained QPC | `QP_RESTORE_ACTIVE`, 0/1/0 | 0/0/0 |
| Ordinary commit preserves unrelated QP fields | `QP_PROGRAMMED_AUTHORITY`, 0/1/0 | 0/0/0 |
| Recovery context capability checked at finalization | `QP_FINALIZE_CONTEXT_AUTHORITY_REJECTED`, 0/1/0 | 0/0/0 |

The first retained-staging fixture used the general helper's 4096-byte mapping
and was rejected by the model's required 512-byte temporary-mapping geometry.
After correcting only the fixture size, removing the staging gate produced the
valid single-error RED shown above.

Nested projection coverage was first GREEN with the real manager, then proven
with temporary production mutations and restored:

- Removing QPC address-vector and behavior equality produced exactly two
  errors (`QP_NESTED_ADDRESS_VECTOR_REJECTED` and
  `QP_NESTED_BEHAVIOR_REJECTED`), 0/2/0.
- Removing QP-plan context capability identity produced
  `QP_NESTED_CONTEXT_AUTHORITY_REJECTED` plus its atomicity assertion, 0/2/0.
- Removing QP-plan owned-mapping opaque capability matching produced exactly
  `QP_NESTED_MAPPING_AUTHORITY_REJECTED`, 0/1/0.
- Transport-extension mutation, standalone/plan recovery context capability,
  and retained staging/query capability substitutions are exercised through
  public manager calls and reject without changing registry/recovery state.

All temporary production mutations were restored before final verification.

## Scope and interface audit

Fix-round files:

- `src/core/rdma_resource_manager.svh`
- `tests/unit/rdma_resource_manager_test.svh`
- `.superpowers/sdd/2026-08-31-rdma-qp-lifecycle/task-2-report.md`

The nine public QP method declarations at the Task 2 base and fix-round head
are identical: `qp_sequence`, `attach_qp_programming`,
`commit_qp_semantic_state`, `commit_qp_programmed`, `mark_qp_error`,
`record_qp_flush_complete`, `record_qp_cleanup_complete`,
`record_qp_context_cleanup_complete`, and `finalize_qp_release`.  No Task 1
model file was modified.

## Final verification

Final evidence is recorded after running:

```text
scripts/run_vcs53.sh core rdma_context_backing_contract_test
scripts/run_vcs53.sh core rdma_resource_manager_test
git diff --check
```

Both VCS53 tests completed with zero UVM warnings, errors, or fatals
(`0/0/0`).  `git diff --check` completed with no diagnostics.

## Fix round 2: recovery retirement gates

Round 2 preserves the same nine public QP manager signatures and does not
modify any Task 1 model file.  It closes four authority gaps left by the first
fix round:

- Successful ERROR context cleanup now requires resolved ambiguity and
  atomically records outer recovery hardware presence as ABSENT.
- ERROR finalization independently requires ABSENT; QUIESCING finalization is
  unchanged.
- Owned backing cleanup follows the exact reverse dependency order
  `URC_DSQ -> URC_RDSQ -> URC_RSQ -> RQ_PD -> SQ_PD -> RQ_RING -> SQ_RING`,
  while absent, SRQ-owned, and borrowed roles are skipped.
- Modify reconciliation validates the caller as the complete desired ACTIVE
  replacement before any recovery gate or caller-sanitizing publication:
  exact retained QPC, its matching semantic state, and every unrelated QP
  field from the authoritative ERROR snapshot.

### Round-2 focused RED/GREEN evidence

Every behavioral run below used
`scripts/run_vcs53.sh core rdma_resource_manager_test` on VCS53.

| Behavior | RED evidence | GREEN evidence |
| --- | --- | --- |
| ERROR context cleanup persists hardware absence | `QP_CONTEXT_ABSENCE`, 0/1/0 | 0/0/0 |
| Unresolved ambiguity blocks context cleanup atomically | gate, atomicity, and follow-on duplicate assertions, 0/3/0 | 0/0/0 |
| ERROR finalization explicitly requires ABSENT | gate plus resource/recovery atomicity cascade, 0/6/0 | 0/0/0 |
| RC reverse cleanup requires RQ_PD before SQ_PD | predecessor, post-proof predecessor, atomicity, and follow-on cleanup, 0/4/0 | 0/0/0 |
| URC exact reverse order requires DSQ before RDSQ before RSQ | two predecessor gates, two atomicity checks, and follow-on cleanup, 0/6/0 | 0/0/0 |
| Reconciliation rejects semantic/index/IOVA mismatch before publication | three rejection and six registry/recovery atomicity assertions, 0/9/0 | 0/0/0 |

The lifecycle test also proves that borrowed SQ/RQ ring refs neither require
cleanup for finalization nor accept an owned-cleanup completion record.  The
URC fixture completes all three opaque releases before its order probes, so
the failures isolate predecessor ordering rather than release-completion
readiness.  Reconciliation rejection coverage snapshots both registry and
recovery after semantic-state, queue-index, IOVA, retained-QPC,
address-vector, behavior, query-release, staging-release, and ambiguity-gate
failures.

One test-only hardware-presence setter in the probe manager creates the
otherwise unreachable inconsistent recovery fixture needed to prove the
finalization gate.  It does not alter production API surface.

### Round-2 final verification

Final evidence is recorded from the final tree with:

```text
scripts/run_vcs53.sh core rdma_resource_manager_test
scripts/run_vcs53.sh core rdma_context_backing_contract_test
git diff --check
```

Both final VCS53 runs completed with pristine UVM summaries (`0/0/0`).
`git diff --check` completed with no diagnostics.
