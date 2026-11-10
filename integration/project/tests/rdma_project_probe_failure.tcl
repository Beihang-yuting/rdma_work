# 第二Function实际probe写失败；第一Function已有MMIO，失败不得发布ready/资源或允许重载。
source [file join $::env(AIP_CORE) dist aip_init_so.tcl]
source [file join $::env(RDMA_ROOT) integration project tests rdma_project_common.tcl]
run 10ns
project_cmd dut_config
project_cmd {project_inject mode=probe}
project_cmd rdma_init 1
set failed [project_state]
project_eq $failed ready 0
project_eq $failed resources 0
project_eq $failed checked 0
if {[dict get $failed cmq_mmio] == 0} { error "PROJECT_FAIL first probe never issued MMIO" }
project_cmd load_params 1
project_cmd rdma_init 1
project_cmd {rdma_run f0=1 f1=2} 1
project_eq [project_state] cmq_mmio [dict get $failed cmq_mmio]
puts PROJECT_PROBE_FAILURE_PASS
project_finish
