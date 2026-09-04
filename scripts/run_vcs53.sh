#!/usr/bin/env bash
set -euo pipefail

readonly REMOTE_HOST="ubuntu@10.11.10.53"
readonly REMOTE_BASE="/home/ubuntu/workspace"
readonly REMOTE_PREFIX="${REMOTE_BASE}/rdma_uvm."

usage() {
  echo "Usage: $0 <suite> <test|regression>" >&2
}

if [[ $# -ne 2 ]]; then
  usage
  exit 2
fi

suite=$1
test_name=$2

case "$suite" in
  core|integration|host_mem|pcie_work|net_packet|axis_vip|xtr_defs) ;;
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

rsync -a --exclude .git "$repo_root/" "$REMOTE_HOST:$remote_dir/"

remote_env=()
for var_name in HOST_MEM_ROOT PCIE_WORK_ROOT NET_PACKET_ROOT AXIS_VIP_ROOT; do
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
