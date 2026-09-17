#!/usr/bin/env bash
# 目录：scripts/，VCS 53 回归驱动脚本。
# 职责：分别调度 core 与 dpu_common integration 测试，避免 core 编译层引入外部依赖。
# 依赖与所有权：依赖 scripts/run_vcs53.sh；仅消费测试与环境变量，不拥有仿真产物生命周期。
set -euo pipefail

readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly repo_root="$(git -C "$script_dir/.." rev-parse --show-toplevel)"
readonly CORE_TESTS=(
  rdma_smoke_test
  rdma_coverage_test
  rdma_responder_registry_test
  rdma_env_composition_test
  rdma_types_test
  rdma_model_test
  rdma_cmq_engine_models_test
  rdma_control_plane_models_test
  rdma_context_model_test
  rdma_request_model_test
  rdma_adapter_contract_test
  rdma_resource_manager_test
  rdma_aeqe_route_test
  rdma_resource_local_lookup_test
  rdma_queue_runtime_test
  rdma_queue_backing_access_test
  rdma_queue_data_engine_post_test
  rdma_queue_detached_snapshot_test
  # device publish、route-consume 与真实 AEQE E2E 共享 lifecycle fixture，
  # 必须在定义共享 fixture 的 post 测试之后执行。
  rdma_queue_data_engine_device_publish_test
  rdma_queue_event_route_consume_test
  rdma_aeqe_f5_e2e_test
  rdma_queue_host_codec_final_fix_test
  rdma_queue_producer_doorbell_final_fix_test
  rdma_queue_cqe_codec_final_fix_test
  rdma_queue_entry_image_final_fix_test
  rdma_queue_ceqe_codec_final_fix_test
  rdma_queue_aeqe_codec_final_fix_test
  rdma_queue_recovery_lifecycle_final_fix_test
  rdma_queue_data_engine_poll_test
  rdma_queue_data_engine_recovery_test
  rdma_cq_engine_resize_test
  rdma_cqe_size_codec_test
  rdma_sq_models_test
  # SQ/RQ/CQ/EQ engine 共享 queue lifecycle 编译，必须纳入同一 VCS53 回归，
  # 才能共同覆盖 PI/CI、credit 与 doorbell 路径。
  rdma_sq_engine_test
  rdma_rq_engine_test
  rdma_cq_engine_test
  rdma_eq_engine_test
  rdma_queue_host_mem_submitter_test
  rdma_queue_host_mem_submitter_authority_test
  rdma_queue_model_test
  rdma_queue_codec_test
  rdma_doorbell_scheduler_test
  rdma_doorbell_scheduler_authority_test
  rdma_doorbell_scheduler_reset_epoch_test
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
  rdma_cmq_driver_field_mutation_test
  rdma_context_cmq_regression_test
  rdma_queue_lifecycle_models_test
  rdma_context_backing_contract_test
  rdma_queue_page_codec_test
  rdma_sriov_enumerator_authority_test
  rdma_queue_lifecycle_test
  rdma_queue_recovery_test
  rdma_qp_lifecycle_test
  rdma_qp_recovery_test
  rdma_sq_codec_test
  rdma_ud_urc_sqe_codec_test
  rdma_wqe_extended_opcode_test
  rdma_sqe_authority_test
  rdma_sq_payload_writer_test
  rdma_function_identity_test
  rdma_queue_txn_journal_test
  rdma_abi_v5_adapter_test
  rdma_umem_pbl_mw_test
  rdma_cq_shadow_flush_test
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

# 这些文件位于 tests/unit/，但只有 RDMA_DPU_INTEGRATION 定义下才会被
# rdma_unit_test_pkg 注册；单独列出，便于 --list 与 unit 测试发现结果一致，
# 实际执行仍沿用下面的 integration 循环和 dpu_common 环境。
readonly UNIT_INTEGRATION_TESTS=(
  rdma_host_mem_router_test
  rdma_pcie_router_test
  rdma_reset_coordinator_test
)

# engine 的物理 process 由 sim/rdma_cmq_engine_process.list 交给统一
# logical runner 展开；这里仅用于 --list 闭合普通 unit-test 发现集合，
# 不能把 shard 名混进 CORE_TESTS，否则 regression 会重复执行每个 leaf。
readonly ENGINE_PROCESS_TESTS=(
  rdma_cmq_engine_test
  rdma_cmq_engine_base_suffix_process_test
  rdma_cmq_engine_capacity_process_test
  rdma_cmq_engine_submission_process_test
  rdma_cmq_engine_submission_matrix_process_test
  rdma_cmq_engine_profile_wide_process_test
  rdma_cmq_engine_retention_prefix_process_test
  rdma_cmq_engine_submission_continuation_process_test
  rdma_cmq_engine_submission_profile_process_test
  rdma_cmq_engine_invariant_process_test
  rdma_cmq_engine_raw_snapshot_process_test
  rdma_cmq_engine_poll_fault_process_test
  rdma_cmq_engine_poison_reset_process_test
  rdma_cmq_engine_wrap_process_test
  rdma_cmq_engine_wrap_publication_process_test
  rdma_cmq_engine_journal_process_test
  rdma_cmq_engine_mmio_arm_process_test
  rdma_cmq_engine_hostile_factory_process_test
)

if [[ ${1-} == "--list" ]]; then
  if [[ $# -ne 1 ]]; then
    echo "Usage: $0 [--list]" >&2
    exit 2
  fi
  printf '%s\n' "${CORE_TESTS[@]}"
  printf '%s\n' "${ENGINE_PROCESS_TESTS[@]}"
  printf '%s\n' "${UNIT_INTEGRATION_TESTS[@]}"
  exit 0
fi

if [[ $# -ne 0 ]]; then
  echo "Usage: $0 [--list]" >&2
  exit 2
fi

cd "$repo_root"
# regression 由 Makefile 在同一个 VCS 编译产物上逐项运行，避免每个 UVM
# test 都重新复制源码和编译一次；--list 仍保留完整 manifest 供静态检查。
scripts/run_vcs53.sh core regression
scripts/run_vcs53.sh integration regression
