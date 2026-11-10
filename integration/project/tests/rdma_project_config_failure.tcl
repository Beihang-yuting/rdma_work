# 独立负向进程：配置写失败必须保留PROJECT_CONFIG_SEQ fatal；不捕获使其变正常返回。
source [file join $::env(AIP_CORE) dist aip_init_so.tcl]
source [file join $::env(RDMA_ROOT) integration project tests rdma_project_common.tcl]
run 10ns
project_cmd {project_inject mode=config}
aip_send_cmd dut_config
error "PROJECT_FAIL expected inherited configuration fatal did not terminate"
