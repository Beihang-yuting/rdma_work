# 目录/层次：integration/virtio/tests；RDMA TX-only Tcl 参数入口回归。
# 职责：验证 tx_only、目的 QPN/DMAC、qps 和 group 互斥参数能进入唯一 rdma_run 命令，
#   并在环境未初始化时保持零资源副作用。
# 依赖：rdma_virtio_top 结构 fixture、rdma_aip_pkg 和 rdma_project_common.tcl；不提供真实 DUT、ETH monitor 或 grant。
# 所有权/生命周期：脚本只借用组合环境和 AIP 命令；每个负例完成后继续检查同一配置快照，最后由 project_finish 收尾。
source [file join $::env(AIP_CORE) dist aip_init_so.tcl]
source [file join $::env(RDMA_ROOT) integration virtio tests rdma_project_common.tcl]
run 100ns

set initial [project_cmd compose_observe]
project_cmd {rdma_run tx_only=1 f0=0} 1
project_cmd {rdma_run tx_only=1 f0=0 dest_qpn=0x12345 dmac=0x001122334455 qps=2} 1
project_cmd {rdma_run tx_only=1 f0=0 dest_qpn=0x12345 dmac=0x001122334455 qps=2 group=0} 1
project_cmd {rdma_run tx_only=1 f0=0 dest_qpn=0x0 dmac=0x001122334455 qps=1} 1
project_cmd {rdma_run tx_only=1 f0=0 dest_qpn=0x12345 dmac=0x0 qps=1} 1
set after [project_cmd compose_observe]
foreach key {count print poll hosts functions irq_local irq_data} {
    project_eq $after $key [dict get $initial $key]
}

puts RDMA_VIRTIO_TX_ONLY_ARGS_PASS
project_finish
