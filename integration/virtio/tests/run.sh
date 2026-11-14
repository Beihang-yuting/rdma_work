#!/usr/bin/env bash
# 目录/层次：integration/virtio/tests；仅在 ubuntu@10.11.10.53 登录 bash 运行。
# 职责：编译实际组合环境，验证直接注册配置 sequence、多 Host/PF/VF、重载及跨进程 restore。
# 依赖：七个源码根、VCS/license 和匹配的 AIP dist；不修改依赖源码。
# 所有权/生命周期：RDMA_VIRTIO_RUN 保存 binary/log/checkpoint；不删除其他回归产物。
set -euo pipefail
: "${RDMA_ROOT:?absolute RDMA checkout required}"
: "${VIRTIO_WORK_ROOT:?current virtio_work source required}"
: "${AIP_CORE_ROOT:?matching AIP source and dist required}"
: "${DPU_COMMON_ROOT:?DPU source required}"
: "${HOST_MEM_ROOT:?Host memory source required}"
: "${NET_PACKET_ROOT:?packet source required}"
: "${PCIE_WORK_ROOT:?PCIe source required}"
: "${PCIE_INTEL_ROOT:?Intel source required}"
export AIP_CORE="$AIP_CORE_ROOT"
export RDMA_VIRTIO_RUN=${RDMA_VIRTIO_RUN:-"$RDMA_ROOT/output/virtio_integration"}
export RDMA_ROOT VIRTIO_WORK_ROOT AIP_CORE_ROOT DPU_COMMON_ROOT HOST_MEM_ROOT NET_PACKET_ROOT PCIE_WORK_ROOT PCIE_INTEL_ROOT
mkdir -p "$RDMA_VIRTIO_RUN"
cd "$RDMA_ROOT"
python3 - <<'PY'
import os
from pathlib import Path
text = Path('integration/filelists/rdma_virtio.f').read_text()
for key in ['VIRTIO_WORK_ROOT', 'AIP_CORE_ROOT', 'DPU_COMMON_ROOT', 'HOST_MEM_ROOT',
            'NET_PACKET_ROOT', 'PCIE_WORK_ROOT', 'PCIE_INTEL_ROOT']:
    text = text.replace('@'+key+'@', os.environ[key])
if os.environ.get('RDMA_DMA_VIEWS_SMOKE_ONLY') == '1':
    text += ('\n+incdir+integration/virtio/tests\n'
             'integration/virtio/tests/rdma_dma_views_test.sv\n')
else:
    text += ('\nintegration/virtio/tests/rdma_project_config_test.sv\n'
             '+incdir+integration/virtio/tests\n'
             'integration/virtio/tests/rdma_virtio_test_pkg.sv\n'
             'integration/virtio/tests/rdma_virtio_top.sv\n')
(Path(os.environ['RDMA_VIRTIO_RUN'])/'expanded.f').write_text(text)
PY
sim_top=rdma_virtio_top
if [[ ${RDMA_DMA_VIEWS_SMOKE_ONLY:-0} == 1 ]]; then
    sim_top=rdma_dma_views_top
fi
vcs -full64 -sverilog -ntb_opts uvm -timescale=1ns/1ps -debug_access+r+w+f -lca \
    -LDFLAGS -Wl,--no-as-needed +define+AIP_VCS2018_COMPAT \
    -f "$RDMA_VIRTIO_RUN/expanded.f" -top "$sim_top" \
    -Mdir="$RDMA_VIRTIO_RUN/csrc" -o "$RDMA_VIRTIO_RUN/simv" > "$RDMA_VIRTIO_RUN/build.log" 2>&1
