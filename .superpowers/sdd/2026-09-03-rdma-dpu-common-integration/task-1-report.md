# Task 1 round2 verification report

## Scope

- Queue transaction evidence now captures detached snapshots for function identity,
  queue handle, semantic request, CQE, hardware image, and failure status.
- Evidence `do_copy` deep-clones all owned objects and release plans. Compatibility
aliases (`capture_queue_h`, `capture_request_snapshot`, `capture_cqe_snapshot`,
  `set_failure_status`, plus setter-style queue/request/CQE aliases) route through
  the same APIs.
- All transaction phase side effects use the guarded transition helper; terminal and
  bypass attempts are rejected. Chinese comments document ownership, lifecycle and
  recovery semantics.
- Function identity is the sole binding authority. Identity is protected and exposed
  only as detached snapshots/configuration; legacy scalar fields are consistency
  mirrors and never a fallback. Global function ID zero remains valid.
- Host/root/segment/BDF route validity is centralized in `rdma_identity_types.sv` and
  enforced by identity validation and transaction capture.
- `rdma_handle` and `rdma_status` now implement complete deep-copy semantics so
  cloned evidence preserves owner identity and diagnostic status fields.
- Unit tests cover no-fallback behavior, global ID zero, invalid routes, accessor and
  transaction clone isolation, capture/set APIs, and transition bypass protection.

## Verification

`git diff --check` passed.

On VCS simulation host 10.11.10.53 (exit 0):

```
PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
  scripts/run_vcs53.sh core rdma_function_identity_test
```

UVM summary: warning=0, error=0, fatal=0.

```
PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
  scripts/run_vcs53.sh core rdma_queue_txn_journal_test
```

UVM summary: warning=0, error=0, fatal=0.

The compile emits the pre-existing TEIF warning in
`tests/mocks/rdma_mock_control_plane.sv:388` (task enabled inside a function);
the runtime UVM reports remain pristine.

## Round2 follow-up

Commit `282430d` intentionally permits any valid PCIe function number for a VF's
parent PF (multi-function PFs are legal); validation still requires a non-zero,
same-segment parent BDF distinct from the VF BDF. Formatting was corrected in the
follow-up commit. `git diff --check` was rerun, and
`rdma_function_identity_test` was rerun on 10.11.10.53 after this adjustment with
exit 0 and UVM warning=0/error=0/fatal=0. The transaction test had already passed
with the same evidence implementation and is unaffected by this route relaxation.
