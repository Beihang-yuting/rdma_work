# Round 2 compatibility fix report

## Root cause and fix

`rdma_resource_manager.project_binding_value()` constructed a new binding by
copying public mirrors and PCIe data but omitted the protected
`rdma_function_identity`. Projected bindings therefore retained the default
zero UID/generation and `make_handle()` returned null. The projection now
explicitly clones the source identity through `configure_identity()`.

`rdma_function_binding` also provides the explicit
`configure_identity_from_legacy_mirrors()` migration API (requiring host/root
and route data), plus an explicit synchronization helper for generation-rebind
fixtures. `make_handle()` and `accepts()` reject mirror/PCIe mismatches while
remaining identity-authoritative.

## VCS53 verification

Commands were run from this worktree with:
`PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 scripts/run_vcs53.sh core <test>`

| Test | Exit | UVM summary |
| --- | ---: | --- |
| `rdma_function_identity_test` | 0 | warning=0 error=0 fatal=0 |
| `rdma_model_test` | 0 | warning=0 error=0 fatal=0 |
| `rdma_queue_lifecycle_test` | 0 | warning=0 error=0 fatal=0 |

`rdma_qp_lifecycle_test` and `rdma_control_plane_cmq_engine_test` were not
executed in this pass.

`git diff --check` passed before commit `8d0a2d5`.

## Host0 correction

Follow-up commit `1fb1d12` makes host topology key 0 (explicit Host0) legal while
retaining zero-BDF and PF/VF route validation. `rdma_function_identity_test`
was rerun on VCS53 and exited 0 with warning=0 error=0 fatal=0. The model,
queue-lifecycle, QP-lifecycle, and control-plane CMQ tests still require a
post-correction run.
