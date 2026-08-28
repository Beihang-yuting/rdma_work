# Task 13 verification report

The queue recovery implementation was verified on VCS53 (`10.11.10.53`) with
the login-shell environment from `~/.bashrc`.

| Command | Exit | UVM summary |
| --- | ---: | --- |
| `PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_recovery_test` | 0 | warning=0, error=0, fatal=0 |
| `PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 scripts/run_vcs53.sh core rdma_cmq_port_test` | 0 | warning=0, error=0, fatal=0 |
| `PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 scripts/run_vcs53.sh core rdma_control_plane_test` | 0 | warning=0, error=0, fatal=0 |

The focused recovery matrix also covers authenticated typed QUERY evidence:
raw-CQE owner/opcode/ecode/WQE/wrap and CMQ ticket/status identity are
cross-checked before a response can prove PRESENT.  Only the opcode-specific
invalid-context whitelist can prove ABSENT, and only with a non-OK command
status; SRFQ and arbitrary nonzero ecodes remain UNKNOWN.  QUERY evidence never
crosses an incomplete OCC barrier.

The recovery test now drives an SRQ through a timed-out first pre-delete OCC,
late OCC success, an authenticated QUERY ABSENT reconciliation, and a
definitive failure of the remaining pre-delete OCC.  The queue remains ERROR
with an incomplete OCC target and no host/context/reservation release.  The
inherited executor matrices are also run from this focused test: ambiguous CQ
OCC outcomes retain ERROR/no-release, and a failed context cleanup can be
retried exactly once without duplicating physical releases.

Create timeout recovery was exercised for late success, definitive late
failure, and still-pending outcomes.  Late success/failure rolls back the
ambiguous create and reaches `RESOURCE_RELEASED`; a pending ticket remains an
ERROR recovery record.  A normal-destroy late delete failure and a failed
pre-delete SRQ OCC completion restore the already-published queue to ACTIVE
without issuing destructive or local-release side effects.  The recovery
executor selects `finalize_release()` from the recovery intent; only
create-rollback recovery persists the reservation-only `RESOURCE_RELEASED`
pending step required by `release_reserved()`.

`git diff --check` is clean.  The pre-existing untracked
`tools/__pycache__/` directory is unrelated and is not part of this change.

No known verification concerns remain for the three requested suites.  A full
repository-wide regression was not run in this task.
