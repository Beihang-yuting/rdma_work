// 目录/层次：integration/filelists；RDMA+virtio 组合项目的完整类型入口。
// 职责：从仓库根展开 @*_ROOT@，先编译 virtio_work 的公共 project_env 依赖，再编译本项目
//       RDMA 组合示例；具体平台 test/top 由调用方提供。
// 所有权/生命周期：filelist 只定义编译依赖；运行期 env、snapshot、pool 和 Tcl 入口由 integration test 拥有。
// 组合约束：VIRTIO_WORK_ROOT 必须指向与本项目约定版本一致的 virtio_work checkout；本项目不修改外部源码。
+define+UVM
+define+RDMA_NETPKT_USE_NET_PACKET_PKG
+incdir+@AIP_CORE_ROOT@
+incdir+@AIP_CORE_ROOT@/src/sv
+incdir+@AIP_CORE_ROOT@/src/sv/core
+incdir+@AIP_CORE_ROOT@/src/sv/bridge
+incdir+@AIP_CORE_ROOT@/src/sv/util
+incdir+@AIP_CORE_ROOT@/src/sv/plugin
+incdir+@AIP_CORE_ROOT@/src/sv/cpu_mem
+incdir+@DPU_COMMON_ROOT@/src
+incdir+src/types
+incdir+src/model
+incdir+src/codec
+incdir+src/dev
+incdir+src/drv
+incdir+src/tb
+incdir+@HOST_MEM_ROOT@/src
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
+incdir+@PCIE_WORK_ROOT@/pcie_tl_vip/src
+incdir+@PCIE_WORK_ROOT@/pcie_tl_vip/src/types
+incdir+@PCIE_WORK_ROOT@/pcie_tl_vip/src/shared
+incdir+@PCIE_WORK_ROOT@/pcie_tl_vip/src/agent
+incdir+@PCIE_WORK_ROOT@/pcie_tl_vip/src/env
+incdir+@PCIE_WORK_ROOT@/pcie_tl_vip/src/adapter
+incdir+@PCIE_WORK_ROOT@/pcie_tl_vip/src/topology
+incdir+@PCIE_WORK_ROOT@/pcie_tl_vip/src/switch
+incdir+@PCIE_WORK_ROOT@/pcie_tl_vip/src/seq/base
+incdir+@PCIE_WORK_ROOT@/pcie_tl_vip/src/seq/constraints
+incdir+@PCIE_WORK_ROOT@/pcie_tl_vip/src/seq/scenario
+incdir+@PCIE_WORK_ROOT@/pcie_tl_vip/src/seq/virtual
+incdir+@DPU_COMMON_ROOT@/integration/pcie
+incdir+integration/project
+incdir+integration/virtio
+incdir+@PCIE_INTEL_ROOT@/src

// virtio_work reference project dependencies, kept in the same order as its
// filelists/project_integration.f. The final package uses this repository's project_env_cfg overlay and includes the external env implementation unchanged.
+incdir+@VIRTIO_WORK_ROOT@/virtio_net_vip/src
+incdir+@VIRTIO_WORK_ROOT@/virtio_net_vip/src/agent
+incdir+@VIRTIO_WORK_ROOT@/virtio_net_vip/src/shared
+incdir+@VIRTIO_WORK_ROOT@/virtio_net_vip/src/types
+incdir+@VIRTIO_WORK_ROOT@/virtio_net_vip/src/iommu
+incdir+@VIRTIO_WORK_ROOT@/virtio_net_vip/src/virtqueue
+incdir+@VIRTIO_WORK_ROOT@/virtio_net_vip/src/sriov
+incdir+@VIRTIO_WORK_ROOT@/virtio_net_vip/src/transport
+incdir+@VIRTIO_WORK_ROOT@/virtio_net_vip/src/pcie
+incdir+@VIRTIO_WORK_ROOT@/virtio_net_vip/src/devmodel
+incdir+@VIRTIO_WORK_ROOT@/virtio_net_vip/src/dataplane
+incdir+@VIRTIO_WORK_ROOT@/virtio_net_vip/src/dpu_priv
+incdir+@VIRTIO_WORK_ROOT@/integration/aip
+incdir+@VIRTIO_WORK_ROOT@/integration/dpu
+incdir+@VIRTIO_WORK_ROOT@/integration/project

@AIP_CORE_ROOT@/aip_core_pkg.sv
@HOST_MEM_ROOT@/src/host_mem_pkg.sv
@DPU_COMMON_ROOT@/src/dpu_resource_pkg.sv
@NET_PACKET_ROOT@/src/net_packet_pkg.sv
@PCIE_WORK_ROOT@/pcie_tl_vip/src/pcie_tl_if.sv
@PCIE_WORK_ROOT@/pcie_tl_vip/src/shared/pcie_tl_bdf_utils_pkg.sv
@PCIE_WORK_ROOT@/pcie_tl_vip/src/shared/pcie_tl_device_profile_pkg.sv
@PCIE_WORK_ROOT@/pcie_tl_vip/src/topology/pcie_topology_pkg.sv
@PCIE_WORK_ROOT@/pcie_tl_vip/src/pcie_tl_pkg.sv
@DPU_COMMON_ROOT@/integration/pcie/dpu_pcie_pkg.sv
@PCIE_INTEL_ROOT@/src/interface/intel_pcie_if.sv
@PCIE_INTEL_ROOT@/src/adapter/intel_pcie_adapter_pkg.sv

@VIRTIO_WORK_ROOT@/virtio_net_vip/src/agent/virtio_protocol_event_if.sv
@VIRTIO_WORK_ROOT@/virtio_net_vip/src/virtio_net_pkg.sv
@VIRTIO_WORK_ROOT@/integration/aip/virtio_aip_pkg.sv
@VIRTIO_WORK_ROOT@/integration/dpu/virtio_dpu_pkg.sv
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
src/adapters/pcie/rdma_pcie_pkg.sv
integration/project/rdma_project_pkg.sv
integration/project/rdma_aip_pkg.sv
integration/virtio/rdma_project_env_pkg.sv
integration/virtio/rdma_virtio_pkg.sv
