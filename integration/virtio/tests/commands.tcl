# 真实组合 build/connect 和 Tcl 事务；fixture 不提供 DUT 或 RDMA grant。
source [file join $::env(AIP_CORE) dist aip_init_so.tcl]
source [file join $::env(RDMA_ROOT) integration virtio tests rdma_project_common.tcl]
run 100ns
set initial [project_cmd compose_observe]
project_eq $initial count 10
project_eq $initial poll 10
project_cmd rdma_init 1
project_cmd {rdma_run f0=0 f1=1} 1
project_cmd {load_params unexpected=1} 1
project_cmd {set_param path=dpu.print_bar_map value=0}
project_cmd {set_param path=vio.wait.poll_ns value=27}
project_cmd {set_param path=rdma.traffic.count value=0}
project_cmd load_params 1
set failed [project_cmd compose_observe]
foreach key {count print poll} { project_eq $failed $key [dict get $initial $key] }
# RDMA 有效但 VIO 固定几何非法，也不能先提交 RDMA/DPU。
project_cmd {set_param path=rdma.traffic.count value=12}
project_cmd {set_param path=vio.pairs value=2}
project_cmd load_params 1
set failed [project_cmd compose_observe]
foreach key {count print poll} { project_eq $failed $key [dict get $initial $key] }
project_cmd {clear_param path=vio.pairs}
project_cmd load_params
set changed [project_cmd compose_observe]
project_eq $changed count 12
project_eq $changed print 0
project_eq $changed poll 27
# 父类释放入口仍有效；空队列释放不改变其他业务或命令注册。
project_cmd vio_release
project_cmd {load_params wait=0}
run 100ns
set repeated [project_cmd compose_observe]
foreach key {count print poll} { project_eq $repeated $key [dict get $changed $key] }
puts RDMA_VIRTIO_COMMANDS_PASS
project_finish
