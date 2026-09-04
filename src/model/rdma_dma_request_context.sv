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

  // 功能：构造 rdma_dma_request_context，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：function_h=null；requester_bdf='0；pasid_valid=1'b0；pasid='0；dma_domain_valid=1'b0；dma_domain_id='0；route='0；reset_epoch=0；其余字段按实现默认值初始化。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_dma_request_context 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
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

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“DMA request Function is invalid”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、function_h、function_h.kind、function_h.generation、route_valid、route、pasid_valid、pasid 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_STALE_GENERATION、RDMA_SC_DMA_TRANSLATION；典型拒绝条件为“DMA request Function is invalid”“DMA request Function generation is zero”；失败路径不提交部分状态或转移未声明资源。

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

  // 功能：将 rhs 中 rdma_dma_request_context 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（rdma_dma_request_context copy type mismatch），不保留部分有效快照。
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
