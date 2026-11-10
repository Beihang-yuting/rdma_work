# prepare正常返回失败必须非零且没有配置/初始化副作用。
source [file join $::env(AIP_CORE) dist aip_init_so.tcl]
source [file join $::env(RDMA_ROOT) integration project tests rdma_project_common.tcl]
run 10ns
project_cmd {project_inject mode=prepare}
project_cmd dut_config 1
project_pristine [project_state]
project_cmd rdma_init 1
puts PROJECT_PREPARE_FAILURE_PASS
project_finish
