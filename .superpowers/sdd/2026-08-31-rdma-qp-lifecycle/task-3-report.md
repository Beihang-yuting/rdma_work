# Task 3 Report: QP plan and semantic QPC builder

## Delivered

- Added `rdma_qp_lifecycle_executor` and registered it in the core package.
- Materializes 64-byte SQ/private-RQ backing, control-plane-owned page
  directories, URC RSQ/RDSQ/DSQ backing, and a distinct 512-byte QPC staging
  allocation. Borrowed backing is cloned and remains unreleased.
- Acquires an HMC QP context separately from staging; projects semantic QPC
  fields, chooses RC/UD/URC codecs, and requires encode/decode serialized
  equality without modifying image bytes.
- Covers RC private-RQ geometry and authority separation, RC+SRQ authority
  and exact depth, UD semantic projection, URC internal geometry, and
  manager-returned detached QP snapshots.
- Preserves canonical borrowed SQ/RQ coverage across multiple detached
  segments, zeros every caller-authority slice, emits literal per-page PD
  entries, then rebinds the persistent copies to the global QP incarnation.
- Registered the test in `tests/rdma_unit_test_pkg.sv` so it executes.

## Narrow prerequisite correction

`rdma_qp.do_copy()` independently clones `srq_h` and
`qp_plan.rq_source_h`; it never aliases or sanitizes either handle. The two
cloned values must retain exact global SRQ instance identity, and a mismatched
caller graph remains mismatched after cloning so validation can reject it.
The serialized QPC still carries a distinct local 15-bit SRQ projection, so
QPC validation checks its kind/Function/generation presence while the executor
projects the authoritative local SRQ ID.

## Planner boundary ruling

The existing `rdma_queue_backing_planner` deliberately rejects QP roles and
only owns legacy queue-plan contracts. This task preserves that separation:
the QP executor uses the same host-memory allocation, alignment, detached
release-authority, and validation primitives, without widening the legacy
planner or creating a second public QP-plan API.

## TDD evidence

RED command:

```text
scripts/run_vcs53.sh core rdma_qp_lifecycle_test
```

The initial test failed to compile at
`tests/unit/rdma_qp_lifecycle_test.svh` because
`rdma_qp_lifecycle_executor` was undeclared; this proved the test was wired
to the missing production interface.

GREEN commands, all run through `scripts/run_vcs53.sh` on VCS host 10.11.10.53:

```text
scripts/run_vcs53.sh core rdma_qp_lifecycle_test
scripts/run_vcs53.sh core rdma_xtr_v1_qpc_codec_test
git diff --check
```

Both simulations reported `UVM_ERROR : 0`, `UVM_FATAL : 0`, and `UVM report
is pristine`; `git diff --check` produced no output. The frozen QPC codec
test remains green.

## Deliberate Task 4 limitations

`create_locked()` stops after semantic plan/QPC attachment in PROGRAMMED and
releases temporary staging; it does not submit CMQ programming or activate a
QP. `modify_locked`, `destroy_locked`, and `recover_locked` deliberately
return unsupported. Full operation rollback, durable recovery, CMQ outcome
handling, and activation remain Task 4 work.

## Fix Round 1

- `tests/unit/rdma_qp_lifecycle_test.svh` now covers the global QP staging
  owner and UD semantic codec path. Its initial UD run was RED with invalid
  transport ECN bits; the UD fixture now uses a legal traffic class and is
  green (`UVM_ERROR : 0`, `UVM_FATAL : 0`).
- Owned QP mappings now validate opaque release authority before and after
  snapshot copying and release any allocation that cannot be returned. The
  staging allocation now uses the global QP handle and performs an ACTIVE,
  expected-owner generation fence after write and before attach.
- QP borrowed backing accepts canonical multiple slices, retains detached
  segment mappings, and resolves each PD entry through the appropriate slice.
  All caller-authority slices are zeroed before detached persistent mappings
  are rebound to the global QP owner. Model/resource-manager projection and
  equality preserve segments; borrowed segments remain non-releasable by QP
  cleanup.
- Added a checked total-coverage helper and extended recovery validation to
  reject invalid pending segment state or normalize every released segment
  only after that role is complete.
- Added focused tests for non-null failed-allocation cleanup, opaque authority
  checks before and after copy, the global staging owner, stale post-write
  rebinding, URC caller-address rejection, RC+SRQ exact-depth and clone-preserved
  mismatch rejection, multi-slice SQ/RQ detachment/ownership/zeroing/literal PD
  bytes, manager snapshot detachment, and additional-segment recovery states.

### Fix-round RED evidence

All simulation commands below ran through `scripts/run_vcs53.sh` on VCS host
10.11.10.53.

```text
scripts/run_vcs53.sh core rdma_queue_lifecycle_models_test
```

Before the checked coverage helper existed, compilation reported two
undeclared-identifier errors for `rdma_qp_backing_total_length`, one at each
SQ/RQ plan-validation call site.

```text
scripts/run_vcs53.sh core rdma_qp_lifecycle_test
```

Before multi-slice materialization was implemented, the focused create path
reported `BORROWED_MULTI_CREATE` with `RDMA_SC_DMA_TRANSLATION` and message
`DMA mapping is unknown`.

The same lifecycle command was also run with the inherited helper guards
temporarily removed. It reported 11 UVM errors covering the non-null allocation
cleanup, both opaque-authority checks, global staging owner, stale-generation
publication fence, and SRQ mismatch sanitization. The intended guards were
restored before the final-tree runs.

### Final-tree GREEN evidence

```text
scripts/run_vcs53.sh core rdma_qp_lifecycle_test
scripts/run_vcs53.sh core rdma_resource_manager_test
scripts/run_vcs53.sh core rdma_queue_lifecycle_models_test
scripts/run_vcs53.sh core rdma_xtr_v1_qpc_codec_test
git diff --check
```

Each of the four VCS runs reported the same pristine summary:
`UVM_WARNING : 0`, `UVM_ERROR : 0`, `UVM_FATAL : 0`, followed by
`UVM report is pristine: warning=0 error=0 fatal=0`. The final
`git diff --check` produced no output.

Remaining comprehensive Task 4 fault matrix, transaction rollback aggregation,
CMQ programming, and activation are intentionally deferred.
