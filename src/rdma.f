// 目录：基础环境编译入口 src/rdma.f。
// 文件职责：按依赖顺序编译 RDMA 基础环境及其公共适配器，最后编译
//   src/rdma_pkg.sv 统一入口。
// 主要依赖：AIP core、dpu_common、host_mem 和 net_packet；调用方先将 @*_ROOT@ 替换为
//   实际路径。
// 所有权与生命周期：filelist 只描述编译输入，不创建运行期对象，也不启动 sequence、Tcl 命令、
//   test 或 top。
// 集成边界：不包含 integration/ 下的 project_env、Intel wrapper、运行时 sequence、Tcl、test/top；
//   RXE/DPI 另行编译。
// 使用约定：从仓库根目录调用 VCS，例如 vcs ... -f src/rdma.f；项目 filelist 可在本清单后追加自己的
//   top/test。

+define+UVM
+define+RDMA_NETPKT_USE_NET_PACKET_PKG

// 统一编译时间单位，调用方无需再补该选项。
-timescale=1ns/1ps

// AIP 必须先于 dpu_common、net_packet 和 RDMA 参数适配器编译。
+incdir+@AIP_CORE_ROOT@
+incdir+@AIP_CORE_ROOT@/src/sv
+incdir+@AIP_CORE_ROOT@/src/sv/core
+incdir+@AIP_CORE_ROOT@/src/sv/bridge
+incdir+@AIP_CORE_ROOT@/src/sv/util
+incdir+@AIP_CORE_ROOT@/src/sv/plugin
+incdir+@AIP_CORE_ROOT@/src/sv/cpu_mem
@AIP_CORE_ROOT@/aip_core_pkg.sv

// dpu_common 提供 Host/PF/VF、BDF、BAR、global Function ID 和 topology 的唯一来源。
+incdir+@DPU_COMMON_ROOT@/src
@DPU_COMMON_ROOT@/src/dpu_resource_pkg.sv

// host_mem 是 RDMA 驱动、设备 DMA 和 PCIe RC 共享的外部内存类型来源。
+incdir+@HOST_MEM_ROOT@/src
@HOST_MEM_ROOT@/src/host_mem_pkg.sv

// 组合环境复用 net_packet_pkg，避免 rdma_netpkt_pkg 在另一个 package 中复制 packet 类型。
+incdir+@NET_PACKET_ROOT@/src
+incdir+@NET_PACKET_ROOT@/src/core
+incdir+@NET_PACKET_ROOT@/src/common
+incdir+@NET_PACKET_ROOT@/src/protocols
+incdir+@NET_PACKET_ROOT@/src/protocols/l2
+incdir+@NET_PACKET_ROOT@/src/protocols/l3
+incdir+@NET_PACKET_ROOT@/src/protocols/l4
+incdir+@NET_PACKET_ROOT@/src/protocols/tunnel
+incdir+@NET_PACKET_ROOT@/src/protocols/rdma
+incdir+@NET_PACKET_ROOT@/src/protocols/storage
+incdir+@NET_PACKET_ROOT@/src/protocols/app
+incdir+@NET_PACKET_ROOT@/src/parser
+incdir+@NET_PACKET_ROOT@/src/sequence
+incdir+@NET_PACKET_ROOT@/src/stream
+incdir+@NET_PACKET_ROOT@/src/uvm_wrapper
@NET_PACKET_ROOT@/src/net_packet_pkg.sv

// RDMA 基础 package 必须按依赖由底向上编译。
+incdir+src/types
+incdir+src/model
+incdir+src/codec
+incdir+src/dev
+incdir+src/drv
+incdir+src/tb
+incdir+src/adapters/host_mem
+incdir+src/adapters/dpu
+incdir+src/adapters/net_packet
+incdir+src/adapters/aip
src/types/rdma_types_pkg.sv
src/model/rdma_model_pkg.sv
src/codec/rdma_codec_pkg.sv
src/adapters/host_mem/rdma_host_mem_pkg.sv
src/dev/rdma_dev_pkg.sv
src/drv/rdma_drv_pkg.sv
src/adapters/dpu/rdma_dpu_adapter_pkg.sv
src/adapters/net_packet/rdma_netpkt_pkg.sv
src/tb/rdma_env_pkg.sv
src/adapters/aip/rdma_aip_cfg_pkg.sv

// facade 必须最后编译，确保所有被 export 的 package 已经存在。
src/rdma_pkg.sv
