// 目录：公共类型层 types/rdma_address_types.sv。
// 职责：定义 RDMA 地址与访问权限的基础 packed 类型。
// 依赖：无。
// 所有权与生命周期：纯值类型，不持有资源，生命周期随使用者。

typedef struct packed {
  bit [63:0] value;
} rdma_backing_addr_t;

typedef struct packed {
  bit [63:0] value;
} rdma_iova_t;

typedef struct packed {
  bit [63:0] value;
} rdma_hmc_fvm_addr_t;

typedef struct packed {
  bit [63:0] value;
} rdma_bar_addr_t;

typedef struct packed {
  bit [11:0] value;
} rdma_cfg_offset_t;

typedef struct packed {
  bit device_read;
  bit device_write;
  bit atomic;
} rdma_dma_permission_t;

typedef struct packed {
  bit local_write;
  bit remote_read;
  bit remote_write;
  bit memory_window_bind;
  bit remote_atomic;
} rdma_rdma_access_t;
