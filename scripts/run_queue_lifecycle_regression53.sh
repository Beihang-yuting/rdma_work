#!/usr/bin/env bash
# 目录：scripts/，VCS 53 回归驱动脚本。
# 职责：调度 core 编译层的全部 UVM 测试（CORE_TESTS），core 层不引入外部依赖。
# 依赖与所有权：依赖 scripts/run_vcs53.sh；仅消费测试与环境变量，不拥有仿真产物生命周期。
set -euo pipefail

readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly repo_root="$(git -C "$script_dir/.." rev-parse --show-toplevel)"
readonly CORE_TESTS=(
  rdma_smoke_test
  rdma_types_test
  rdma_aeqe_route_test
  rdma_dev_cmq_test
  rdma_drv_cmq_test
  rdma_drv_cmq_golden_test
  rdma_drv_dev_test
  rdma_drv_verbs_test
  rdma_drv_data_test
  rdma_drv_reliability_test
  rdma_drv_qp_lifecycle_test
  rdma_multifunc_test
  rdma_defs_test
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
# regression 由 Makefile 在同一个 VCS 编译产物上逐项运行，避免每个 UVM
# test 都重新复制源码和编译一次；--list 仍保留完整 manifest 供静态检查。
scripts/run_vcs53.sh core regression
