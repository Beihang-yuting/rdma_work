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

Post-Host0 rerun: queue lifecycle, QP lifecycle, control-plane CMQ, identity,
and transaction journal all exited 0 with warning=0 error=0 fatal=0. Resource
manager remains blocked by legacy generation mutation fixtures pending explicit
synchronization migration.

The transaction journal additionally covers recording a distinct second WQE
release while already in partial-release phase.

`git diff --check` passed before commit `8d0a2d5`.

## Host0 correction

Follow-up commit `1fb1d12` makes host topology key 0 (explicit Host0) legal while
retaining zero-BDF and PF/VF route validation. `rdma_function_identity_test`
was rerun on VCS53 and exited 0 with warning=0 error=0 fatal=0. The model,
queue-lifecycle, QP-lifecycle, and control-plane CMQ tests still require a
post-correction run.

## Phase 1C Task 1 — CQE profile-relative 128B header

### Scope and implementation

The CQE codec now derives an active qword window from the builder profile:
32/64B use qword0..qword2 and 128B uses qword8..qword10 (byte64). Field
encode/decode offsets and reserved checks use that same base. Prefix qwords in a
128B image are intentionally opaque, while qwords after the active three-qword
window remain fail-closed. Image length, alignment, endian, generation and
target metadata are unchanged.

Tests add a nonzero-prefix raw 128B decode case, a byte0-only negative case, and
queue-codec raw qword8/qword9/qword10 assertions. The 128B explicit-image tail
check now starts after the active window at byte88.

### RED evidence

`scripts/run_vcs53.sh core rdma_cqe_size_codec_test` failed before the codec
change with `CQE_PROFILE_RELATIVE_DECODE` and `CQE_PROFILE_RELATIVE_BYTE0`
(UVM warning=0, error=2, fatal=0).

### GREEN evidence

- `scripts/run_vcs53.sh core rdma_cqe_size_codec_test`: exit 0; UVM
  warning=0, error=0, fatal=0; `PROCESS PASS` and `LOGICAL PASS`.
- `scripts/run_vcs53.sh core rdma_queue_codec_test`: exit 0; UVM warning=0,
  error=0, fatal=0; `PROCESS PASS` and `LOGICAL PASS`.
- `python3 tools/check_changed_sv_style.py --base HEAD --head HEAD`: pass.
- `git diff --check`: pass.

### Style remediation follow-up

Review against `3f85367..HEAD` found adjacent-comment label typos in two
changed test tasks, an undocumented `image_bytes()` accessor, merged
declarations, and compressed CQE field functions. These were expanded or
corrected without changing field masks, profile offsets, or test assertions.
The follow-up verification was rerun on VCS53 for both focused tests; each
returned exit 0 with UVM warning=0, error=0, fatal=0. The changed-line checker
and `git diff --check` are both clean.
