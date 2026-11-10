# 显式启动示例；先source与simv匹配的dist/aip_init_so.tcl，再source本文件。
# Function参数是DPU global ID，示例模型具有VF IDs1/2；真实平台必须替换成实际peer。
set_param path=rdma.traffic.op value=write
if {[aip_check_status] != 0} { error [aip_read_result] }
set_param path=rdma.traffic.count value=100
if {[aip_check_status] != 0} { error [aip_read_result] }
foreach command {load_params dut_config rdma_init {rdma_run f0=1 f1=2}} {
    aip_send_cmd $command
    if {[aip_check_status] != 0} { error [aip_read_result] }
}
end_test drain=100ns
if {[aip_check_status] != 0} { error [aip_read_result] }
run
