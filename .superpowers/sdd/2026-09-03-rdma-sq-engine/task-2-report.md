# Task 2 report

## Scope

Implemented QP SQ SGB backing allocation, zeroing, retention and cleanup.

## TDD evidence

Added lifecycle assertions for UD SQ SGB authority, logical depth*512 geometry,
and 512-byte IOVA alignment.  The first VCS run failed before implementation
because `sq_sgb_ref` was not materialized.  After implementation the VCS compile
completed successfully on `ubuntu@10.11.10.53` using `scripts/run_vcs53.sh`.

## Implementation

- Added 512-byte-aligned owned allocation and borrowed-reference handling.
- Added slot-granular zeroing with segment-boundary validation.
- Retained SQ SGB through QP plan copies, recovery equality/projection and
  recovery role progress.
- Added SQ SGB to rollback and destroy cleanup ordering; borrowed references are
  never released by the executor.
- Updated QP fixtures to use the canonical 512-byte inline/SGB capability.

## Verification

`git diff --check` passed. VCS lifecycle compilation/test command:

`scripts/run_vcs53.sh core rdma_qp_lifecycle_test`

completed without compile errors on the VCS host (the harness emits existing
non-fatal no-job-control and keyword warnings).

Follow-up fixture correction: RC/UD requests explicitly select owned SQ-SGB
backing; URC keeps `max_inline_data=32` and does not request SGB.  Queue-data
fixture likewise selects canonical owned SQ-SGB backing.

Generic lifecycle RC requests use the legacy 2-SGE/32-byte-inline capability to
avoid changing unrelated allocation-count assertions.  UD requests retain the
4-SGE/512-byte-inline SQ-SGB path for dedicated coverage.

The UD fixture's staging IOVA expectation is `0x0000000100015000` and its live
allocation baseline is five, accounting for the additional 64 KiB SQ-SGB.

Recovery validation now treats SQ-SGB as optional for RC/URC plans and rejects
completion progress that claims an absent SQ-SGB authority.
