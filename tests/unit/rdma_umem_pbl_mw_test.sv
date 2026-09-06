// 目录：测试层 unit/rdma_umem_pbl_mw_test.sv。
// 职责：验证 UMEM 页 pin/refcount、多级 PBL 构建和 MW bind/invalidate 生命周期。
// 依赖：依赖 rdma_model_pkg 中的 rdma_umem、rdma_pbl_builder 与 rdma_mw_binding。
// 所有权与生命周期：测试只拥有本地 UMEM/PBL/MW 值对象；borrowed 场景用于证明不会替外部对象 unpin。

class rdma_umem_pbl_mw_test extends uvm_test;
  `uvm_component_utils(rdma_umem_pbl_mw_test)

  // 功能：构造 UMEM/PBL/MW 单元测试组件并建立 UVM 层级关系。
  // 输入/输出及副作用：name、parent 为 UVM 输入；只创建本地测试组件，不访问外部后端。
  // 失败/边界：父组件为空由 UVM 框架处理；构造阶段不执行 pin、PBL 或 MW 操作。
  function new(string name = "rdma_umem_pbl_mw_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：创建一个具有稳定 Function UID、对象 ID 和 generation 的测试 authority。
  // 输入/输出及副作用：name 为对象命名输入；返回独立句柄，不转移外部资源所有权。
  // 失败/边界：返回空句柄表示 fixture 创建失败，调用方必须停止后续状态机。
  function automatic rdma_function_handle make_function(string name);
    rdma_function_handle function_h;

    function_h = rdma_function_handle::type_id::create(name);
    function_h.kind = RDMA_RESOURCE_FUNCTION;
    function_h.function_uid = 64'hf00d_0000_0000_0001;
    function_h.object_id = 32'h0000_0021;
    function_h.generation = 32'd7;
    return function_h;
  endfunction

  // 功能：检查状态码并报告可定位的 UVM 错误。
  // 输入/输出及副作用：label、status、expected 为只读输入；失败时产生 UVM error，不修改生产对象。
  // 失败/边界：status 为空或 code 不匹配时按失败处理，并保留实际错误消息。
  function automatic void expect_status(string label,
                                         rdma_status status,
                                         rdma_status_code_e expected);
    if (status == null || status.code != expected)
      `uvm_error(label,
                 $sformatf("expected %s got %s (%s)", expected.name(),
                           status == null ? "null" : status.code.name(),
                           status == null ? "" : status.message))
  endfunction

  // 功能：构造一个 2 MiB、4 KiB 页粒度且带 Function authority 的 UMEM。
  // 输入/输出及副作用：返回新 UMEM 值对象；仅填充本地字段，不接管 host-mem。
  // 失败/边界：长度必须是 page_size 的整数倍；非法长度由 pin_pages() 拒绝。
  function automatic rdma_umem make_umem(string name,
                                          longint unsigned length,
                                          rdma_function_handle function_h);
    rdma_umem umem;

    umem = rdma_umem::type_id::create(name);
    umem.function_h = function_h;
    umem.user_va = 64'h0000_4000_0000_0000;
    umem.length = length;
    umem.page_size = 4096;
    umem.permissions = '{device_read:1'b1, device_write:1'b1, atomic:1'b0};
    umem.generation = function_h.generation;
    return umem;
  endfunction

  // 功能：验证多级 PBL、MW 绑定和 exactly-once invalidate 会释放 UMEM pin。
  // 输入/输出及副作用：创建本地 UMEM/PBL/MW 并更新其生命周期计数；不访问外部 host-mem。
  // 失败/边界：pin、PBL、bind 任一步失败都报告错误；重复 invalidate 必须保持幂等且不增加 unpin 次数。
  task automatic test_multilevel_pbl_and_mw_invalidate();
    rdma_function_handle function_h;
    rdma_umem umem;
    rdma_pbl pbl;
    rdma_mw_binding mw;

    function_h = make_function("umem_function");
    umem = make_umem("umem_2m", 2 * 1024 * 1024, function_h);
    expect_status("UMEM_PIN", umem.pin_pages(), RDMA_SC_OK);
    if (!umem.pinned || umem.pages.size() != 512 || umem.pin_count != 1)
      `uvm_error("UMEM_PIN", "2 MiB UMEM did not produce 512 pinned pages")

    expect_status("PBL_BUILD", rdma_pbl_builder::build_multilevel(umem, pbl),
                  RDMA_SC_OK);
    if (pbl == null || !pbl.active || pbl.level_count < 2 ||
        pbl.page_count != umem.pages.size())
      `uvm_error("PBL_BUILD", "multilevel PBL directory is incomplete")

    mw = rdma_mw_binding::type_id::create("mw_owned");
    mw.function_h = function_h;
    mw.mw_h = rdma_function_handle::type_id::create("mw_handle");
    mw.mw_h.kind = RDMA_RESOURCE_MW;
    mw.mw_h.function_uid = function_h.function_uid;
    mw.mw_h.object_id = 32'h0000_0042;
    mw.mw_h.generation = function_h.generation;
    mw.access = '{local_write:1'b1, remote_read:1'b1,
                  remote_write:1'b1, memory_window_bind:1'b1,
                  remote_atomic:1'b0};
    expect_status("MW_BIND", mw.\bind (umem, pbl), RDMA_SC_OK);
    expect_status("MW_INVALIDATE", mw.invalidate(), RDMA_SC_OK);
    expect_status("MW_INVALIDATE_IDEMPOTENT", mw.invalidate(), RDMA_SC_OK);
    if (umem.pin_count != 1 || umem.unpin_count != 1 || umem.pinned ||
        pbl.active || !mw.invalidated)
      `uvm_error("UMEM_REF", "owned MW invalidation did not release exactly once")
  endtask

  // 功能：验证 borrowed UMEM/PBL 只解除引用，不调用外部 unpin 或释放目录。
  // 输入/输出及副作用：创建 borrowed MW 并执行 bind/invalidate；只更新借用对象的本地状态。
  // 失败/边界：borrowed invalidate 必须幂等，且 UMEM 的 unpin_count 必须保持零。
  task automatic test_borrowed_mapping_detaches_without_unpin();
    rdma_function_handle function_h;
    rdma_umem umem;
    rdma_pbl pbl;
    rdma_mw_binding mw;

    function_h = make_function("borrowed_function");
    umem = make_umem("borrowed_umem", 4096, function_h);
    expect_status("BORROWED_PIN", umem.pin_pages(), RDMA_SC_OK);
    expect_status("BORROWED_PBL", rdma_pbl_builder::build_multilevel(umem, pbl),
                  RDMA_SC_OK);
    mw = rdma_mw_binding::type_id::create("mw_borrowed");
    mw.function_h = function_h;
    mw.ownership = RDMA_OWNERSHIP_BORROWED;
    expect_status("BORROWED_BIND", mw.\bind (umem, pbl), RDMA_SC_OK);
    expect_status("BORROWED_INVALIDATE", mw.invalidate(), RDMA_SC_OK);
    expect_status("BORROWED_INVALIDATE_IDEMPOTENT", mw.invalidate(), RDMA_SC_OK);
    if (umem.unpin_count != 0 || !umem.pinned || !pbl.active)
      `uvm_error("BORROWED_REF", "borrowed invalidation released external backing")
  endtask

  // 功能：验证 MW bind 拒绝跨 Function、stale generation 和不匹配 PBL 的 authority。
  // 输入/输出及副作用：仅创建本地错误输入并检查状态码；失败路径不修改 UMEM/PBL。
  // 失败/边界：任一 authority 不匹配必须在提交 bind 前返回明确错误。
  task automatic test_mw_authority_rejection();
    rdma_function_handle function_h;
    rdma_function_handle foreign_h;
    rdma_umem umem;
    rdma_pbl pbl;
    rdma_mw_binding mw;

    function_h = make_function("authority_function");
    foreign_h = make_function("foreign_function");
    foreign_h.function_uid++;
    umem = make_umem("authority_umem", 4096, function_h);
    expect_status("AUTHORITY_PIN", umem.pin_pages(), RDMA_SC_OK);
    expect_status("AUTHORITY_PBL", rdma_pbl_builder::build_multilevel(umem, pbl),
                  RDMA_SC_OK);
    mw = rdma_mw_binding::type_id::create("mw_authority");
    mw.function_h = foreign_h;
    expect_status("MW_FOREIGN_FUNCTION", mw.\bind (umem, pbl),
                  RDMA_SC_DMA_PERMISSION);
    mw.function_h = function_h;
    function_h.generation++;
    expect_status("MW_STALE_GENERATION", mw.\bind (umem, pbl),
                  RDMA_SC_STALE_GENERATION);
  endtask

  // 功能：运行 UMEM/PBL/MW 全部生命周期和拒绝路径，并完成 objection 收尾。
  // 输入/输出及副作用：phase 由 UVM 提供；任务只产生断言报告和本地值对象。
  // 失败/边界：测试失败也必须释放 objection，避免仿真悬挂。
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    test_multilevel_pbl_and_mw_invalidate();
    test_borrowed_mapping_detaches_without_unpin();
    test_mw_authority_rejection();
    phase.drop_objection(this);
  endtask
endclass
