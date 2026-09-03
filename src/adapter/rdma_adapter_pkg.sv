// 中文说明：rdma_adapter_pkg.sv 属于适配器接口层，定义主机内存、PCIe、网络及上下文后端接口。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

package rdma_adapter_pkg;
  import uvm_pkg::*;
  import rdma_types_pkg::*;
  import rdma_model_pkg::*;
  import rdma_codec_pkg::*;
  `include "uvm_macros.svh"

  `include "rdma_host_mem_api.sv"
  `include "rdma_xtr_v1_queue_host_mem_submitter.sv"
  `include "rdma_context_backing_api.sv"
  `include "rdma_pcie_api.sv"
  `include "rdma_function_table_api.sv"
  `include "rdma_net_api.sv"
endpackage
