# VIO-only 组合回归：RDMA 未开启时只加载/保留 VIO 参数，不创建 RDMA 子环境或 RDMA 表项。
source [file join $::env(AIP_CORE) dist aip_init_so.tcl]
source [file join $::env(RDMA_ROOT) integration virtio tests rdma_project_common.tcl]
run 100ns
set initial [project_cmd compose_observe]
project_eq $initial count 0
project_eq $initial functions 0
project_cmd rdma_init 1
project_cmd {rdma_run f0=0 f1=1} 1
project_cmd load_params
set reloaded [project_cmd compose_observe]
project_eq $reloaded count 0
project_eq $reloaded functions 0
puts RDMA_VIRTIO_VIO_ONLY_PASS
project_finish
