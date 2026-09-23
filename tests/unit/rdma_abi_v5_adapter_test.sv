// 目录：测试层 unit/rdma_abi_v5_adapter_test.sv。
// 职责：验证用户态 ABI v5 协商、context/region 映射及 exactly-once 生命周期。
// 依赖：依赖 rdma_abi_v5_api、rdma_types_pkg、rdma_model_pkg 和 UVM 测试基类。
// 所有权与生命周期：测试只拥有 ABI 测试对象；借用映射不得由 ABI 释放外部 host-mem 资源。

// 中文设计：ABI 的 context/host-memory 后端是可替换的 virtual boundary，
// 因此测试必须能够模拟“后端违反状态返回契约”的最小故障。以下两个 fixture
// 只返回一次 null，不修改父类的成功路径或其 allocation ledger。
class rdma_abi_null_context_backing extends rdma_mock_context_backing;
  `uvm_object_utils(rdma_abi_null_context_backing)

  bit null_next_acquire;

  // 功能：构造一次性 null-acquire fixture，默认不注入故障。
  // 输入/输出及副作用：name 为 UVM 对象名；初始化本地开关，不创建 context slot。
  // 失败/边界：只有显式置位 null_next_acquire 时下一次 acquire 返回 null status，随后恢复父类行为。
  function new(string name = "rdma_abi_null_context_backing");
    super.new(name);
    null_next_acquire = 1'b0;
  endfunction

  // 功能：在 ABI alloc_context 的 acquire 边界注入一次 null status，验证调用方 fail-closed。
  // 输入/输出及副作用：binding/resource_kind/local_id/context_ref 为输入输出；故障时清空 context_ref，不创建 slot。
  // 失败/边界：null 注入只消费一次；未注入时委托父类并保留其正常生命周期语义。
  virtual function rdma_status acquire(
    rdma_function_binding binding,
    rdma_resource_kind_e resource_kind,
    int unsigned local_id,
    output rdma_context_backing_ref context_ref
  );
    if (null_next_acquire) begin
      null_next_acquire = 1'b0;
      context_ref = null;
      return null;
    end
    return super.acquire(binding, resource_kind, local_id, context_ref);
  endfunction
endclass

class rdma_abi_null_host_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_abi_null_host_mem)

  bit null_next_allocate;
  bit null_next_release;

  // 功能：构造一次性 null host-memory fixture，默认委托父类实现。
  // 输入/输出及副作用：name 为 UVM 对象名；初始化两个故障开关，不预分配 mapping。
  // 失败/边界：每个开关只影响下一次对应调用，故障消费后恢复父类行为。
  function new(string name = "rdma_abi_null_host_mem");
    super.new(name);
    null_next_allocate = 1'b0;
    null_next_release = 1'b0;
  endfunction

  // 功能：在 ABI map_region_with_backing 的 host_mem.allocate 边界注入一次 null status。
  // 输入/输出及副作用：请求参数和 mapping 为输入输出；故障时清空 mapping，不创建后端 region。
  // 失败/边界：null 注入只消费一次；未注入时委托父类并保留其 allocation ledger。
  virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    if (null_next_allocate) begin
      null_next_allocate = 1'b0;
      mapping = null;
      return null;
    end
    return super.allocate(request_context, size, alignment, direction, mapping);
  endfunction

  // 功能：在 ABI unmap_region 的 host_mem.release 边界注入一次 null status。
  // 输入/输出及副作用：mapping 为待释放输入；故障时不修改父类 region 或 release seal。
  // 失败/边界：null 注入只消费一次；未注入时委托父类执行 exactly-once release。
  virtual function rdma_status \release (rdma_dma_mapping mapping);
    if (null_next_release) begin
      null_next_release = 1'b0;
      return null;
    end
    return super.\release (mapping);
  endfunction
endclass

class rdma_abi_v5_adapter_test extends uvm_test;
  `uvm_component_utils(rdma_abi_v5_adapter_test)

  // 功能：构造 ABI v5 测试组件并建立 UVM 层级关系。
  // 输入/输出及副作用：name、parent 为 UVM 输入；只创建本地测试组件，不访问外部资源。
  // 失败/边界：父组件为空由 UVM 框架处理；构造阶段不执行协商或映射。
  function new(string name = "rdma_abi_v5_adapter_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：创建一个具有稳定 UID、generation、reset epoch 和 BDF 路由的 Function binding。
  // 输入/输出及副作用：name 为对象命名输入；返回独立 binding 值快照，不接管外部对象。
  // 失败/边界：legacy identity 配置失败时返回未完成 binding，测试必须报告错误而不能继续伪造映射。
  function automatic rdma_function_binding make_binding(string name);
    rdma_function_binding binding;

    binding = rdma_function_binding::type_id::create(name);
    binding.function_uid = 64'h1234_5678_9abc_def0;
    binding.global_function_id = 32'h1020_3040;
    binding.generation = 32'd17;
    binding.pcie.bdf = '{segment:16'h1, bus:8'h22, device:5'h3,
                         function_num:3'h4};
    if (!binding.configure_identity_from_legacy_mirrors(
          16'h0, 32'h1, RDMA_FUNCTION_PF, 16'h0, 64'd9).ok()) begin
      `uvm_error("ABI_BINDING", "Function binding identity setup failed")
    end
    return binding;
  endfunction

  // 功能：检查返回状态码并报告可定位的 ABI 测试错误。
  // 输入/输出及副作用：label、status、expected 为只读输入；失败时产生 UVM error，不修改 ABI 状态。
  // 失败/边界：status 为空时按失败处理；该辅助函数不吞掉状态消息。
  function automatic void expect_status(string label,
                                         rdma_status status,
                                         rdma_status_code_e expected);
    if (status == null || status.code != expected)
      `uvm_error(label,
                 $sformatf("expected %s got %s (%s)", expected.name(),
                           status == null ? "null" : status.code.name(),
                           status == null ? "" : status.message))
  endfunction

  // 功能：执行 ABI v5 的成功、拒绝、authority 和映射释放场景。
  // 输入/输出及副作用：phase 由 UVM 提供；task 更新本地 ABI 账本并产生断言报告，不拥有外部 host-mem 映射。
  // 失败/边界：任一前置协商或映射失败时仍执行 objection 收尾；失败路径不得依赖未初始化 response。
  task run_phase(uvm_phase phase);
    rdma_abi_v5_api abi;
    rdma_abi_v5_response response;
    rdma_abi_v5_response context_response;
    rdma_abi_v5_response invalid_response;
    rdma_function_binding binding;
    rdma_function_handle stale_function;
    rdma_status status;
    rdma_mock_context_backing context_api;
    rdma_mock_host_mem host_mem_api;
    rdma_abi_v5_api backend_abi;
    rdma_abi_v5_response backend_response;
    rdma_abi_v5_response borrowed_response;
    rdma_abi_v5_response query_response;
    rdma_abi_v5_response region_response;
    rdma_abi_v5_api region_abi;
    rdma_abi_v5_api null_context_abi;
    rdma_abi_v5_api null_host_abi;
    rdma_abi_v5_response null_response;
    rdma_abi_v5_response null_map_response;
    rdma_abi_v5_response null_release_response;
    rdma_abi_null_context_backing null_context_api;
    rdma_abi_null_host_mem null_host_api;
    int unsigned host_release_calls;

    phase.raise_objection(this);
    abi = rdma_abi_v5_api::type_id::create("abi");
    binding = make_binding("binding");
    expect_status("ABI_CONFIGURE", abi.configure(binding), RDMA_SC_OK);

    expect_status("ABI_NEGOTIATE", abi.negotiate(5, response), RDMA_SC_OK);
    if (response == null || response.negotiated_version != 5)
      `uvm_error("ABI_NEGOTIATE", "ABI v5 negotiation response is incomplete")

    expect_status("ABI_VERSION_REJECT", abi.negotiate(4, invalid_response),
                   RDMA_SC_UNSUPPORTED_OPCODE);

    expect_status("ABI_CONTEXT_ALLOC",
                  abi.alloc_context(context_response), RDMA_SC_OK);
    if (context_response == null || context_response.mapping_id == 0 ||
        context_response.region_kind != RDMA_ABI_REGION_CONTEXT ||
        context_response.function_uid != binding.function_uid ||
        context_response.generation != binding.generation ||
        context_response.reset_epoch != binding.function_reset_epoch())
      `uvm_error("ABI_CONTEXT_ALLOC", "context response lost authority snapshot")

    expect_status("ABI_DOORBELL_MAP",
                  abi.map_region(RDMA_ABI_REGION_DOORBELL, 8192, response),
                  RDMA_SC_OK);
    if (response == null || response.length != 8192 ||
        response.region_kind != RDMA_ABI_REGION_DOORBELL ||
        response.function_uid != binding.function_uid ||
        response.generation != binding.generation ||
        response.reset_epoch != binding.function_reset_epoch())
      `uvm_error("ABI_DOORBELL_MAP", "doorbell response is incomplete")

    expect_status("ABI_DUPLICATE_UNMAP", abi.unmap_region(response.mapping_id),
                  RDMA_SC_OK);
    expect_status("ABI_DUPLICATE_UNMAP_IDEMPOTENT",
                  abi.unmap_region(response.mapping_id), RDMA_SC_OK);
    if (abi.release_count != 1)
      `uvm_error("ABI_REFCOUNT", "mapping release was not exactly once")
    expect_status("ABI_QUERY_RELEASED",
                  abi.query_mapping(response.mapping_id, query_response),
                  RDMA_SC_OK);
    if (query_response == null || !query_response.released ||
        query_response.refcount != 0)
      `uvm_error("ABI_QUERY_RELEASED", "unmapped descriptor is not terminal")

    expect_status("ABI_ZERO_SIZE",
                  abi.map_region(RDMA_ABI_REGION_QP, 0, invalid_response),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("ABI_UNALIGNED_SIZE",
                  abi.map_region(RDMA_ABI_REGION_QP, 513, invalid_response),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("ABI_CONTEXT_MAP_REJECT",
                  abi.map_region(RDMA_ABI_REGION_CONTEXT, 512, invalid_response),
                  RDMA_SC_INVALID_ARGUMENT);

    // 验证 ABI v5 规定的全部用户态 mmap region 类型都能被独立登记和释放。
    region_abi = rdma_abi_v5_api::type_id::create("region_abi");
    expect_status("ABI_REGION_CONFIGURE", region_abi.configure(binding),
                  RDMA_SC_OK);
    expect_status("ABI_REGION_NEGOTIATE", region_abi.negotiate(5, region_response),
                  RDMA_SC_OK);
    expect_status("ABI_REGION_QP", region_abi.map_region(
                  RDMA_ABI_REGION_QP, 512, region_response), RDMA_SC_OK);
    expect_status("ABI_REGION_QP_UNMAP",
                  region_abi.unmap_region(region_response.mapping_id), RDMA_SC_OK);
    expect_status("ABI_REGION_CQ", region_abi.map_region(
                  RDMA_ABI_REGION_CQ, 64, region_response), RDMA_SC_OK);
    expect_status("ABI_REGION_CQ_UNMAP",
                  region_abi.unmap_region(region_response.mapping_id), RDMA_SC_OK);
    expect_status("ABI_REGION_SRQ", region_abi.map_region(
                  RDMA_ABI_REGION_SRQ, 64, region_response), RDMA_SC_OK);
    expect_status("ABI_REGION_SRQ_UNMAP",
                  region_abi.unmap_region(region_response.mapping_id), RDMA_SC_OK);
    expect_status("ABI_REGION_SHADOW", region_abi.map_region(
                  RDMA_ABI_REGION_SHADOW, 4096, region_response), RDMA_SC_OK);
    expect_status("ABI_REGION_SHADOW_UNMAP",
                  region_abi.unmap_region(region_response.mapping_id), RDMA_SC_OK);
    expect_status("ABI_REGION_FWQE_SGB", region_abi.map_region(
                  RDMA_ABI_REGION_FWQE_SGB, 512, region_response), RDMA_SC_OK);
    expect_status("ABI_REGION_FWQE_SGB_UNMAP",
                  region_abi.unmap_region(region_response.mapping_id), RDMA_SC_OK);

    stale_function = binding.make_handle();
    stale_function.generation++;
    expect_status("ABI_STALE_GENERATION",
                  abi.validate_function(stale_function),
                  RDMA_SC_STALE_GENERATION);

    status = abi.map_region(RDMA_ABI_REGION_SHADOW, 4096, response);
    expect_status("ABI_SHADOW_MAP", status, RDMA_SC_OK);
    if (status != null && status.ok()) begin
      expect_status("ABI_SHADOW_UNMAP", abi.unmap_region(response.mapping_id),
                    RDMA_SC_OK);
      if (abi.release_count != 2)
        `uvm_error("ABI_REFCOUNT_SHADOW", "shadow release count drifted")
    end

    // 注入真实的抽象后端，确认 context/host-mem owned backing 的释放顺序，
    // 并确认 borrowed 映射只登记引用而不触发外部 release。
    context_api = rdma_mock_context_backing::type_id::create("context_api");
    host_mem_api = rdma_mock_host_mem::type_id::create("host_mem_api");
    backend_abi = rdma_abi_v5_api::type_id::create("backend_abi");
    expect_status("ABI_BACKEND_CONFIGURE",
                  backend_abi.configure(binding, context_api, host_mem_api),
                  RDMA_SC_OK);
    expect_status("ABI_BACKEND_NEGOTIATE",
                  backend_abi.negotiate(5, backend_response), RDMA_SC_OK);
    expect_status("ABI_BACKEND_CONTEXT",
                  backend_abi.alloc_context(backend_response), RDMA_SC_OK);
    if (backend_response == null || backend_response.context_ref == null ||
        context_api.release_call_count != 0)
      `uvm_error("ABI_BACKEND_CONTEXT", "context backing was not acquired")
    expect_status("ABI_BACKEND_CONTEXT_UNMAP",
                  backend_abi.unmap_region(backend_response.mapping_id),
                  RDMA_SC_OK);
    if (context_api.release_call_count != 1)
      `uvm_error("ABI_BACKEND_CONTEXT_RELEASE", "context release count drifted")

    expect_status("ABI_BACKEND_QP_MAP",
                  backend_abi.map_region(RDMA_ABI_REGION_QP, 512,
                                         backend_response), RDMA_SC_OK);
    expect_status("ABI_BACKEND_BORROWED_MAP",
                  backend_abi.map_region_with_backing(
                    RDMA_ABI_REGION_CQ, 64, RDMA_ABI_MAPPING_BORROWED,
                    backend_response.dma_mapping, null, borrowed_response),
                  RDMA_SC_OK);
    expect_status("ABI_BACKEND_BORROWED_UNMAP",
                  backend_abi.unmap_region(borrowed_response.mapping_id),
                  RDMA_SC_OK);
    host_release_calls = 0;
    foreach (host_mem_api.calls[i])
      if (host_mem_api.calls[i] != null &&
          host_mem_api.calls[i].method_name == "release")
        host_release_calls++;
    if (host_release_calls != 0)
      `uvm_error("ABI_BORROWED_RELEASE", "borrowed mapping released host memory")
    expect_status("ABI_BACKEND_QP_UNMAP",
                  backend_abi.unmap_region(backend_response.mapping_id),
                  RDMA_SC_OK);
    host_release_calls = 0;
    foreach (host_mem_api.calls[i])
      if (host_mem_api.calls[i] != null &&
          host_mem_api.calls[i].method_name == "release")
        host_release_calls++;
    if (host_release_calls != 1)
      `uvm_error("ABI_OWNED_RELEASE", "owned mapping was not released once")

    // 后端 status 返回 null 时，ABI 必须在不登记 mapping/不推进 context_id
    // 的前提下报告 INVALID_STATE；该场景专门覆盖 virtual boundary 的 fail-closed 契约。
    null_context_api = rdma_abi_null_context_backing::type_id::create(
      "null_context_api"
    );
    null_context_abi = rdma_abi_v5_api::type_id::create("null_context_abi");
    expect_status("ABI_NULL_CONTEXT_CONFIGURE",
                  null_context_abi.configure(binding, null_context_api),
                  RDMA_SC_OK);
    expect_status("ABI_NULL_CONTEXT_NEGOTIATE",
                  null_context_abi.negotiate(5, null_response), RDMA_SC_OK);
    null_context_api.null_next_acquire = 1'b1;
    expect_status("ABI_NULL_CONTEXT_ACQUIRE",
                  null_context_abi.alloc_context(null_response),
                  RDMA_SC_INVALID_STATE);
    if (null_response == null || null_response.mapping_id != 0 ||
        null_context_abi.context_id != 1 ||
        null_context_abi.mappings.size() != 0)
      `uvm_error("ABI_NULL_CONTEXT_ACQUIRE",
                 "null context status published a partial mapping")

    null_host_api = rdma_abi_null_host_mem::type_id::create("null_host_api");
    null_host_abi = rdma_abi_v5_api::type_id::create("null_host_abi");
    expect_status("ABI_NULL_HOST_CONFIGURE",
                  null_host_abi.configure(binding, null, null_host_api),
                  RDMA_SC_OK);
    expect_status("ABI_NULL_HOST_NEGOTIATE",
                  null_host_abi.negotiate(5, null_map_response), RDMA_SC_OK);
    null_host_api.null_next_allocate = 1'b1;
    expect_status("ABI_NULL_HOST_ALLOCATE",
                  null_host_abi.map_region(RDMA_ABI_REGION_QP, 512,
                                            null_map_response),
                  RDMA_SC_INVALID_STATE);
    if (null_map_response == null || null_map_response.mapping_id != 0 ||
        null_host_abi.next_mapping_id != 1 ||
        null_host_abi.mappings.size() != 0)
      `uvm_error("ABI_NULL_HOST_ALLOCATE",
                 "null host status published a partial mapping")

    null_host_api.null_next_release = 1'b1;
    expect_status("ABI_NULL_HOST_MAP_FOR_RELEASE",
                  null_host_abi.map_region(RDMA_ABI_REGION_QP, 512,
                                            null_release_response),
                  RDMA_SC_OK);
    expect_status("ABI_NULL_HOST_RELEASE",
                  null_host_abi.unmap_region(null_release_response.mapping_id),
                  RDMA_SC_INVALID_STATE);
    expect_status("ABI_NULL_HOST_RELEASE_QUERY",
                  null_host_abi.query_mapping(null_release_response.mapping_id,
                                               query_response),
                  RDMA_SC_OK);
    if (query_response == null || query_response.released ||
        query_response.refcount != 1)
      `uvm_error("ABI_NULL_HOST_RELEASE",
                 "null release status retired the mapping prematurely")
    expect_status("ABI_NULL_HOST_RELEASE_RETRY",
                  null_host_abi.unmap_region(null_release_response.mapping_id),
                  RDMA_SC_OK);

    phase.drop_objection(this);
  endtask
endclass
