#!/usr/bin/env bash
set -euo pipefail

readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly repo_root="$(git -C "$script_dir/.." rev-parse --show-toplevel)"
readonly core_tests=(
  rdma_queue_lifecycle_models_test
  rdma_request_model_test
  rdma_context_backing_contract_test
  rdma_resource_manager_test
  rdma_xtr_v1_qpc_codec_test
  rdma_qp_lifecycle_test
  rdma_qp_recovery_test
  rdma_control_plane_test
  rdma_control_plane_cmq_engine_test
  rdma_queue_lifecycle_test
  rdma_queue_recovery_test
)

if [[ ${1-} == "--list" ]]; then
  if [[ $# -ne 1 ]]; then
    echo "Usage: $0 [--list]" >&2
    exit 2
  fi
  printf '%s\n' "${core_tests[@]}"
  exit 0
fi

if [[ $# -ne 0 ]]; then
  echo "Usage: $0 [--list]" >&2
  exit 2
fi

cd "$repo_root"
for test_name in "${core_tests[@]}"; do
  scripts/run_vcs53.sh core "$test_name"
done
