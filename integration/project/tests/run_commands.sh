#!/usr/bin/env bash
# 目录/层次：integration/project/tests；指定ubuntu@10.11.10.53执行的独立构建/桥验证入口。
# 职责：展开实际依赖filelist、构建两种top、运行真实Tcl及同binary双进程restore。
# 依赖：登录bash中的VCS/license、已构建且匹配AIP工作树的dist .so；不修改任何依赖。
# 所有权/生命周期：RDMA_RUN指定独立产物目录；保留日志/快照，不删除其他构建。
set -euo pipefail
: "${RDMA_ROOT:?absolute RDMA checkout required}"
: "${AIP_CORE_ROOT:?matching expression-capable AIP staging required}"
: "${DPU_COMMON_ROOT:?complete DPU working tree required}"
: "${HOST_MEM_ROOT:?Host memory checkout required}"
: "${PCIE_WORK_ROOT:?PCIe checkout required}"
: "${NET_PACKET_ROOT:?network packet checkout required}"
export AIP_CORE="$AIP_CORE_ROOT"
export RDMA_RUN=${RDMA_RUN:-"$RDMA_ROOT/output/validation/task6"}
mkdir -p "$RDMA_RUN"
export RDMA_ROOT AIP_CORE_ROOT DPU_COMMON_ROOT HOST_MEM_ROOT PCIE_WORK_ROOT NET_PACKET_ROOT
cd "$RDMA_ROOT"
python3 - <<'PY'
import os
from pathlib import Path
for source, target in [('commands.f', 'commands.expanded.f'), ('namespace.f', 'namespace.expanded.f')]:
    text = (Path(os.environ['RDMA_ROOT'])/'integration/project/tests'/source).read_text()
    for key in ['AIP_CORE_ROOT','DPU_COMMON_ROOT','HOST_MEM_ROOT','PCIE_WORK_ROOT','NET_PACKET_ROOT']:
        text = text.replace('@'+key+'@', os.environ[key])
    (Path(os.environ['RDMA_RUN'])/target).write_text(text)
PY
vcs -full64 -sverilog -ntb_opts uvm -timescale=1ns/1ps -debug_access+r+w+f -lca \
    -LDFLAGS -Wl,--no-as-needed +define+AIP_VCS2018_COMPAT \
    -f "$RDMA_RUN/commands.expanded.f" -top rdma_project_command_top \
    -Mdir="$RDMA_RUN/csrc" -o "$RDMA_RUN/simv" > "$RDMA_RUN/build.log" 2>&1
vcs -full64 -sverilog -ntb_opts uvm -timescale=1ns/1ps -debug_access+r+w+f -lca \
    -LDFLAGS -Wl,--no-as-needed +define+AIP_VCS2018_COMPAT \
    -f "$RDMA_RUN/namespace.expanded.f" -top rdma_project_namespace_top \
    -Mdir="$RDMA_RUN/namespace_csrc" -o "$RDMA_RUN/namespace_simv" > "$RDMA_RUN/namespace_build.log" 2>&1
