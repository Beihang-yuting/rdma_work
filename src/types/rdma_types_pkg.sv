// 目录：公共类型层 types/rdma_types_pkg.sv。
// 职责：实现 rdma_types_pkg 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_types_pkg.sv 属于基础类型层，集中定义 RDMA 枚举、地址、身份和状态契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

package rdma_types_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  `include "rdma_enum_types.sv"
  `include "rdma_address_types.sv"
  `include "rdma_identity_types.sv"
  `include "rdma_status.sv"
endpackage
