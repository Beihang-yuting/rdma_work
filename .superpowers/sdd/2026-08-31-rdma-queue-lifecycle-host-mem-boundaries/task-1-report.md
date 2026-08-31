# Task 1 report

Implemented `tools/check_queue_lifecycle.py` and unit coverage in `tests/unit/test_check_queue_lifecycle.py`.

Commands:

* `python3 -m pytest -q tests/unit/test_check_queue_lifecycle.py` — unavailable (`No module named pytest`).
* `python3 -m unittest tests.unit.test_check_queue_lifecycle` — 9 tests run; 8 pass, 1 error because the current policy source does not contain `rdma_queue_base_from_iova` (the checker correctly fails closed).
* `python3 tools/check_queue_lifecycle.py` — exits 1 for the same missing policy helper.
* `git diff --check` — clean.

The normal-repository success test and real checker remain blocked until the policy includes the required projection helper, as specified by the boundary contract.
