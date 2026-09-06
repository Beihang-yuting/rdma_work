// 目录：测试层 integration/rdma_host_mem_umem_test.sv。
// 职责：在真实 host_mem manager 上验证 UMEM 页 backing、PBL 构建和释放无泄漏。
// 依赖：依赖 host_mem_pkg、rdma_host_mem_adapter_pkg 及 rdma_model_pkg。
// 所有权与生命周期：测试拥有本地 host_mem manager；适配器只在显式 unpin/release 时释放其登记的页。

class rdma_host_mem_umem_test extends uvm_test;
  `uvm_component_utils(rdma_host_mem_umem_test)

  // 功能：构造真实 host-mem UMEM 集成测试组件。
  // 输入/输出及副作用：name、parent 为 UVM 输入；只建立测试层级，不分配外部资源。
  // 失败/边界：构造阶段不执行 host_mem 初始化，资源均在 run_phase 中显式登记。
  function new(string name = "rdma_host_mem_umem_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：创建用于 host_mem 路由校验的 Function authority。
  // 输入/输出及副作用：name 为对象命名输入；返回独立 Function handle，不转移 manager 所有权。
  // 失败/边界：空句柄或错误 kind 会使 pin_umem 返回 INVALID_ARGUMENT。
  function automatic rdma_function_handle make_function(string name);
    rdma_function_handle function_h;

    function_h = rdma_function_handle::type_id::create(name);
    function_h.kind = RDMA_RESOURCE_FUNCTION;
    function_h.function_uid = 64'hca_fe_0000_0000_0001;
    function_h.object_id = 32'h0000_0053;
    function_h.generation = 32'd3;
    return function_h;
  endfunction

  // 功能：检查状态码并记录 host_mem 集成测试错误。
  // 输入/输出及副作用：label、status、expected 为只读输入；失败时产生 UVM error。
  // 失败/边界：空 status 按失败处理，不隐藏底层 host_mem 错误消息。
  function automatic void expect_status(string label,
                                         rdma_status status,
                                         rdma_status_code_e expected);
    if (status == null || status.code != expected)
      `uvm_error(label,
                 $sformatf("expected %s got %s (%s)", expected.name(),
                           status == null ? "null" : status.code.name(),
                           status == null ? "" : status.message))
  endfunction

  // 功能：驱动真实 host_mem UMEM/PBL/MW 生命周期并验证页 backing 正确回收。
  // 输入/输出及副作用：从 manager 申请两个 4 KiB 页并在结束时逆序释放；不修改外部 host_mem 源码。
  // 失败/边界：任一阶段失败均报告错误；最终 adapter.check_leaks 必须为零。
  task run_phase(uvm_phase phase);
    $unit::host_mem_manager host_mem;
    rdma_host_mem_adapter adapter;
    rdma_function_handle function_h;
    rdma_umem umem;
    rdma_pbl pbl;
    rdma_dma_mapping mapping;
    rdma_status status;
    int unsigned leak_count;

    phase.raise_objection(this);
    host_mem = $unit::host_mem_manager::type_id::create("umem_host_mem");
    host_mem.init_region(64'h0000_0010_0000_0000,
                         64'h0000_0010_00ff_ffff);
    adapter = rdma_host_mem_adapter::type_id::create("umem_adapter");
    adapter.mem = host_mem;
    function_h = make_function("umem_function");

    expect_status("HOST_UMEM_PIN",
                  adapter.pin_umem(function_h, 64'h0000_4000_0000_0000,
                                   8192, umem), RDMA_SC_OK);
    if (umem == null || umem.pages.size() != 2 ||
        umem.pages[0].iova.value == umem.user_va)
      `uvm_error("HOST_UMEM_PIN", "real host_mem IOVA was not installed")
    expect_status("HOST_PBL_BUILD",
                  rdma_pbl_builder::build_multilevel(umem, pbl), RDMA_SC_OK);
    expect_status("HOST_MAPPING_BUILD", adapter.build_umem_pbl(umem, mapping),
                  RDMA_SC_OK);
    if (mapping == null || mapping.umem_ref != umem || mapping.pbl_ref == null)
      `uvm_error("HOST_MAPPING_BUILD", "UMEM mapping lost PBL authority")

    expect_status("HOST_UMEM_UNPIN", adapter.unpin_umem(umem), RDMA_SC_OK);
    expect_status("HOST_UMEM_UNPIN_IDEMPOTENT", adapter.unpin_umem(umem),
                  RDMA_SC_OK);
    status = adapter.check_leaks(leak_count);
    expect_status("HOST_UMEM_LEAK_CHECK", status, RDMA_SC_OK);
    if (leak_count != 0)
      `uvm_error("HOST_UMEM_LEAK_CHECK", "UMEM host backing leaked")
    phase.drop_objection(this);
  endtask
endclass
