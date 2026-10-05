// 目录/层次：协议与资源模型层 model/rdma_context_types.sv。
// 职责：定义 context 对象的寻址模式枚举 rdma_object_mode_e。
// 依赖：无外部依赖。
// 所有权与生命周期：仅类型定义，不拥有运行时对象。

typedef enum bit [1:0] {
  RDMA_OBJECT_DIRECT_4K       = 2'd0,
  RDMA_OBJECT_INDIRECT_4K     = 2'd1,
  RDMA_OBJECT_HUGE_2M         = 2'd2,
  RDMA_OBJECT_L3_INDIRECT_4K  = 2'd3
} rdma_object_mode_e;
