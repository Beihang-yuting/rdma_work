// 目录/层次：integration/project；可选 RDMA 项目配置入口，须在 DPU/PCIe 公共包之后编译。
// 职责：导出独立配置 sequence，不导入 VIO 包、不注册 AIP 命令、不创建环境或设备。
// 依赖与所有权：所有快照、map、RC 和资源均由平台拥有，本包只定义借用这些对象的类型。
// 生命周期：包只提供编译期类型；运行期句柄由平台先发布并保持存活至配置结束。
package rdma_project_pkg;
  timeunit 1ns;
  timeprecision 1ps;
  import uvm_pkg::*;
  import dpu_resource_pkg::*;
  import dpu_pcie_pkg::*;
  import pcie_tl_pkg::*;
  `include "uvm_macros.svh"
  `include "rdma_project_cfg_seq.sv"
endpackage
