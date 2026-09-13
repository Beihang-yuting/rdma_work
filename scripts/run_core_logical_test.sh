#!/usr/bin/env bash
# 目录/层次：scripts，core UVM logical-to-physical 执行控制层。
# 文件职责：把普通 logical test 映射到自身，把 engine umbrella 展开为十三个
#   独立 simulator process。
# 主要依赖：bash、tee、可执行 simv、strict UVM summary checker，以及只读
#   engine process manifest。
# 资源所有权：调用者拥有 simv/checker/manifest；本脚本只覆盖每个 physical
#   test 的独立日志，不持有外部资源。

set -uo pipefail

if [[ $# -ne 4 ]]; then
  echo "Usage: $0 <logical-test> <build-dir> <engine-manifest> <summary-checker>" >&2
  exit 2
fi

readonly logical_test=$1
readonly logical_build=$2
readonly engine_manifest=$3
readonly summary_checker=$4
readonly engine_logical_test=rdma_cmq_engine_test

# logical test 名同时形成 UVM 参数和日志 basename，先限制为 SV identifier，
# 避免路径分隔、空白或 shell token 把一个 logical execution 扩成非预期资源。
if [[ ! "$logical_test" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "invalid core test: $logical_test" >&2
  exit 2
fi

if [[ ! -d "$logical_build" ]]; then
  echo "core build directory is missing: $logical_build" >&2
  exit 2
fi

if [[ ! -x "$logical_build/simv" ]]; then
  echo "core simulator is not executable: $logical_build/simv" >&2
  exit 2
fi

if [[ ! -x "$summary_checker" ]]; then
  echo "UVM summary checker is not executable: $summary_checker" >&2
  exit 2
fi

declare -a physical_tests=()

# engine manifest 是唯一 physical inventory authority；严格 cardinality、首项、
# identifier 与唯一性校验在任何 simulator 启动前完成，畸形清单不会产生
# 部分日志。
if [[ "$logical_test" == "$engine_logical_test" ]]; then
  if [[ ! -r "$engine_manifest" ]]; then
    echo "engine process manifest is missing: $engine_manifest" >&2
    exit 2
  fi

  mapfile -t physical_tests < <(
    sed -e 's/[[:space:]]*#.*$//' \
        -e '/^[[:space:]]*$/d' "$engine_manifest"
  )

  if (( ${#physical_tests[@]} != 13 )); then
    echo "engine process manifest requires exactly thirteen tests" >&2
    exit 2
  fi

  if [[ "${physical_tests[0]}" != "$logical_test" ]]; then
    echo "engine process manifest must start with $logical_test" >&2
    exit 2
  fi

  declare -A process_seen=()
  for physical_test in "${physical_tests[@]}"; do
    if [[ ! "$physical_test" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      echo "invalid engine process test: $physical_test" >&2
      exit 2
    fi

    if [[ -n "${process_seen[$physical_test]+x}" ]]; then
      echo "duplicate engine process test: $physical_test" >&2
      exit 2
    fi

    process_seen[$physical_test]=1
  done
else
  physical_tests=("$logical_test")
fi

# 每片即使 simulator 或 summary 失败也继续执行后续片；两个状态分别记录，
# 最终 logical status 取全体 all-of，避免后续成功覆盖先前失败证据。
logical_failed=0
for physical_test in "${physical_tests[@]}"; do
  physical_log="$logical_build/$physical_test.log"
  simulator_status=0
  "$logical_build/simv" +UVM_TESTNAME="$physical_test" \
    | tee "$physical_log" || simulator_status=$?

  summary_status=0
  "$summary_checker" "$physical_log" || summary_status=$?

  if (( simulator_status != 0 || summary_status != 0 )); then
    logical_failed=1
    printf 'PROCESS FAIL logical=%s physical=%s simulator=%d summary=%d log=%s\n' \
      "$logical_test" "$physical_test" "$simulator_status" \
      "$summary_status" "$physical_log" >&2
  else
    echo "PROCESS PASS logical=$logical_test physical=$physical_test log=$physical_log"
  fi
done

if (( logical_failed != 0 )); then
  echo "LOGICAL FAIL logical=$logical_test processes=${#physical_tests[@]}" >&2
  exit 1
fi

echo "LOGICAL PASS logical=$logical_test processes=${#physical_tests[@]}"
