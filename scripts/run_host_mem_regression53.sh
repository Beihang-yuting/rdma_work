#!/usr/bin/env bash
# 目录：scripts/，Host-memory 真实后端回归驱动脚本。
# 职责：在 VCS53 登录 bash 中按固定顺序运行 Host-memory adapter、queue
#   data-engine 和 UMEM/PBL/MW 生命周期测试，确保每项测试都经过同一 preflight。
# 依赖与所有权：依赖 scripts/run_vcs53.sh 和 HOST_MEM_ROOT；脚本只调度测试，
#   不拥有外部 host_mem manager、仿真产物或日志生命周期。
set -euo pipefail

readonly repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly host_mem_tests=(
  rdma_host_mem_adapter_test
  rdma_queue_data_engine_host_mem_test
  rdma_host_mem_umem_test
  rdma_tb_host_mem_test
)

if [[ $# -ne 0 ]]; then
  echo "Usage: $0" >&2
  exit 2
fi

cd "$repo_root"
# regression 由 Makefile 在同一个 VCS 编译产物上逐项运行；保留数组供
# --list/静态契约和 Makefile 的 fail-closed manifest 提取使用。
scripts/run_vcs53.sh host_mem regression
