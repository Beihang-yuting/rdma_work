# Task 1 report

Implemented semantic/QP SQ capability model foundation.

Files changed: `src/model/rdma_context_layouts.sv` (detached UD AV fields and clone support), `src/model/rdma_semantic_requests.sv` (create-QP inline/SGB capability fields and validation; post-send fence and detached AV snapshot clone), `src/model/rdma_queue_lifecycle_models.sv` (SQ-SGB role, geometry helpers, 512-byte alignment handling), `tests/unit/rdma_sq_models_test.sv` (focused model test), and test package registration.

Decisions: SQ SGB is required for UD transport; geometry is depth*512 logical bytes rounded to 4KiB storage. Inline limits are 512 bytes maximum and 32 bytes when no SGB is required; max_send_sge is capped at 32. Existing `rdma_resources.sv` and `rdma_queue_models.sv` required no direct edits for this contract in this task branch.

Tests: `scripts/run_vcs53.sh core rdma_sq_models_test` completed successfully (VCS compile and test invocation exit 0; only pre-existing warning messages, no model errors observed). The brief also requests `rdma_request_model_test`; not rerun after final edits due time.

Concerns: QP backing-plan `sq_sgb_ref` and full canonical backing validation remain lifecycle integration work; this task only adds model primitives and request fields.

## Review fixes

Commit `19128d8` adds detached QP capability fields and plan SQ-SGB authority reference, with clone/validation handling and canonical SQ-SGB backing checks (512-byte slot alignment, rounded storage geometry, role validation). Focused regressions should be rerun by controller.

## Review round 2

Commit `$(git rev-parse --short HEAD)` fixes SQ-SGB plan validation to require 4KiB-rounded storage (including segmented references) and applies 512-byte alignment to SQ-SGB backing refs/segments while preserving 4KiB alignment for other roles.

## Review round 3

Plan validation now computes total SQ-SGB backing length across additional segments and requires exact rounded storage coverage, rejecting oversized/malformed segmented refs while permitting canonical 512+3584 segmentation.

## Post-review capability correction

Corrected `rdma_qp_needs_sq_sgb()` to implement the full specification: UD always requires SQ-SGB; RC requires it when either send or receive SGE capacity exceeds two; URC never requires it. The focused test now covers UD, RC `(3,1)`, RC `(2,2)`, and URC cases. A controller rerun remains authoritative because the requested remote VCS invocation reached the compile inline pass but did not emit a final UVM summary before handoff.
