# Task 1 report: CQE profile-relative header and reserved policy

## Scope and baseline

- Worktree head before this remediation: `c981182` (Task 2 RQE SGB_PA already
  present); prior Task 1 commits: `58fc94c`, `ebbfecc`.
- Driver archive was not modified. CQE coordinates remain header-relative:
  32B/64B at qword0 (byte0), 128B at qword8 (byte64).

## Changes

- Preserved the profile-relative base offset in `encode_fields()` and
  `decode_fields()`.
- Added exact qword3 mask constants for `UD_SMAC[63:16]` and
  `UD_VLAN_TAG[15:0]`, guarded by an explicit `set_ud_qword3_enabled()` UD
  variant gate. The default registry codec remains fail-closed for non-UD
  images; Task 3 owns transport discriminator wiring.
- Kept 64B qword4..7 and 128B qword0..7 opaque according to the fixed profile
  payload geometry. The archived source has no field/payload macro for 128B
  qword12..15, so that tail remains strict zero.
- Added a minimum-four-qword check before qword3 access to reject malformed
  builders without out-of-range indexing.
- Added focused tests for legal qword3 fields, opaque payload/prefix bytes,
  explicit UD gating, 8-bit unknown ECODE (`8'hff`), and strict 128B tail.

## Remote VCS evidence (login bash on ubuntu@10.11.10.53)

- RED (pre-fix legal qword3/payload rejected):
  `evidence/task-1-red-qword3.log` — UVM warning=0/error=3/fatal=0.
- GREEN CQE:
  `evidence/task-1-green-cqe-final.log` — UVM warning=0/error=0/fatal=0.
- GREEN queue regression:
  `evidence/task-1-green-queue.log` — UVM warning=0/error=0/fatal=0.

## Review notes and concerns

- `set_ud_qword3_enabled()` is intentionally an explicit local authority hook;
  no transport/variant discriminator exists in the current CQE model. Task 3
  must connect this gate to authenticated UD profile data and add non-UD/UD
  mismatch negatives before broadening the public model.
- Payload bytes are accepted solely by the documented 64B/128B geometry; no
  typed payload fields are introduced in Task 1. Future typed fields must keep
  the same base offset and exact mask discipline.
- Static `git diff --check` is clean. Existing unrelated dirty files from
  Task 18 were not staged.
