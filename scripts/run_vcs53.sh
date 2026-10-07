#!/usr/bin/env bash
set -euo pipefail

readonly REMOTE_HOST="ubuntu@10.11.10.53"
readonly REMOTE_BASE="/home/ubuntu/workspace"
readonly REMOTE_PREFIX="${REMOTE_BASE}/rdma_uvm."
readonly RSYNC_EXCLUDES=(
  --exclude=/.git/
  --exclude=/.worktrees/
  --exclude=/sim/build/
  --exclude='**/__pycache__/'
  --exclude='__pycache__/'
  --exclude='*.pyc'
)

usage() {
  # 功能：打印 run_vcs53 的命令行用法，供参数失败路径调用。
  # 输入输出及副作用：无输入；向 stderr 输出一行 Usage，不修改环境。
  # 失败边界：输出本身不报告状态，调用者负责返回具体错误码。
  echo "Usage: $0 <suite> <test|regression>" >&2
}

sync_repo() {
  # 功能：以固定排除集合把仓库同步到目标，并可选择 rsync dry-run。
  # 输入输出及副作用：输入 source、destination 和可选 --dry-run；执行 rsync，正常模式写目标目录。
  # 失败边界：参数个数或模式非法返回 2；rsync 失败原样返回且不会隐式添加空选项。
  if [[ $# -lt 2 || $# -gt 3 ]]; then
    printf 'Usage: sync_repo <source> <destination> [--dry-run]\n' >&2
    return 2
  fi
  local source=$1 destination=$2 mode_arg=${3:-}
  local -a rsync_args=(-a --itemize-changes)
  case "$mode_arg" in
    "") ;;
    --dry-run) rsync_args+=(--dry-run) ;;
    *) printf 'Unsupported sync mode: %s\n' "$mode_arg" >&2; return 2 ;;
  esac
  rsync "${rsync_args[@]}" "${RSYNC_EXCLUDES[@]}" "$source/" "$destination/"
}

main() {
  # 功能：校验 suite/test，建立隔离远端目录，同步输入并在登录 shell 中运行指定 Make 目标。
  # 输入输出及副作用：输入两个命令行参数和五个 allowlisted root 环境变量；通过 SSH/rsync 运行远端仿真并清理目录。
  # 失败边界：非法参数、远端路径格式、同步/SSH/Make 失败均返回非零；清理失败会提升成功状态。
  if [[ $# -ne 2 ]]; then
  usage
  exit 2
  fi

suite=$1
test_name=$2

case "$suite" in
  core|cmq_gate|env|pcie_work|rxe|axis_vip|rdma_defs) ;;
  *)
    echo "Unsupported suite: $suite" >&2
    usage
    exit 2
    ;;
esac

if [[ "$test_name" != "regression" && ! "$test_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "Invalid test name: $test_name" >&2
  usage
  exit 2
fi

repo_root=$(git rev-parse --show-toplevel)
remote_dir=$(ssh "$REMOTE_HOST" "mktemp -d ${REMOTE_PREFIX}XXXXXX")

if [[ ! "$remote_dir" =~ ^/home/ubuntu/workspace/rdma_uvm\.[A-Za-z0-9]{6}$ ]]; then
  echo "Refusing unexpected remote directory: $remote_dir" >&2
  exit 1
fi

cleanup() {
  local command_status=$?

  trap - EXIT
  if ! ssh "$REMOTE_HOST" "rm -rf -- '$remote_dir'"; then
    echo "Failed to remove remote simulation directory: $remote_dir" >&2
    if (( command_status == 0 )); then
      command_status=1
    fi
  fi
  exit "$command_status"
}
trap cleanup EXIT

sync_repo "$repo_root" "$REMOTE_HOST:$remote_dir"

remote_env=()
for var_name in HOST_MEM_ROOT DPU_COMMON_ROOT PCIE_WORK_ROOT NET_PACKET_ROOT AXIS_VIP_ROOT; do
  if [[ -v "$var_name" ]]; then
    printf -v quoted_value '%q' "${!var_name}"
    remote_env+=("$var_name=$quoted_value")
  fi
done

printf -v quoted_remote_dir '%q' "$remote_dir"
printf -v quoted_suite '%q' "$suite"
printf -v quoted_test '%q' "$test_name"
remote_command="cd $quoted_remote_dir/sim &&"
if (( ${#remote_env[@]} )); then
  remote_command+=" ${remote_env[*]}"
fi
remote_command+=" make $quoted_suite TEST=$quoted_test"
printf -v quoted_remote_command '%q' "$remote_command"

ssh "$REMOTE_HOST" "bash -lic $quoted_remote_command"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
