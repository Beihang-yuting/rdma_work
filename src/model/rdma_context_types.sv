// 中文说明：rdma_context_types.sv 属于模型层，描述语义请求、资源快照、DMA 映射及生命周期数据。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

typedef enum bit [1:0] {
  RDMA_OBJECT_DIRECT_4K       = 2'd0,
  RDMA_OBJECT_INDIRECT_4K     = 2'd1,
  RDMA_OBJECT_HUGE_2M         = 2'd2,
  RDMA_OBJECT_L3_INDIRECT_4K  = 2'd3
} rdma_object_mode_e;
