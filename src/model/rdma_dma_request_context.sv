// 目录：协议与资源模型层 model/rdma_dma_request_context.sv。
// 职责：描述一次 DMA 请求的 Function、BDF/PASID、DMA domain、route/epoch 与 owner 快照。
// 依赖：rdma_function_handle、route key、reset epoch、rdma_status。
// 所有权与生命周期：对象拥有值字段及 handle 的 clone；调用方管理外部资源。

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

  // 功能：构造默认（全无效）DMA 请求上下文。
  // 输入/输出及副作用：name 为对象名；各字段清零，句柄置 null。
  // 失败/边界：无。
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

  // 功能：把校验链得到的 status 规范化，null 时返回确定的 INVALID_STATE。
  // 输入/输出及副作用：candidate 非空原样返回；boundary 用于拼接诊断文本；不改上下文。
  // 失败/边界：null 不转成成功，且用 make_direct 避免被重载的 factory 再返回 null。
  function automatic rdma_status normalize_validation_status(
    rdma_status candidate,
    string boundary
  );
    if (candidate == null)
      return rdma_status::make_direct(
        RDMA_SC_INVALID_STATE,
        {"DMA request validation returned null status at ", boundary}
      );
    return candidate;
  endfunction

  // 功能：校验 Function、generation、route、PASID 与 owner 的一致性。
  // 输入/输出及副作用：只读本对象；返回 status。
  // 失败/边界：Function 非法/generation 为零/route 非法/无效 PASID 非零/owner 不属于 Function 时返回对应错误。
  function rdma_status validate();
    rdma_status status;

    if (function_h == null || function_h.kind != RDMA_RESOURCE_FUNCTION) begin
      status = rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "DMA request Function is invalid"
      );
      return normalize_validation_status(status, "Function validation");
    end
    if (function_h.generation == 0) begin
      status = rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "DMA request Function generation is zero"
      );
      return normalize_validation_status(status, "Function generation");
    end
    if (route_valid && !rdma_route_key_valid(route)) begin
      status = rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "DMA request route is invalid"
      );
      return normalize_validation_status(status, "route validation");
    end
    if (!pasid_valid && pasid != 0) begin
      status = rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "invalid PASID must be zero"
      );
      return normalize_validation_status(status, "PASID validation");
    end
    if (owner_h != null) begin
      status = rdma_handle_owner_status(owner_h, function_h);
      status = normalize_validation_status(status, "owner validation");
      if (!status.ok())
        return status;
    end
    status = rdma_status::success();
    return normalize_validation_status(status, "success construction");
  endfunction

  // 功能：深拷贝 rhs 的值字段，handle 字段按 clone 复制。
  // 输入/输出及副作用：覆盖当前对象字段；rhs 不被修改。
  // 失败/边界：类型不匹配触发 uvm_fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_dma_request_context rhs_context;

    super.do_copy(rhs);
    if (!$cast(rhs_context, rhs))
      `uvm_fatal("RDMA_COPY_TYPE",
                 "rdma_dma_request_context copy type mismatch")
    function_h = rdma_deep_copy#(rdma_function_handle)::of(
      rhs_context.function_h, "DMA request Function clone type mismatch");
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
    owner_h = rdma_deep_copy#(rdma_handle)::of(
      rhs_context.owner_h, "DMA request owner clone type mismatch");
  endfunction
endclass
