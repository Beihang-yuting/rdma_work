# Task 6 fix report — QP destroy recovery fences

## Changes

Destroy and destroy-recovery CMQ operations now use a fenced execute helper,
checking the binding before and after ERROR MODIFY, each OCC flush, and
QPC_DELETE. Context, backing, and finalization boundaries likewise fence both
sides and fail closed on stale generations. Ticketless ambiguous retries
persist `has_pending_hardware_step` and operation/role authority; manager
replacement validation admits only same-authority pending-marker refreshes.
All destroy/recovery manager lookup, progress, and finalization calls now
check null/error returns and preserve ERROR recovery on failure. A focused VCS53
test injects a generation rebind after destroy MODIFY and verifies no later
CMQ side effects and retained recovery authority.

## Verification

* `git diff --check` passed.
* `scripts/run_vcs53.sh core rdma_qp_lifecycle_test` reached successful VCS
  compile/elaboration/link on VCS53. Runtime was not completed within the
  harness timeout in this environment.

## Concerns

The stale-boundary runtime assertion should be rerun by the controller with an
unbounded/longer simulation timeout. The untracked regression helper was not
included in the commit.
