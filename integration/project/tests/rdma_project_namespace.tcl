# 既有项目注册入口保持不变，导入runtime包不增加公共命令。
source [file join $::env(AIP_CORE) dist aip_init_so.tcl]
run 10ns
aip_send_cmd load_params
if {[aip_check_status] != 0 || [aip_read_result] ne "EXISTING_PROJECT_LOAD"} {
    error "PROJECT_FAIL existing load_params replaced"
}
aip_send_cmd namespace_probe
if {[aip_check_status] != 0 || [aip_read_result] ne "NAMESPACE_UNCHANGED"} { error "PROJECT_FAIL reusable package registered commands" }
puts PROJECT_NAMESPACE_PASS
quit
