# 进程 B：恢复后重新 source AIP，单次 load_params 加载两业务与公共 DPU 参数。
source [file join $::env(AIP_CORE) dist aip_init_so.tcl]
set ::aip_ckpt_dir [file join $::env(RDMA_VIRTIO_RUN) snapshots]
set ::aip_simv_path [file join $::env(RDMA_VIRTIO_RUN) simv]
run 100ns
aip_restore combined
source [file join $::env(AIP_CORE) dist aip_init_so.tcl]
source [file join $::env(RDMA_ROOT) integration virtio tests rdma_project_common.tcl]
set before [project_cmd compose_observe]
project_eq $before count 10
project_eq $before poll 10
project_cmd load_params
set held [project_cmd compose_observe]
project_eq $held count 17
project_eq $held poll 27
project_cmd {clear_param path=rdma.traffic.count}
project_cmd {clear_param path=vio.wait.poll_ns}
project_cmd load_params
set updated [project_cmd compose_observe]
project_eq $updated count 20
project_eq $updated poll 33
puts RDMA_VIRTIO_RESTORE_PASS
project_finish
