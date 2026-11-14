# 目录/层次：integration/virtio；平台用户 source 的 RDMA 启动入口。
# 职责：把参数加载、DUT 配置、RDMA 初始化和一次业务启动串成显式 Tcl 步骤；默认启动 TX-only 首发，
#   不在环境 phase 中隐式创建 sequence，也不引入 RX/环回/ACK 等额外流程。
# 依赖：已加载与 simv 匹配的 AIP loader；平台提供真实 DUT、PCIe/ETH ready、硬件绑定和 RDMA grant。
# 所有权/生命周期：脚本只借用 AIP 命令和项目对象；失败立即停止，不重试、不复位、不释放平台资源。
#
# TX-only 用法（RC 首轮每 QP 一条 SEND，数量默认等于 qps）：
#   set ::rdma_f0 0
#   set ::rdma_qps 2
#   set ::rdma_dest_qpn 0x12345
#   set ::rdma_dmac 0x001122334455
#   source /path/to/integration/virtio/rdma_start.tcl
#
# 设置 ::rdma_tx_only 0 后可保留双端模型/环回入口，此时还必须提供 ::rdma_f1。
if {![info exists ::rdma_f0]} {
    error "Set ::rdma_f0 to the sender's actual dpu_common global Function ID before sourcing"
}
if {![info exists ::rdma_tx_only]} {
    set ::rdma_tx_only 1
}
if {![info exists ::rdma_qps]} {
    set ::rdma_qps 1
}
if {$::rdma_qps < 1} {
    error "::rdma_qps must be a positive integer"
}

set commands [list]
if {$::rdma_tx_only} {
    if {![info exists ::rdma_dest_qpn] || ![info exists ::rdma_dmac]} {
        error "TX-only requires ::rdma_dest_qpn and ::rdma_dmac"
    }
    if {$::rdma_dest_qpn == 0 || $::rdma_dmac == 0} {
        error "TX-only destination QPN and DMAC must be nonzero"
    }
    if {![info exists ::rdma_tx_count]} {
        set ::rdma_tx_count $::rdma_qps
    }
    if {$::rdma_tx_count < 1 || $::rdma_tx_count > $::rdma_qps} {
        error "::rdma_tx_count must be positive and no greater than ::rdma_qps for TX-only"
    }
    aip_send_cmd "set_param path=rdma.traffic.count value=$::rdma_tx_count"
    if {[aip_check_status] != 0} {
        error "set_param rdma.traffic.count failed: [aip_read_result]"
    }
    lappend commands load_params dut_config rdma_init
    set run_command "rdma_run tx_only=1 f0=$::rdma_f0 qps=$::rdma_qps dest_qpn=$::rdma_dest_qpn dmac=$::rdma_dmac"
    if {[info exists ::rdma_dest_qkey]} {
        append run_command " dest_qkey=$::rdma_dest_qkey"
    }
    lappend commands $run_command
} else {
    if {![info exists ::rdma_f1]} {
        error "Set ::rdma_f1 to the peer's actual dpu_common global Function ID"
    }
    lappend commands load_params dut_config rdma_init
    lappend commands "rdma_run f0=$::rdma_f0 f1=$::rdma_f1 qps=$::rdma_qps"
}

foreach command $commands {
    aip_send_cmd $command
    if {[aip_check_status] != 0} {
        error "$command failed: [aip_read_result]"
    }
}
