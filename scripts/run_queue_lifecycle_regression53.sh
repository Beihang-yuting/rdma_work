#!/usr/bin/env bash
# 目录：scripts/，VCS 53 回归驱动脚本。
# 职责：分别调度 core 与 dpu_common integration 测试，避免 core 编译层引入外部依赖。
# 依赖与所有权：依赖 scripts/run_vcs53.sh；仅消费测试与环境变量，不拥有仿真产物生命周期。
set -euo pipefail

readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly repo_root="$(git -C "$script_dir/.." rev-parse --show-toplevel)"
readonly CORE_TESTS=(
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
  rdma_sq_models_test
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
  rdma_sq_codec_test
  rdma_sq_payload_writer_test
  rdma_function_identity_test
  rdma_queue_txn_journal_test
)

# 功能：列出必须在 dpu_common integration 编译定义下运行的测试。
# 输入输出及副作用：测试名由调用方传给 run_vcs53.sh integration，不修改 core 编译输入。
# 失败边界：缺少 DPU_COMMON_ROOT 或 integration 测试注册时由仿真入口返回失败。
readonly INTEGRATION_TESTS=(
  rdma_dpu_integration_test
  rdma_function_context_test
  rdma_device_env_test
  rdma_reset_cascade_test
  rdma_pcie_router_test
  rdma_host_mem_router_test
  rdma_reset_coordinator_test
)

if [[ ${1-} == "--list" ]]; then
  if [[ $# -ne 1 ]]; then
    echo "Usage: $0 [--list]" >&2
    exit 2
  fi
  printf '%s\n' "${CORE_TESTS[@]}"
  exit 0
fi

if [[ $# -ne 0 ]]; then
  echo "Usage: $0 [--list]" >&2
  exit 2
fi

cd "$repo_root"
for test_name in "${CORE_TESTS[@]}"; do
  scripts/run_vcs53.sh core "$test_name"
done

for test_name in "${INTEGRATION_TESTS[@]}"; do
  scripts/run_vcs53.sh integration "$test_name"
done
