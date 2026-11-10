# 独立恢复进程省略count；清除快照override后必须采用新默认32而非旧CLI10。
source [file join $::env(AIP_CORE) dist aip_init_so.tcl]
set ::aip_ckpt_dir [file join $::env(RDMA_RUN) snapshots]
set ::aip_simv_path [file join $::env(RDMA_RUN) simv]
run 10ns
aip_restore base
source [file join $::env(AIP_CORE) dist aip_init_so.tcl]
source [file join $::env(RDMA_ROOT) integration project tests rdma_project_common.tcl]
project_eq [project_state] count 10
project_cmd {clear_param path=rdma.traffic.count}
project_cmd load_params
set state [project_state]
project_eq $state count 32
project_pristine $state
puts PROJECT_RESTORE_ABSENT_PASS
project_finish
