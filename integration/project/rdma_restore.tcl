# 进程B：必须使用同一binary；恢复在顶层，下一行立即重新source匹配loader。
source [file join $::env(AIP_CORE) dist aip_init_so.tcl]
set ::aip_ckpt_dir [file join $::env(RDMA_RUN) snapshots]
set ::aip_simv_path [file join $::env(RDMA_RUN) simv]
run 10ns
aip_restore base
source [file join $::env(AIP_CORE) dist aip_init_so.tcl]
source [file join $::env(RDMA_ROOT) integration project tests rdma_project_common.tcl]
set before [project_state]
project_pristine $before
project_eq $before count 10
# 快照override优先于新进程count20。
project_cmd load_params
set held [project_state]
project_pristine $held
project_eq $held count 17
project_cmd {clear_param path=rdma.traffic.count}
project_cmd load_params
set changed [project_state]
project_pristine $changed
project_eq $changed count 20
project_eq $changed dpu_reads 2
project_eq $changed rdma_reads 2
project_cmd load_params
project_pristine [project_state]
# 语义非法候选不部分提交，保持新进程20及原DPU值。
project_cmd {set_param path=rdma.traffic.count value=0}
project_cmd {set_param path=dpu.print_bar_map value=0}
project_cmd load_params 1
set rejected [project_state]
project_pristine $rejected
project_eq $rejected count 20
project_eq $rejected print [dict get $changed print]
project_cmd {clear_param path=rdma.traffic.count}
project_cmd {clear_param path=dpu.print_bar_map}
project_cmd dut_config
set configured [project_state]
foreach key {ready probes cmq_mmio checked write_posts write_completions pending_writes sb_errors resources draws} { project_eq $configured $key 0 }
project_cmd rdma_init
project_cmd {rdma_run f0=1 f1=2}
set done [project_state]
project_eq $done write_posts 20
project_eq $done write_completions 20
project_eq $done pending_writes 0
project_eq $done sb_errors 0
project_eq $done sb_idle 1
project_eq $done identity 1
project_eq $done registry_stable 1
project_cmd load_params 1
puts PROJECT_RESTORE_PASS
project_finish
