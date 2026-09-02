#!/usr/bin/env bash
set -euo pipefail

readonly repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly host_mem_tests=(
  rdma_host_mem_adapter_test
  rdma_queue_data_engine_host_mem_test
)

if [[ $# -ne 0 ]]; then
  echo "Usage: $0" >&2
  exit 2
fi

cd "$repo_root"
for test_name in "${host_mem_tests[@]}"; do
  scripts/run_vcs53.sh host_mem "$test_name"
done
