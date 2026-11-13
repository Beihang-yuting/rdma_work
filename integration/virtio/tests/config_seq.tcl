# 目录/层次：integration/virtio/tests；直接 AIP sequence 注册的配置获取回归。
# 依赖：project_cfg_seq_test 与寄存器传输 fixture；执行生产配置流程，不执行 DUT 初始化或网络流量。
# 生命周期：重载后两次创建全新 sequence，验证配置门禁，再检查异源拒绝并结束仿真。
source [file join $::env(AIP_CORE) dist aip_init_so.tcl]
source [file join $::env(RDMA_ROOT) integration project tests rdma_project_common.tcl]
run 100ns
set initial [project_cmd cfg_seq_observe]
project_eq $initial calls 0
project_eq $initial configured 0
project_eq $initial initializable 0
project_cmd load_params
project_cmd {cfg_seq_direct wait=1}
set first [project_cmd cfg_seq_observe]
project_eq $first configured 1
project_eq $first initializable 1
project_eq $first busy 0
project_eq $first calls 1
project_cmd {set_param path=rdma.traffic.count value=23}
project_cmd load_params
set reloaded [project_cmd cfg_seq_observe]
project_eq $reloaded count 23
project_eq $reloaded configured 0
project_eq $reloaded initializable 0
project_cmd {cfg_seq_direct wait=1}
set second [project_cmd cfg_seq_observe]
project_eq $second configured 1
project_eq $second initializable 1
project_eq $second busy 0
project_eq $second calls 2
project_cmd cfg_seq_reject
project_eq [project_cmd cfg_seq_observe] initializable 1
puts RDMA_CFG_SEQ_PASS
project_finish
