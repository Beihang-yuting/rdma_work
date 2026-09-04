// 目录：协议与资源模型层 model/rdma_context_types.sv。
// 职责：实现 rdma_context_types 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_context_types.sv 属于模型层，描述语义请求、资源快照、DMA 映射及生命周期数据。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

typedef enum bit [1:0] {
  RDMA_OBJECT_DIRECT_4K       = 2'd0,
  RDMA_OBJECT_INDIRECT_4K     = 2'd1,
  RDMA_OBJECT_HUGE_2M         = 2'd2,
  RDMA_OBJECT_L3_INDIRECT_4K  = 2'd3
} rdma_object_mode_e;
