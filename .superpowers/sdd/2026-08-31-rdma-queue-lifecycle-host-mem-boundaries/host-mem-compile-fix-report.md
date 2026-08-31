# Host-memory compile fix report

## Change

Qualified the integration fixture's queue PD codec type and factory reference
with `rdma_codec_pkg::`. The fixture is included at compilation-unit scope,
where the package wildcard import inside `rdma_unit_test_pkg` is not visible to
VCS. No production adapter, pinned host_mem checkout, Makefile, or frozen ABI
was changed.

## Verification

- `HOST_MEM_ROOT=/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/host_mem PATH=/tmp/rdma_sshpass_wrapper_codex:$PATH SSHPASS=123 scripts/run_vcs53.sh host_mem rdma_host_mem_adapter_test`
  - preflight passed (pinned commit and hashes)
  - compile/elab/simulation completed
  - UVM report counts: WARNING=0, ERROR=0, FATAL=0
- `python3 -m unittest tests.unit.test_check_queue_lifecycle tests.unit.test_check_xtr_v1_defs`
  - 103 tests passed
- `python3 tools/check_queue_lifecycle.py` passed
- `git diff --check` passed

## Concerns

The VCS53 shell emits the expected non-interactive `no job control` warning.
No functional concerns remain for this fixture.
