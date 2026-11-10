#!/usr/bin/env bash
# 目录/层次：integration/project/tests；53上的完整Intel类型编译与现有wire fixture入口。
# 职责：展开两份独立清单，显式选择top，保留编译/运行日志并核对完成及零W/E/F。
# 依赖：登录bash配置的VCS/license及六个实际依赖checkout；不构建或修改外部仓库。
# 所有权/生命周期：RDMA_INTEL_RUN拥有本次构建产物；不复用Task6 binary或删除已有日志。
set -euo pipefail
: "${RDMA_ROOT:?absolute RDMA checkout required}"
: "${AIP_CORE_ROOT:?expression-capable AIP checkout required}"
: "${HOST_MEM_ROOT:?Host memory checkout required}"
: "${DPU_COMMON_ROOT:?complete DPU working tree required}"
: "${PCIE_WORK_ROOT:?complete PCIe working tree required}"
: "${PCIE_INTEL_ROOT:?Intel checkout required}"
: "${NET_PACKET_ROOT:?network packet checkout required}"
export RDMA_INTEL_RUN=${RDMA_INTEL_RUN:-"$RDMA_ROOT/output/validation/task7_intel"}
export RDMA_ROOT AIP_CORE_ROOT HOST_MEM_ROOT DPU_COMMON_ROOT PCIE_WORK_ROOT PCIE_INTEL_ROOT NET_PACKET_ROOT
mkdir -p "$RDMA_INTEL_RUN"
cd "$RDMA_ROOT"
# 固定展开类型清单和fixture附加清单；不增加递归filelist解释器或修改旧sim构建入口。
python3 - <<'PY'
import os
from pathlib import Path
for source, target in [('integration/filelists/rdma_project.f', 'project.expanded.f'),
                       ('integration/project/tests/project_intel.f', 'fixture.expanded.f')]:
    text = Path(source).read_text()
    for key in ['AIP_CORE_ROOT', 'HOST_MEM_ROOT', 'DPU_COMMON_ROOT', 'PCIE_WORK_ROOT',
                'PCIE_INTEL_ROOT', 'NET_PACKET_ROOT']:
        text = text.replace('@' + key + '@', os.environ[key])
    (Path(os.environ['RDMA_INTEL_RUN']) / target).write_text(text)
PY
vcs -full64 -sverilog -ntb_opts uvm -timescale=1ns/1ps -debug_access+r+w+f -lca \
    -LDFLAGS -Wl,--no-as-needed +define+AIP_VCS2018_COMPAT \
    -f "$RDMA_INTEL_RUN/project.expanded.f" -f "$RDMA_INTEL_RUN/fixture.expanded.f" \
    -top rdma_project_transport_top -Mdir="$RDMA_INTEL_RUN/csrc" \
    -o "$RDMA_INTEL_RUN/simv" > "$RDMA_INTEL_RUN/build.log" 2>&1
cd "$RDMA_INTEL_RUN"
timeout --kill-after=10s 180s ./simv -exitstatus +UVM_NO_RELNOTES > run.log 2>&1
# 既有fixture在全部断言后才报告此UVM_INFO；汇总中的同名ID不能代替完成消息。
grep -Eq '^UVM_INFO .*\[PROJECT_TRANSPORT_PASS\]' run.log
if grep -Eq '^UVM_(WARNING|ERROR|FATAL) .*@|^Error-|^Fatal[-:]|^Error:|^ERROR:|^FATAL:' run.log; then
    cat run.log
    exit 1
fi
for severity in WARNING ERROR FATAL; do
    grep -Eq "^UVM_${severity}[[:space:]]*:[[:space:]]*0[[:space:]]*$" run.log
    if grep -Eq "^UVM_${severity}[[:space:]]*:[[:space:]]*[1-9][0-9]*[[:space:]]*$" run.log; then
        cat run.log
        exit 1
    fi
done
echo PROJECT_INTEL_TYPES_PASS
