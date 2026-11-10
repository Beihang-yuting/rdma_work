# 真实Tcl/DPI命令矩阵：独立模型fixture，不证明外部DUT/grants。
source [file join $::env(AIP_CORE) dist aip_init_so.tcl]
source [file join $::env(RDMA_ROOT) integration project tests rdma_project_common.tcl]
run 10ns
project_pristine [project_state]
project_cmd rdma_init 1
project_cmd {rdma_run f0=1 f1=2} 1
project_cmd rdma_run 1
project_pristine [project_state]
# 参数事务：任一侧非法，两边都不得提交。
set initial [project_state]
project_cmd {set_param path=dpu.print_bar_map value=0}
project_cmd {set_param path=rdma.traffic.count value=0}
project_cmd load_params 1
set failed [project_state]
project_eq $failed print [dict get $initial print]
project_eq $failed count [dict get $initial count]
project_eq $failed loads 0
project_pristine $failed
project_cmd {set_param path=rdma.traffic.count value=12}
project_cmd {set_param path=dpu.configure_bdf value=0}
project_cmd load_params 1
set failed [project_state]
project_eq $failed print [dict get $initial print]
project_eq $failed count [dict get $initial count]
project_pristine $failed
project_cmd {clear_param path=dpu.configure_bdf}
project_cmd {set_param path=dpu.verify_readback value=1}
project_cmd {set_param path=rdma.traffic.op value=write}
project_cmd {set_param path=rdma.traffic.signaled_pct value=100}
set before [project_state]
project_cmd load_params
set after [project_state]
project_eq $after count 12
project_eq $after print 0
project_eq $after verify 1
project_eq $after dpu_reads [expr {[dict get $before dpu_reads]+1}]
project_eq $after rdma_reads [expr {[dict get $before rdma_reads]+1}]
project_pristine $after
project_cmd load_params
project_pristine [project_state]
project_cmd dut_config
set configured [project_state]
project_eq $configured configured 1
foreach key {ready probes cmq_mmio checked write_posts write_completions pending_writes sb_errors resources draws} { project_eq $configured $key 0 }
project_cmd rdma_init
project_cmd rdma_init 1
project_cmd {rdma_run f0=1} 1
project_cmd {rdma_run f0=1 f1=99} 1
project_cmd {rdma_run f0=1 f1=1} 1
project_cmd {rdma_run f0=4294967297 f1=2} 1
project_cmd {rdma_run f0=1 f1=2 wait=0}
set running [project_state]
project_eq $running busy 1
project_cmd load_params 1
# 给真实业务留出有界排空时间，再核对实际完成数，不以发起命令的count充当证据。
run 10ms
set done [project_state]
project_eq $done busy 0
project_eq $done write_posts 12
project_eq $done write_completions 12
project_eq $done pending_writes 0
project_eq $done sb_errors 0
project_eq $done sb_idle 1
project_eq $done identity 1
project_eq $done registry_stable 1
project_cmd load_params 1
puts PROJECT_COMMANDS_PASS
project_finish
