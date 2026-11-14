# 目录：integration/virtio/tests；自动 grant 的基础构建/重载验证，不提供真实 DUT。
# 依赖：实际 AIP 桥与组合 smoke test；测试对象检查多 Function SD/CEQ/vector 不重叠。
# 生命周期：只观察 build/connect 后的配置；拒绝反序初始化，再显式结束，不发配置或流量。
source [file join $::env(AIP_CORE) dist aip_init_so.tcl]
source [file join $::env(RDMA_ROOT) integration virtio tests rdma_project_common.tcl]
run 100ns
set initial [project_cmd compose_observe]
project_cmd rdma_init 1
if {[dict get $initial irq_local] >= 0} {
    project_cmd {set_param path=dpu.msix.msg_data_base value=1000}
}
project_cmd load_params
set repeated [project_cmd compose_observe]
foreach key {count hosts functions} {
    project_eq $repeated $key [dict get $initial $key]
}
if {[dict get $initial irq_local] >= 0} {
    project_eq $repeated irq_local [dict get $initial irq_local]
    project_eq $repeated irq_data [expr {1000 + [dict get $initial irq_local]}]
}
puts RDMA_GRANTS_PASS
project_finish
