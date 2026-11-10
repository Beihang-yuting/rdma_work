# 独立负向运行：原始AIP duplicate错误必须存在，不能混入正向0/0/0结果。
source [file join $::env(AIP_CORE) dist aip_init_so.tcl]
source [file join $::env(RDMA_ROOT) integration project tests rdma_project_common.tcl]
run 10ns
set result [project_cmd project_duplicate]
if {$result ne "DUPLICATE_ORIGINAL_PRESERVED"} { error "PROJECT_FAIL duplicate replaced registry" }
puts PROJECT_DUPLICATE_PRESERVED
project_finish
