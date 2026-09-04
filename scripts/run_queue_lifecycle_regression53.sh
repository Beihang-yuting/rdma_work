#!/usr/bin/env bash
set -euo pipefail

readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly repo_root="$(git -C "$script_dir/.." rev-parse --show-toplevel)"
readonly core_tests=(
  rdma_smoke_test
  rdma_types_test
  rdma_model_test
  rdma_cmq_engine_models_test
  rdma_control_plane_models_test
  rdma_context_model_test
  rdma_request_model_test
  rdma_adapter_contract_test
  rdma_resource_manager_test
  rdma_queue_runtime_test
  rdma_queue_backing_access_test
  rdma_queue_data_engine_post_test
  rdma_queue_data_engine_poll_test
  rdma_queue_data_engine_recovery_test
  # SQ/RQ/CQ/EQ engines share the queue lifecycle build and must run in the
  # same VCS 53 regression so PI/CI, credits and doorbell paths are covered.
  rdma_sq_engine_test
  rdma_rq_engine_test
  rdma_cq_engine_test
  rdma_eq_engine_test
  rdma_queue_host_mem_submitter_test
  rdma_queue_model_test
  rdma_queue_codec_test
  rdma_doorbell_scheduler_test
  rdma_cmq_engine_test
  rdma_cmq_port_test
  rdma_control_plane_test
  rdma_control_plane_cmq_engine_test
  rdma_codec_registry_test
  rdma_defs_test
  rdma_qword_codec_test
  rdma_doorbell_codec_test
  rdma_qpc_codec_test
  rdma_context_body_codec_test
  rdma_cmq_codec_test
  rdma_error_codec_test
  rdma_cmq_completion_test
  rdma_cmq_profile_test
  rdma_context_cmq_regression_test
  rdma_queue_lifecycle_models_test
  rdma_context_backing_contract_test
  rdma_queue_page_codec_test
  rdma_queue_lifecycle_test
  rdma_queue_recovery_test
  rdma_qp_lifecycle_test
  rdma_qp_recovery_test
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
