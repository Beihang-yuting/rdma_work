#!/usr/bin/env bash
# 目录/层次：scripts，core UVM 单测执行控制层。
# 文件职责：在已编译的 simv 上运行一个 UVM test，写独立日志并做严格 summary 检查。
# 主要依赖：bash、tee、可执行 simv、strict UVM summary checker。
# 资源所有权：调用者拥有 simv/checker；本脚本只覆盖该 test 的日志，不持有外部资源。

set -uo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <logical-test> <build-dir> <summary-checker>" >&2
  exit 2
fi

readonly logical_test=$1
readonly logical_build=$2
readonly summary_checker=$3

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

declare -a physical_tests=("$logical_test")

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
