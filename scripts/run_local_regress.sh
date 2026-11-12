#!/usr/bin/env bash
# 目录：scripts/run_local_regress.sh，本机（无远端同步）回归入口。
# 职责：按清单在当前机器上运行仿真：每个 suite 只编译一次（make build_<suite>），清单每行运行一次
#   simv，可带 plusargs 与种子，用 check_uvm_summary.sh 判定，最后打印汇总。适用于本地虚拟机等
#   已配置好 VCS 与 *_ROOT 环境变量的机器；53 主机仍可使用 run_vcs53.sh。
# 清单格式（# 起注释）：<suite> <test> [tag ...] [+plusarg ...]
#   suite 为 core/env；以 + 或 - 开头的字段原样传给 simv，其余字段视为标签忽略，因此
#   sim/regression.list 也可直接使用。未给 +ntb_random_seed 时使用 RDMA_SEED 或随机种子并打印。
# 依赖：sim/Makefile 的 build_<suite> 目标、scripts/check_uvm_summary.sh、VCS 与 *_ROOT 环境变量。
# 所有权：只写 sim/build/<suite>/ 下的编译产物与日志，不改源码。
# 生命周期：一次调用完成编译与运行；任一测试失败时退出码为 1。
set -uo pipefail

readonly REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly SIM_DIR="$REPO_ROOT/sim"
readonly CHECKER="$REPO_ROOT/scripts/check_uvm_summary.sh"

usage() {
  # 功能：打印用法。
  # 输入输出及副作用：向 stderr 输出；不修改环境。
  # 失败边界：无；调用者决定退出码。
  echo "Usage: $0 [list-file] (default: sim/param_regression.list; RDMA_SEED, RDMA_SUITES optional)" >&2
}

build_suite() {
  # 功能：编译一个 suite（make build_<suite>），日志写入 sim/build/<suite>/build.log。
  # 输入输出及副作用：$1 为 suite 名；生成 sim/build/<suite>/simv。
  # 失败边界：suite 不受支持或编译失败返回非零并打印日志尾部。
  local suite=$1
  local log="$SIM_DIR/build/$suite/build.log"

  case "$suite" in
    core|env) ;;
    *) echo "unsupported suite: $suite" >&2; return 2 ;;
  esac
  mkdir -p "$SIM_DIR/build/$suite"
  echo "BUILD suite=$suite log=$log"
  if ! make -C "$SIM_DIR" --no-print-directory "build_$suite" > "$log" 2>&1; then
    tail -40 "$log" >&2
    echo "BUILD FAIL suite=$suite" >&2
    return 1
  fi
}

run_one() {
  # 功能：运行一个清单项：选种子、运行 simv、检查 UVM 汇总，打印 PASS/FAIL 行。
  # 输入输出及副作用：$1 suite，$2 序号，$3 test，其余为 simv 参数；日志写入 sim/build/<suite>/。
  # 失败边界：simv 或汇总检查失败返回 1。
  local suite=$1 index=$2 test=$3
  shift 3
  local -a args=("$@")
  local seed="" arg log status=0

  for arg in "${args[@]}"; do
    [[ "$arg" == +ntb_random_seed=* ]] && seed=${arg#+ntb_random_seed=}
  done
  if [[ -z "$seed" ]]; then
    seed=${RDMA_SEED:-$(( (RANDOM << 15) | RANDOM ))}
    args+=("+ntb_random_seed=$seed")
  fi
  log="$SIM_DIR/build/$suite/${test}.${index}.log"
  (cd "$SIM_DIR" && "build/$suite/simv" +UVM_TESTNAME="$test" "${args[@]}") > "$log" 2>&1 \
    || status=$?
  if (( status == 0 )) && "$CHECKER" "$log" > /dev/null 2>&1; then
    echo "PASS suite=$suite test=$test seed=$seed log=$log"
    return 0
  fi
  echo "FAIL suite=$suite test=$test seed=$seed simv=$status log=$log args=${args[*]}" >&2
  return 1
}

main() {
  # 功能：解析清单，按 suite 首次出现顺序各编译一次，再按清单顺序运行全部项并汇总。
  # 输入输出及副作用：$1 为可选清单路径；RDMA_SUITES（空格分隔）可只运行其中的 suite。
  # 失败边界：清单缺失返回 2；任一编译或测试失败返回 1。
  local list=${1:-$SIM_DIR/param_regression.list}
  local -a suites=() lines=()
  local line suite test field pass=0 fail=0 index=0
  local -A built=() wanted=()

  if [[ ! -r "$list" ]]; then
    usage
    echo "list not found: $list" >&2
    return 2
  fi
  for suite in ${RDMA_SUITES:-}; do
    wanted[$suite]=1
  done
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%%#*}
    read -r -a fields <<< "$line"
    (( ${#fields[@]} >= 2 )) || continue
    suite=${fields[0]}
    if (( ${#wanted[@]} )) && [[ -z "${wanted[$suite]+x}" ]]; then
      continue
    fi
    lines+=("$line")
    if [[ -z "${built[$suite]+x}" ]]; then
      built[$suite]=pending
      suites+=("$suite")
    fi
  done < "$list"
  for suite in "${suites[@]}"; do
    if build_suite "$suite"; then
      built[$suite]=ok
    else
      built[$suite]=fail
    fi
  done
  for line in "${lines[@]}"; do
    read -r -a fields <<< "$line"
    suite=${fields[0]}
    test=${fields[1]}
    local -a simargs=()
    for field in "${fields[@]:2}"; do
      [[ "$field" == [+-]* ]] && simargs+=("$field")
    done
    index=$((index + 1))
    if [[ "${built[$suite]}" != ok ]]; then
      echo "FAIL suite=$suite test=$test reason=build" >&2
      fail=$((fail + 1))
      continue
    fi
    if run_one "$suite" "$index" "$test" "${simargs[@]}"; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
    fi
  done
  echo "LOCAL REGRESSION SUMMARY total=$((pass + fail)) pass=$pass fail=$fail list=$list"
  (( fail == 0 ))
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
