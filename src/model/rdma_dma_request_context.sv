// 目录：协议与资源模型层 model/rdma_dma_request_context.sv。
// 职责：实现 rdma_dma_request_context 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_dma_request_context.sv 属于模型层，描述语义请求、资源快照、DMA 映射及生命周期数据。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_dma_request_context extends uvm_object;
  `uvm_object_utils(rdma_dma_request_context)

  rdma_function_handle function_h;
  rdma_bdf_t requester_bdf;
  bit pasid_valid;
  bit [19:0] pasid;
  bit dma_domain_valid;
  int unsigned dma_domain_id;
  // 中文：DMA 请求携带完整 fabric route 与 reset epoch，防止跨 Host/root 重用。
  rdma_route_key_t route;
  rdma_reset_epoch_t reset_epoch;
  bit route_valid;
  bit epoch_valid;
  rdma_handle owner_h;
  // Optional queue-backing role hint used by deterministic lifecycle mocks.
  // The production DMA contract does not depend on this metadata; callers
  // that do not model queue backing leave it invalid.
  bit queue_role_valid;
  int unsigned queue_role;

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function new(string name = "rdma_dma_request_context");
    super.new(name);
    function_h = null;
    requester_bdf = '0;
    pasid_valid = 1'b0;
    pasid = '0;
    dma_domain_valid = 1'b0;
    dma_domain_id = '0;
    route = '0;
    reset_epoch = 0;
    route_valid = 1'b0;
    epoch_valid = 1'b0;
    owner_h = null;
    queue_role_valid = 1'b0;
    queue_role = '0;
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 validate）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function rdma_status validate();
    rdma_status status;

    if (function_h == null || function_h.kind != RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "DMA request Function is invalid");
    if (function_h.generation == 0)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "DMA request Function generation is zero");
    if (route_valid && !rdma_route_key_valid(route))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "DMA request route is invalid");
    if (!pasid_valid && pasid != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "invalid PASID must be zero");
    if (owner_h != null) begin
      status = rdma_handle_owner_status(owner_h, function_h);
      if (!status.ok())
        return status;
    end
    return rdma_status::success();
  endfunction

  // 功能：把源对象投影/克隆为当前类型的独立值快照，避免共享可变引用（接口 do_copy）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  virtual function void do_copy(uvm_object rhs);
    rdma_dma_request_context rhs_context;
    uvm_object cloned_object;

    super.do_copy(rhs);
    if (!$cast(rhs_context, rhs))
      `uvm_fatal("RDMA_COPY_TYPE",
                 "rdma_dma_request_context copy type mismatch")
    if (rhs_context.function_h == null) begin
      function_h = null;
    end
    else begin
      cloned_object = rhs_context.function_h.clone();
      if (cloned_object == null || !$cast(function_h, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE",
                   "DMA request Function clone type mismatch")
    end
    requester_bdf = rhs_context.requester_bdf;
    pasid_valid = rhs_context.pasid_valid;
    pasid = rhs_context.pasid;
    dma_domain_valid = rhs_context.dma_domain_valid;
    dma_domain_id = rhs_context.dma_domain_id;
    route = rhs_context.route;
    reset_epoch = rhs_context.reset_epoch;
    route_valid = rhs_context.route_valid;
    epoch_valid = rhs_context.epoch_valid;
    queue_role_valid = rhs_context.queue_role_valid;
    queue_role = rhs_context.queue_role;
    if (rhs_context.owner_h == null) begin
      owner_h = null;
    end
    else begin
      cloned_object = rhs_context.owner_h.clone();
      if (cloned_object == null || !$cast(owner_h, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE",
                   "DMA request owner clone type mismatch")
    end
  endfunction
endclass
