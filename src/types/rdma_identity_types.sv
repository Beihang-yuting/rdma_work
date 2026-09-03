// 中文说明：rdma_identity_types.sv 属于基础类型层，集中定义 RDMA 枚举、地址、身份和状态契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

typedef struct packed {
  bit [15:0] segment;
  bit [7:0] bus;
  bit [4:0] device;
  bit [2:0] function_num;
} rdma_bdf_t;

function automatic bit [15:0] rdma_bdf_requester_id(rdma_bdf_t bdf);
  return {bdf.bus, bdf.device, bdf.function_num};
endfunction

typedef struct packed {
  bit [15:0] root_id;
  bit [31:0] host_topology_key;
  rdma_function_kind_e function_kind;
  rdma_bdf_t parent_pf_bdf;
  bit [15:0] vf_index;
  rdma_bdf_t bdf;
} rdma_function_key_t;
