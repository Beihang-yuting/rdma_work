// 目录/层次：integration/project；显式项目组装与运行期事务层。
// 职责：组合已有配置并原子提交受支持候选；配置、初始化和业务启动由独立 Tcl 命令创建的 sequence 负责。
// 依赖：AIP loader、RDMA env、DPU/PCIe与独立配置sequence；不注册命令。
// 所有权：平台拥有DPU/PCIe及外部硬件；项目拥有RDMA子组件，借用发布配置。
// 生命周期：build绑定，平台prepare后由命令启动配置 sequence；初始化尝试后禁止重载，取消不自动恢复。
package rdma_project_runtime_pkg;
  timeunit 1ns;
  timeprecision 1ps;
  import uvm_pkg::*;
  import aip_core_pkg::*;
  import dpu_resource_pkg::*;
  import dpu_pcie_pkg::*;
  import pcie_tl_pkg::*;
  import rdma_types_pkg::*;
  import rdma_env_pkg::*;
  import rdma_aip_cfg_pkg::*;
  import rdma_dpu_adapter_pkg::*;
  import rdma_project_pkg::*;
  `include "uvm_macros.svh"
  `include "rdma_project_env_cfg.sv"
  `include "rdma_project_env.sv"
endpackage
