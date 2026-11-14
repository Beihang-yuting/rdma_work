# 同 binary 的进程 A：保存未配置、未初始化的真实组合环境。
source [file join $::env(AIP_CORE) dist aip_init_so.tcl]
source [file join $::env(RDMA_ROOT) integration virtio tests rdma_project_common.tcl]
set ::aip_ckpt_dir [file join $::env(RDMA_VIRTIO_RUN) snapshots]
set ::aip_simv_path [file join $::env(RDMA_VIRTIO_RUN) simv]
run 100ns
set initial [project_cmd compose_observe]
project_eq $initial count 10
project_eq $initial poll 10
project_cmd {set_param path=rdma.traffic.count value=17}
project_cmd {set_param path=vio.wait.poll_ns value=27}
aip_checkpoint combined "note=combined VIO RDMA before explicit configuration"
puts RDMA_VIRTIO_SAVE_PASS
quit
