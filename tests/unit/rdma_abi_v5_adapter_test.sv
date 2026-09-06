// 目录：测试层 unit/rdma_abi_v5_adapter_test.sv。
// 职责：验证用户态 ABI v5 协商、context/region 映射及 exactly-once 生命周期。
// 依赖：依赖 rdma_abi_v5_api、rdma_types_pkg、rdma_model_pkg 和 UVM 测试基类。
// 所有权与生命周期：测试只拥有 ABI 测试对象；借用映射不得由 ABI 释放外部 host-mem 资源。

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

    phase.drop_objection(this);
  endtask
endclass
