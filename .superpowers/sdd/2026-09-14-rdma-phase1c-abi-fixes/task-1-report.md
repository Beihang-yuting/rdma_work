# Task 1 report: CQE profile-relative header and reserved policy

## Scope and baseline

- Worktree head before this remediation: `c981182` (Task 2 RQE SGB_PA already
  present); prior Task 1 commits: `58fc94c`, `ebbfecc`.
- Driver archive was not modified. CQE coordinates remain header-relative:
  32B/64B at qword0 (byte0), 128B at qword8 (byte64).

## Review-round scope

- Preserved the profile-relative base offset in `encode_fields()` and
  `decode_fields()`.
- Removed the mutable qword3 UD gate and all qword3/payload acceptance from
  this Task 1 follow-up. Task 3 must first add typed fields plus authenticated
  transport/variant discrimination; until then qword3 and extension qwords
  remain fail-closed reserved data.
- Added a minimum-four-qword/null-builder guard before qword3 access and a
  focused short-image test. No driver archive or profile checker mapping was
  changed.

## Remote VCS evidence (login bash on ubuntu@10.11.10.53)

- GREEN CQE:
  `evidence/task-1-green-cqe-final.log` — UVM warning=0/error=0/fatal=0.
- GREEN queue regression:
  `evidence/task-1-green-queue.log` — UVM warning=0/error=0/fatal=0.
- GREEN CQC baseline:
  `evidence/task-1-green-cqc.log` — UVM warning=0/error=0/fatal=0.
- Historical RED for the original header-base defect remains in
  `evidence/task-1-red.log`; this follow-up intentionally has no qword3/payload
  RED because those fields are deferred to Task 3.

## Review notes and concerns

- qword3 UD overlays and inline payload windows are intentionally deferred to
  Task 3, where the model can carry transport/format authority without a
  mutable codec-side discriminator.
- Static `git diff --check` is clean. Existing unrelated dirty files from
  Task 18 were not staged.
