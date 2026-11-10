# 进程A：以count10启动，只保存未配置/未初始化状态；override不立刻改变cfg。
source [file join $::env(AIP_CORE) dist aip_init_so.tcl]
source [file join $::env(RDMA_ROOT) integration project tests rdma_project_common.tcl]
set ::aip_ckpt_dir [file join $::env(RDMA_RUN) snapshots]
set ::aip_simv_path [file join $::env(RDMA_RUN) simv]
run 10ns
set state [project_state]
project_pristine $state
project_eq $state count 10
project_cmd {set_param path=rdma.traffic.count value=17}
aip_checkpoint base "note=unconfigured model, count10 cfg and count17 saved override"
puts PROJECT_SAVE_PASS
quit
