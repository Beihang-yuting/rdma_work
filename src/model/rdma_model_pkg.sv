// 目录：模型层 model/rdma_model_pkg.sv。
// 职责：汇编并导出硬件镜像（CMQ 字段编解码用）与语义报文 rdma_packet，固定源码可见顺序。
// 依赖：导入 uvm_pkg 与 rdma_types_pkg，并包含 model 目录中的公开类型和对象定义。
// 所有权与生命周期：package 只建立编译期命名空间，不创建或持有运行期对象与外部资源。

package rdma_model_pkg;
  import uvm_pkg::*;
  import rdma_types_pkg::*;
  `include "uvm_macros.svh"

  `include "rdma_hw_image.sv"
  `include "rdma_semantic_requests.sv"
endpackage
