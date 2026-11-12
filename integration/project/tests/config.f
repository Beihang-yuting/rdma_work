// 从仓库根目录调用，替换 @DPU_COMMON_ROOT@/@HOST_MEM_ROOT@/@PCIE_WORK_ROOT@。
// 独立表/传输契约入口：不引入 RDMA model/driver、VIO包、Intel包或旧sim/filelists。
+incdir+@DPU_COMMON_ROOT@/src
@DPU_COMMON_ROOT@/src/dpu_resource_pkg.sv
+incdir+@HOST_MEM_ROOT@/src
@HOST_MEM_ROOT@/src/host_mem_pkg.sv
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
@PCIE_WORK_ROOT@/pcie_tl_vip/src/pcie_tl_if.sv
@PCIE_WORK_ROOT@/pcie_tl_vip/src/shared/pcie_tl_bdf_utils_pkg.sv
@PCIE_WORK_ROOT@/pcie_tl_vip/src/shared/pcie_tl_device_profile_pkg.sv
@PCIE_WORK_ROOT@/pcie_tl_vip/src/topology/pcie_topology_pkg.sv
@PCIE_WORK_ROOT@/pcie_tl_vip/src/pcie_tl_pkg.sv

+incdir+@DPU_COMMON_ROOT@/integration/pcie
@DPU_COMMON_ROOT@/integration/pcie/dpu_pcie_pkg.sv
+incdir+integration/project
integration/project/rdma_project_pkg.sv
integration/project/tests/rdma_project_config_test.sv
integration/project/tests/rdma_project_config_top.sv