cd "$RDMA_VIRTIO_RUN"
# 功能：运行实际 Tcl 脚本并检查独立 PASS、原始诊断和 UVM 零 W/E/F 汇总。
# 输入/输出及副作用：label/script/marker/report 加 plusargs；保留独立日志，失败返回非零。
# 失败/边界：超时、缺标记、原始错误/警告或非零/缺失汇总均拒绝；save 尚未执行 report。
run_case() {
    local label=$1 script=$2 marker=$3 report=$4 severity
    shift 4
    timeout --kill-after=10s 180s ./simv -ucli -do "$RDMA_ROOT/integration/virtio/tests/$script" \
        +UVM_NO_RELNOTES "$@" > "$label.log" 2>&1
    if ! grep -Eq "^${marker}$" "$label.log" ||
       awk '/^[[:space:]]*ucli%/ { next }
            /^UVM_(WARNING|ERROR|FATAL) .*@|^PROJECT_FAIL|^Error-|^Fatal[-:]|^Error:|^ERROR:/ { bad=1 }
            END { exit !bad }' "$label.log"; then
        tail -100 "$label.log"
        return 1
    fi
    if [[ $report == required ]]; then
        for severity in WARNING ERROR FATAL; do
            grep -Eq "^UVM_${severity}[[:space:]]*:[[:space:]]*0[[:space:]]*$" "$label.log"
            if grep -Eq "^UVM_${severity}[[:space:]]*:[[:space:]]*[1-9]" "$label.log"; then return 1; fi
        done
        grep -Eq '^UVM_INFO .*\[RDMA_VIRTIO_PASS\]' "$label.log"
    fi
    echo "$label: $marker"
}
# 功能：直接运行不需要 Tcl 的 UVM fixture，并验证 marker、原始诊断和零 W/E/F 汇总。
# 输入/输出及副作用：label/marker 选择日志与通过条件；保留独立日志，失败返回非零。
# 失败/边界：超时、缺 marker、原始错误/警告或非零/缺失汇总均拒绝。
run_direct_case() {
    local label=$1 marker=$2 severity
    timeout --kill-after=10s 180s ./simv +UVM_NO_RELNOTES > "$label.log" 2>&1
    if ! grep -Eq "^${marker}$" "$label.log" ||
       awk '/^UVM_(WARNING|ERROR|FATAL) .*@|^PROJECT_FAIL|^Error-|^Fatal[-:]|^Error:|^ERROR:/ { bad=1 }
            END { exit !bad }' "$label.log"; then
        tail -100 "$label.log"
        return 1
    fi
    for severity in WARNING ERROR FATAL; do
        grep -Eq "^UVM_${severity}[[:space:]]*:[[:space:]]*0[[:space:]]*$" "$label.log"
        if grep -Eq "^UVM_${severity}[[:space:]]*:[[:space:]]*[1-9]" "$label.log"; then return 1; fi
    done
    echo "$label: $marker"
}
common=(+vio.pairs=1 +vio.queue_type=VQ_PACKED +vio.queue_size=256 +vio.rx_buf_size=2048
    +vio.completion_mode=VIRTIO_COMPLETION_POLLING +vio.notify_bar=0 +vio.notify_base=0
    +vio.notify_stride=4 +vio.notify_encoding=VIO_NOTIFY_DPU32 +rdma.enabled=1)
pf1_h0=(+dpu.h0.pf1.requester=1 +dpu.h0.pf1.intel_pf=1 +dpu.h0.pf1.intel_vf=-1
    +dpu.h0.pf1.vport=1)
two_host_pf_routes=("${pf1_h0[@]}"
    +dpu.h1.pf1.requester=3 +dpu.h1.pf1.intel_pf=1 +dpu.h1.pf1.intel_vf=-1
    +dpu.h1.pf1.vport=1)
multi_host_pf_vf_routes=(+dpu.h0.pf0.requester=0 +dpu.h0.pf0.intel_pf=0 +dpu.h0.pf0.intel_vf=-1
    +dpu.h0.pf0.vport=0 "${pf1_h0[@]}"
    +dpu.h0.pf0.vf0.requester=2 +dpu.h0.pf0.vf0.intel_pf=0 +dpu.h0.pf0.vf0.intel_vf=0
    +dpu.h0.pf0.vf0.vport=2 +dpu.h0.pf1.vf0.requester=3 +dpu.h0.pf1.vf0.intel_pf=1
    +dpu.h0.pf1.vf0.intel_vf=1 +dpu.h0.pf1.vf0.vport=3
    +dpu.h1.pf0.requester=4 +dpu.h1.pf0.intel_pf=0 +dpu.h1.pf0.intel_vf=-1
    +dpu.h1.pf0.vport=0 +dpu.h1.pf1.requester=5 +dpu.h1.pf1.intel_pf=1
    +dpu.h1.pf1.intel_vf=-1 +dpu.h1.pf1.vport=1
    +dpu.h1.pf0.vf0.requester=6 +dpu.h1.pf0.vf0.intel_pf=0 +dpu.h1.pf0.vf0.intel_vf=0
    +dpu.h1.pf0.vf0.vport=2 +dpu.h1.pf1.vf0.requester=7 +dpu.h1.pf1.vf0.intel_pf=1
    +dpu.h1.pf1.vf0.intel_vf=1 +dpu.h1.pf1.vf0.vport=3)
# 公共 RC DMA view fixture 不依赖 project env/Tcl；单独编译 top，验证 RDMA 直接 Host 地址、VIO IOVA、权限和 MSI-X sink。
if [[ ${RDMA_DMA_VIEWS_SMOKE_ONLY:-0} == 1 ]]; then
    run_direct_case dma_views DMA_VIEWS_PASS
    exit 0
