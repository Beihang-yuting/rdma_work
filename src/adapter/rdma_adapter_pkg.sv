// 目录：适配器接口层 adapter/rdma_adapter_pkg.sv。
// 职责：实现 rdma_adapter_pkg 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_adapter_pkg.sv 属于适配器接口层，定义主机内存、PCIe、网络及上下文后端接口。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

package rdma_adapter_pkg;
  import uvm_pkg::*;
  import rdma_types_pkg::*;
  import rdma_model_pkg::*;
  import rdma_codec_pkg::*;
  `include "uvm_macros.svh"

  `include "rdma_host_mem_api.sv"
  `include "rdma_queue_host_mem_submitter.sv"
  `include "rdma_context_backing_api.sv"
  `include "rdma_pcie_api.sv"
  `include "rdma_function_table_api.sv"
  `include "rdma_net_api.sv"
endpackage
