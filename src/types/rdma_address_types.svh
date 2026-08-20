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