fi
# 配置入口定向验证自动绑定、重载与两 PF Notify 写入；复用寄存器传输 fixture，无真实 DUT。
if [[ ${RDMA_CFG_SEQ_SMOKE_ONLY:-0} == 1 ]]; then
    run_case config_seq config_seq.tcl RDMA_CFG_SEQ_PASS required \
        +UVM_TESTNAME=project_cfg_seq_test +rdma.enabled=1 +vio.pairs=0 \
        +dpu.hosts=1 +dpu.pfs_per_host=2 +dpu.h0.pf1.requester=1 \
        +dpu.h0.pf1.intel_pf=1 +dpu.h0.pf1.intel_vf=-1 +dpu.h0.pf1.vport=1
    run_case rdma_disabled vio_only_commands.tcl RDMA_VIRTIO_VIO_ONLY_PASS required \
        "${common[@]:0:9}" +rdma.enabled=0 +dpu.hosts=1 +dpu.pfs_per_host=1
    exit 0
fi
# grant 定向验证只运行结构/参数场景；无 DUT，不把未收到 ACK 的流量伪装成通过。
if [[ ${RDMA_GRANT_SMOKE_ONLY:-0} == 1 ]]; then
    run_case rdma_only_two_pf grants.tcl RDMA_GRANTS_PASS required \
        +rdma.enabled=1 +vio.pairs=0 +dpu.hosts=1 +dpu.pfs_per_host=2 \
        +dpu.h0.pf1.requester=1 +dpu.h0.pf1.intel_pf=1 +dpu.h0.pf1.intel_vf=-1 \
        +dpu.h0.pf1.vport=1 +rdma.resource.qp_count=96 +grant_expect_qp=96
    run_case rdma_vio_two_host grants.tcl RDMA_GRANTS_PASS required "${common[@]}" \
        +dpu.hosts=2 +dpu.pfs_per_host=1 +dpu.msix.msg_addr_base=4276092928 \
        +dpu.msix.msg_data_base=0 +dpu.msix.msg_data_stride=1 +dpu.msix.table_only_enable=1
    run_case rdma_disabled vio_only_commands.tcl RDMA_VIRTIO_VIO_ONLY_PASS required \
        "${common[@]:0:9}" +rdma.enabled=0 +dpu.hosts=1 +dpu.pfs_per_host=1
    exit 0
fi
# TX-only 参数入口只验证组合环境能接收并拒绝/转发完整命令；空闲结构 top 没有真实 DUT，
# 因而不会把 rdma_init 或 ETH 发包误报为通过。
if [[ ${RDMA_TX_ONLY_SMOKE_ONLY:-0} == 1 ]]; then
    run_case tx_only_args tx_only_commands.tcl RDMA_VIRTIO_TX_ONLY_ARGS_PASS required \
        "${common[@]}" +dpu.hosts=1 +dpu.pfs_per_host=1
    exit 0
fi
run_case two_pf commands.tcl RDMA_VIRTIO_COMMANDS_PASS required "${common[@]}" \
    +dpu.hosts=1 +dpu.pfs_per_host=2 +rdma.traffic.count=10 "${pf1_h0[@]}"
run_case multi_host_pf_vf commands.tcl RDMA_VIRTIO_COMMANDS_PASS required "${common[@]}" \
    +dpu.hosts=2 +dpu.pfs_per_host=2 +dpu.vfs_per_pf=1 +rdma.traffic.count=10 \
    "${multi_host_pf_vf_routes[@]}"
run_case save save.tcl RDMA_VIRTIO_SAVE_PASS optional "${common[@]}" \
    +dpu.hosts=2 +dpu.pfs_per_host=2 +rdma.traffic.count=10 +vio.wait.poll_ns=10 \
    "${two_host_pf_routes[@]}"
run_case restore restore.tcl RDMA_VIRTIO_RESTORE_PASS required "${common[@]}" \
    +dpu.hosts=2 +dpu.pfs_per_host=2 +rdma.traffic.count=20 +vio.wait.poll_ns=33 \
    "${two_host_pf_routes[@]}"
run_case vio_only vio_only_commands.tcl RDMA_VIRTIO_VIO_ONLY_PASS required \
    +vio.pairs=1 +vio.queue_type=VQ_PACKED +vio.queue_size=256 +vio.rx_buf_size=2048 \
    +vio.completion_mode=VIRTIO_COMPLETION_POLLING +vio.notify_bar=0 +vio.notify_base=0 \
    +vio.notify_stride=4 +vio.notify_encoding=VIO_NOTIFY_DPU32 +rdma.enabled=0 \
    +dpu.hosts=2 +dpu.pfs_per_host=2 "${two_host_pf_routes[@]}"