cd "$RDMA_RUN"
# 功能：对所有正向日志区分UCLI命令回显与实际诊断，拒绝原始错误/警告并核对UVM最终零W/E/F汇总。
# 输入/输出及副作用：log/marker/report_mode指定日志、完成标记及required/optional报告约束；失败打印原日志。
# 失败/边界：缺实际输出标记、原始诊断、非零或缺失必需汇总均失败；save/namespace无报告时只使用断言/标记。
check_positive_log() {
    local log=$1 marker=$2 report_mode=$3 severity
    # PASS必须是独立输出行；诊断扫描只忽略带ucli%提示符的命令回显。
    # awk读完整文件后给出结果，不使用grep -q管道，避免pipefail将提前退出误判为无错误。
    if ! grep -Eq "^${marker}$" "$log" ||
       awk '
           /^[[:space:]]*ucli%/ { next }
           /^UVM_(WARNING|ERROR|FATAL) .*@|^PROJECT_FAIL|^Error-|^Fatal[-:]|^Error:|^ERROR:|^FATAL:/ { failed = 1 }
           END { exit !failed }
       ' "$log"; then
        cat "$log"
        return 1
    fi
    if [[ $report_mode == required ]] || grep -Eq 'UVM Report Summary|^UVM_(WARNING|ERROR|FATAL)[[:space:]]*:' "$log"; then
        for severity in WARNING ERROR FATAL; do
            if ! grep -Eq "^UVM_${severity}[[:space:]]*:[[:space:]]*0[[:space:]]*$" "$log" ||
               grep -Eq "^UVM_${severity}[[:space:]]*:[[:space:]]*[1-9][0-9]*[[:space:]]*$" "$log"; then
                cat "$log"
                return 1
            fi
        done
    fi
}
# 功能：运行正向真实桥进程并交由统一日志门禁检查。
# 输入/输出及副作用：label/script/marker/report_mode/plusargs为输入，保留完整log；失败返回非零。
# 失败/边界：进程失败、超时或日志门禁拒绝均失败；timeout不自动重试。
run_positive() {
    local label=$1 script=$2 marker=$3 report_mode=$4
    shift 4
    timeout --kill-after=10s 180s ./simv -ucli -do "$script" "$@" > "$label.log" 2>&1
    check_positive_log "$label.log" "$marker" "$report_mode"
}
common=(+UVM_NO_RELNOTES +rdma.qp.type=RC +rdma.traffic.op=write +rdma.traffic.signaled_pct=100)
run_positive commands "$RDMA_ROOT/integration/project/tests/rdma_project_commands.tcl" PROJECT_COMMANDS_PASS required "${common[@]}"
run_positive prepare_failure "$RDMA_ROOT/integration/project/tests/rdma_project_prepare_failure.tcl" PROJECT_PREPARE_FAILURE_PASS required "${common[@]}"
run_positive probe_failure "$RDMA_ROOT/integration/project/tests/rdma_project_probe_failure.tcl" PROJECT_PROBE_FAILURE_PASS required "${common[@]}"
run_positive save "$RDMA_ROOT/integration/project/tests/rdma_project_save.tcl" PROJECT_SAVE_PASS optional "${common[@]}" +rdma.traffic.count=10
run_positive restore "$RDMA_ROOT/integration/project/rdma_restore.tcl" PROJECT_RESTORE_PASS required "${common[@]}" +rdma.traffic.count=20
run_positive absent "$RDMA_ROOT/integration/project/tests/rdma_project_restore_absent.tcl" PROJECT_RESTORE_ABSENT_PASS required "${common[@]}"
timeout --kill-after=10s 180s ./namespace_simv -ucli \
    -do "$RDMA_ROOT/integration/project/tests/rdma_project_namespace.tcl" > namespace.log 2>&1
check_positive_log namespace.log PROJECT_NAMESPACE_PASS optional
# 重复注册与父类配置fatal为两个单独负向进程，不能计入正向0/0/0。
negative_rc=0
timeout --kill-after=10s 180s ./simv -ucli \
    -do "$RDMA_ROOT/integration/project/tests/rdma_project_duplicate.tcl" "${common[@]}" > duplicate.log 2>&1 || negative_rc=$?
if [[ $negative_rc -eq 124 ]]; then exit 1; fi
grep -Eq "Command 'load_params' already registered" duplicate.log
grep -Eq '^PROJECT_DUPLICATE_PRESERVED$' duplicate.log
negative_rc=0
timeout --kill-after=10s 180s ./simv -ucli \
    -do "$RDMA_ROOT/integration/project/tests/rdma_project_config_failure.tcl" "${common[@]}" > config_failure.log 2>&1 || negative_rc=$?
if [[ $negative_rc -eq 124 ]]; then exit 1; fi
grep -Eq 'UVM_FATAL.*PROJECT_CONFIG_SEQ.*declare_af' config_failure.log
if grep -Eq 'expected inherited configuration fatal did not terminate' config_failure.log; then exit 1; fi
echo PROJECT_TASK6_PASS
