// 中文说明：rdma_address_types.sv 属于基础类型层，集中定义 RDMA 枚举、地址、身份和状态契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

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
