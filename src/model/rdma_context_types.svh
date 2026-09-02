typedef enum bit [1:0] {
  RDMA_OBJECT_DIRECT_4K       = 2'd0,
  RDMA_OBJECT_INDIRECT_4K     = 2'd1,
  RDMA_OBJECT_HUGE_2M         = 2'd2,
  RDMA_OBJECT_L3_INDIRECT_4K  = 2'd3
} rdma_object_mode_e;
