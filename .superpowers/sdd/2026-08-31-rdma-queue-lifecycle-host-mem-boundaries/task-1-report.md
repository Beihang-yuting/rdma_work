# Task 1 report

Implemented `tools/check_queue_lifecycle.py` and unit coverage in `tests/unit/test_check_queue_lifecycle.py`.

Commands:

* `python3 -m pytest -q tests/unit/test_check_queue_lifecycle.py` — unavailable (`No module named pytest`).
* `python3 -m unittest tests.unit.test_check_queue_lifecycle` — 9 tests run; 8 pass, 1 error because the current policy source does not contain `rdma_queue_base_from_iova` (the checker correctly fails closed).
* `python3 tools/check_queue_lifecycle.py` — exits 1 for the same missing policy helper.
* `git diff --check` — clean.

The normal-repository success test and real checker remain blocked until the policy includes the required projection helper, as specified by the boundary contract.

## Round 1 fixes

Integrated `rdma_queue_base_from_iova` in policy `backing_iova`, hardened explicit core-file and class parsing checks, and added malformed/missing fixture coverage. `python3 -m unittest tests.unit.test_check_queue_lifecycle` passes (11 tests); `python3 tools/check_queue_lifecycle.py` exits 0; `git diff --check` is clean. Commit: `235a5e165a0bae71495a6f3da2fa93f885da43ed`.

## Round 2 fixes

Helper detection now strips comments; added a comment-forgery negative test and modified frozen-ABI fixture test. 13 unittest tests pass, real checker exits 0, and `git diff --check` is clean.

## Round 3 fixes

Frozen ABI fixture now initializes a temporary git repository, commits baseline files, then modifies one file; the checker invocation executes a real `git diff` (baseline hash translated to temporary HEAD). 13 unittest tests pass; checker and whitespace checks are clean.

## Final review fixes

Core dependency validation now scans all `src/core/*.svh` (including unlisted headers) while preserving explicit required-file checks; an `evil.svh` regression fixture was added. The host-memory queue fixture now asserts ring and PD backing addresses exceed 32-bit range. `python3 -m unittest tests.unit.test_check_queue_lifecycle` passes (14 tests), `python3 tools/check_queue_lifecycle.py` exits 0, and `git diff --check` is clean. VCS host_mem execution remains blocked by the previously reported unavailable pinned checkout path.
