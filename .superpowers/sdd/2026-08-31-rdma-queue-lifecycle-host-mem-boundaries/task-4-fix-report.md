# Task 4 fix report

## Scope

Moved the `rdma_iova_t effective_iova` declaration in
`src/core/rdma_queue_lifecycle_policy.svh::backing_iova()` into the function's
declaration section. The existing overflow check and
`rdma_queue_base_from_iova` projection helper call are unchanged.

## Verification

* `python3 -m unittest -v tests/unit/test_check_xtr_v1_defs.py tests/unit/test_check_queue_lifecycle.py` — exit **0**; 102 tests passed.
* `python3 tools/check_queue_lifecycle.py` — exit **0**.
* `git diff --check` — exit **0**.
* `PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_lifecycle_test` — exit **0**. VCS compilation and simulation completed; UVM report summary: `UVM_WARNING=0`, `UVM_ERROR=0`, `UVM_FATAL=0`.

The non-interactive shell warnings (`cannot set terminal process group`, `no job control`) are expected from the SSH wrapper and do not affect the result.
