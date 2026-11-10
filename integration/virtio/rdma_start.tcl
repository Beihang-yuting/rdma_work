# 目录：integration/virtio；用户显式 source 的 RDMA 启动示例。
# 依赖：已加载与 simv 匹配的 AIP；平台提供真实 DUT、硬件绑定和 RDMA grant。
# 生命周期：先设置 ::rdma_f0/::rdma_f1 为实际 global ID；失败停止，不自动重试或重置。
if {![info exists ::rdma_f0] || ![info exists ::rdma_f1]} {
    error "Set ::rdma_f0 and ::rdma_f1 to two actual dpu_common global Function IDs before sourcing"
}
foreach command [list load_params dut_config rdma_init "rdma_run f0=$::rdma_f0 f1=$::rdma_f1"] {
    aip_send_cmd $command
    if {[aip_check_status] != 0} {
        error "$command failed: [aip_read_result]"
    }
}
