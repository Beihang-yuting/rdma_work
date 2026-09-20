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

  // 功能：构造一个指定长度、4 KiB 页粒度且带 Function authority 的 UMEM。
  // 输入/输出及副作用：返回新 UMEM 值对象；仅填充本地字段，不接管 host-mem。
  // 失败/边界：零长度、地址溢出或非法页大小由 pin_pages() 拒绝；非页对齐起始 VA/长度用于覆盖 Linux ib_umem 对齐语义。
  function automatic rdma_umem make_umem(string name,
                                          longint unsigned length,
                                          rdma_function_handle function_h,
                                          longint unsigned start_va =
                                            64'h0000_4000_0000_0000);
    rdma_umem umem;

    umem = rdma_umem::type_id::create(name);
    umem.function_h = function_h;
    umem.user_va = start_va;
    umem.length = length;
    umem.page_size = 4096;
    umem.permissions = '{device_read:1'b1, device_write:1'b1, atomic:1'b0};
    umem.generation = function_h.generation;
    return umem;
  endfunction

  // 功能：创建代表驱动 HMC/PBLE allocator 返回值的非拥有引用，供 PBL2 显式绑定目录索引。
  // 输入/输出及副作用：name、function_h、first_index 为输入；返回值仅是本地 fixture，不分配或释放真实 HMC backing。
  // 失败/边界：first_index 为零的引用故意保留为无效 fixture，PBL builder 必须拒绝而不能自行猜测目录位置。
  function automatic rdma_hmc_ref make_hmc_ref(
    string name,
    rdma_function_handle function_h,
    int unsigned first_index,
    bit index_valid = 1'b1
  );
    rdma_hmc_ref hmc_ref;

    hmc_ref = rdma_hmc_ref::type_id::create(name);
    hmc_ref.owner = function_h;
    hmc_ref.object_kind = RDMA_RESOURCE_MR;
    hmc_ref.address.value = 64'h0000_0000_0800_0000;
    hmc_ref.size = 4096;
    hmc_ref.first_pbl_index = first_index;
    hmc_ref.index_valid = index_valid;
    hmc_ref.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
    return hmc_ref;
  endfunction

  // 功能：验证真实 PBLE allocator 允许从索引零开始分配，同时要求 HMC 快照显式携带有效性证据。
  // 输入/输出及副作用：创建同一 Function 下的零索引有效引用和未声明有效性
  //       的伪造引用，分别调用 validate；只读取返回状态。
  // 失败/边界：index_valid=1 的零索引必须返回 RDMA_SC_OK；index_valid=0
  //       无论索引为零还是非零都必须返回 RDMA_SC_INVALID_ARGUMENT，不能把
  //       数值本身当作 lease 证明。
  task automatic test_hmc_index_zero_requires_explicit_validity();
    rdma_function_handle function_h;
    rdma_hmc_ref zero_index;
    rdma_hmc_ref forged_zero;
    rdma_hmc_ref forged_nonzero;

    function_h = make_function("hmc_index_function");
    zero_index = make_hmc_ref("hmc_index_zero", function_h, 0, 1'b1);
    expect_status("HMC_INDEX_ZERO_VALID", zero_index.validate(), RDMA_SC_OK);

    forged_zero = make_hmc_ref("hmc_index_zero_forged", function_h, 0,
                               1'b0);
    expect_status("HMC_INDEX_ZERO_UNMARKED", forged_zero.validate(),
                  RDMA_SC_INVALID_ARGUMENT);

    forged_nonzero = make_hmc_ref("hmc_index_nonzero_forged", function_h,
                                  32'h80, 1'b0);
    expect_status("HMC_INDEX_NONZERO_UNMARKED", forged_nonzero.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
  endtask

  // 功能：验证 UMEM 接受 Linux ib_umem 语义中的非页对齐起始 VA，并按对齐区间创建完整 DMA 页序列。
  // 输入/输出及副作用：创建本地 Function/UMEM，调用 validate() 与 pin_pages()，读取首页 offset、对齐页地址和页数；不访问外部 host-mem。
  // 失败/边界：起始 VA 或长度未对齐本身不应被拒绝；溢出、零长度和非法页大小仍必须返回明确错误，失败时不得留下部分 pinned 页。
  task automatic test_umem_unaligned_range_uses_aligned_dma_span();
    rdma_function_handle function_h;
    rdma_umem umem;
    rdma_status status;

    function_h = make_function("unaligned_function");
    umem = make_umem("unaligned_umem", 64'h1001, function_h,
                     64'h0000_4000_0000_1003);

    status = umem.validate();
    expect_status("UNALIGNED_VALIDATE", status, RDMA_SC_OK);

    status = umem.pin_pages();
    expect_status("UNALIGNED_PIN", status, RDMA_SC_OK);
    if (umem.first_page_offset != 3)
      `uvm_error("UNALIGNED_PAGE_OFFSET",
                 "UMEM must preserve the original first-page offset")
    if (umem.pages.size() != 2)
      `uvm_error("UNALIGNED_PAGE_COUNT",
                 "UMEM must cover both aligned DMA blocks")
    if (umem.pages.size() >= 2 &&
        (umem.pages[0].host_va != 64'h0000_4000_0000_1000 ||
         umem.pages[1].host_va != 64'h0000_4000_0000_2000))
      `uvm_error("UNALIGNED_PAGE_BASE",
                 "UMEM page descriptors must use aligned page bases")
    if (umem.pages.size() >= 2 &&
        (umem.pages[0].iova.value != 64'h0000_4000_0000_1000 ||
         umem.pages[1].iova.value != 64'h0000_4000_0000_2000))
      `uvm_error("UNALIGNED_PAGE_IOVA",
                 "UMEM DMA blocks must retain aligned IOVA bases")
  endtask

  // 功能：验证 UMEM 的范围检查不会把非连续 DMA block 之间的空洞误当成可访问覆盖。
  // 输入/输出及副作用：创建并 pin 三页 UMEM，篡改第二页 IOVA 形成 gap，再调用 check_range；只读取返回状态，不改变 pin 账本。
  // 失败/边界：首尾页边界合法但中间存在 gap 时必须返回 RDMA_SC_DMA_TRANSLATION，不能仅凭首尾地址通过检查。
  task automatic test_umem_range_rejects_dma_gap();
    rdma_function_handle function_h;
    rdma_umem umem;
    rdma_iova_t first_iova;
    rdma_status status;

    function_h = make_function("gap_function");
    umem = make_umem("gap_umem", 3 * 4096, function_h);
    expect_status("GAP_PIN", umem.pin_pages(), RDMA_SC_OK);

    if (umem.pages.size() >= 2)
      umem.pages[1].iova.value += 2 * umem.page_size;

    first_iova = umem.pages[0].iova;
    status = umem.check_range(first_iova, 3 * umem.page_size);
    expect_status("GAP_RANGE_REJECT", status, RDMA_SC_DMA_TRANSLATION);
    if (!umem.pinned || umem.unpin_count != 0)
      `uvm_error("GAP_RANGE_SIDE_EFFECT",
                 "range rejection must not change UMEM pin ownership")
  endtask

  // 功能：验证非页对齐 UMEM 只暴露原始用户范围，而不是把首尾整页的 padding 当成 DMA payload。
  // 输入/输出及副作用：创建非对齐 UMEM，分别检查合法跨页区间、首部 padding 和尾部越界；只读取状态，不修改页账本。
  // 失败/边界：从首个 DMA 页基址开始的 prefix、超过 user_va+length-1 的 suffix 都必须拒绝，原始范围内的访问必须成功。
  task automatic test_umem_unaligned_range_is_bounded();
    rdma_function_handle function_h;
    rdma_umem umem;
    rdma_iova_t first_iova;
    rdma_status status;

    function_h = make_function("bounded_function");
    umem = make_umem("bounded_umem", 64'h1001, function_h,
                     64'h0000_4000_0000_1003);
    expect_status("BOUNDED_PIN", umem.pin_pages(), RDMA_SC_OK);
    first_iova = umem.pages[0].iova;
    first_iova.value += umem.first_page_offset;

    status = umem.check_range(first_iova, umem.length);
    expect_status("BOUNDED_VALID", status, RDMA_SC_OK);

    status = umem.check_range(umem.pages[0].iova, 1);
    expect_status("BOUNDED_PREFIX", status, RDMA_SC_DMA_TRANSLATION);

    first_iova.value += umem.length;
    status = umem.check_range(first_iova, 1);
    expect_status("BOUNDED_SUFFIX", status, RDMA_SC_DMA_TRANSLATION);
  endtask

  // 功能：验证 PBL mode 由 DMA block 的真实连续性决定，而不是由页数阈值猜测。
  // 输入/输出及副作用：创建并 pin 三组本地 UMEM，构建 PBL 后读取 mode、level 和目录索引；只修改本地页映射快照。
  // 失败/边界：连续一页或多页必须使用 PBL0；恰好两个非连续 block 使用 PBL1；三个非连续 block 使用 PBL2 且携带真实的非零目录索引。
  task automatic test_pbl_mode_follows_dma_contiguity();
    rdma_function_handle function_h;
    rdma_umem one_page;
    rdma_umem contiguous_pages;
    rdma_umem two_sparse_pages;
    rdma_umem three_sparse_pages;
    rdma_hmc_ref hmc_ref;
    rdma_pbl pbl;
    rdma_status status;

    function_h = make_function("pbl_mode_function");

    one_page = make_umem("pbl_one_page", 4096, function_h);
    expect_status("PBL0_ONE_PIN", one_page.pin_pages(), RDMA_SC_OK);
    pbl = null;
    status = rdma_pbl_builder::build_multilevel(one_page, pbl);
    expect_status("PBL0_ONE_BUILD", status, RDMA_SC_OK);
    if (pbl == null || pbl.mode != RDMA_MR_PBL0)
      `uvm_error("PBL0_ONE_MODE", "one contiguous block must use PBL0")

    contiguous_pages = make_umem("pbl_contiguous", 3 * 4096, function_h);
    expect_status("PBL0_CONTIG_PIN", contiguous_pages.pin_pages(), RDMA_SC_OK);
    pbl = null;
    status = rdma_pbl_builder::build_multilevel(contiguous_pages, pbl);
    expect_status("PBL0_CONTIG_BUILD", status, RDMA_SC_OK);
    if (pbl == null || pbl.mode != RDMA_MR_PBL0)
      `uvm_error("PBL0_CONTIG_MODE",
                 "contiguous blocks must use PBL0 regardless of count")

    two_sparse_pages = make_umem("pbl_two_sparse", 2 * 4096, function_h);
    expect_status("PBL1_SPARSE_PIN", two_sparse_pages.pin_pages(), RDMA_SC_OK);
    if (two_sparse_pages.pages.size() >= 2)
      two_sparse_pages.pages[1].iova.value += 2 * 4096;
    pbl = null;
    status = rdma_pbl_builder::build_multilevel(two_sparse_pages, pbl);
    expect_status("PBL1_SPARSE_BUILD", status, RDMA_SC_OK);
    if (pbl == null || pbl.mode != RDMA_MR_PBL1)
      `uvm_error("PBL1_SPARSE_MODE",
                 "two non-contiguous blocks must use PBL1")

    three_sparse_pages = make_umem("pbl_three_sparse", 3 * 4096, function_h);
    expect_status("PBL2_SPARSE_PIN", three_sparse_pages.pin_pages(), RDMA_SC_OK);
    if (three_sparse_pages.pages.size() >= 2)
      three_sparse_pages.pages[1].iova.value += 2 * 4096;
    if (three_sparse_pages.pages.size() >= 3)
      three_sparse_pages.pages[2].iova.value += 4 * 4096;
    pbl = null;
    status = rdma_pbl_builder::build_multilevel(three_sparse_pages, pbl);
    expect_status("PBL2_MISSING_HMC", status, RDMA_SC_INVALID_STATE);
    if (pbl != null)
      `uvm_error("PBL2_MISSING_HMC_OBJECT",
                 "failed PBL2 build must not publish a partial object")
    hmc_ref = make_hmc_ref("pbl_hmc_ref", function_h, 32'h1234);
    pbl = null;
    status = rdma_pbl_builder::build_multilevel(three_sparse_pages, pbl,
                                                hmc_ref);
    expect_status("PBL2_SPARSE_BUILD", status, RDMA_SC_OK);
    if (pbl == null || pbl.mode != RDMA_MR_PBL2)
      `uvm_error("PBL2_SPARSE_MODE",
                 "more than two non-contiguous blocks must use PBL2")
    if (pbl != null && pbl.mode == RDMA_MR_PBL2 &&
        (pbl.hmc_ref == null ||
         pbl.hmc_ref.first_pbl_index != hmc_ref.first_pbl_index))
      `uvm_error("PBL2_DIRECTORY_INDEX",
                 "PBL2 must carry the allocator-provided HMC/PBLE index")
  endtask

  // 功能：验证 PBL.validate 会拒绝 page_iovas、PBA 和 PBL2 目录 authority 被篡改的快照。
  // 输入/输出及副作用：分别构建本地 PBL0/PBL2，修改一个镜像字段后调用 validate；只修改测试快照，不触碰 UMEM/HMC 的外部所有权。
  // 失败/边界：页引用不一致、PBA 不匹配、目录地址不匹配或 HMC 容量不足必须返回 RDMA_SC_INVALID_ARGUMENT，不能继续发布伪造布局。
  task automatic test_pbl_validate_rejects_inconsistent_snapshots();
    rdma_function_handle function_h;
    rdma_umem contiguous_umem;
    rdma_umem sparse_umem;
    rdma_hmc_ref hmc_ref;
    rdma_pbl pbl;
    rdma_status status;

    function_h = make_function("pbl_validate_function");

    contiguous_umem = make_umem("pbl_validate_contiguous", 4096,
                                function_h);
    expect_status("PBL_VALIDATE_PIN", contiguous_umem.pin_pages(), RDMA_SC_OK);
    expect_status("PBL_VALIDATE_BUILD",
                  rdma_pbl_builder::build_multilevel(contiguous_umem, pbl),
                  RDMA_SC_OK);
    pbl.page_iovas[0].value += pbl.page_size;
    expect_status("PBL_VALIDATE_PAGE_IOVA",
                  pbl.validate(), RDMA_SC_INVALID_ARGUMENT);

    pbl = null;
    expect_status("PBL_VALIDATE_REBUILD",
                  rdma_pbl_builder::build_multilevel(contiguous_umem, pbl),
                  RDMA_SC_OK);
    pbl.page_layout.pba0.value += pbl.page_size;
    expect_status("PBL_VALIDATE_PBA",
                  pbl.validate(), RDMA_SC_INVALID_ARGUMENT);

    sparse_umem = make_umem("pbl_validate_sparse", 3 * 4096, function_h);
    expect_status("PBL_VALIDATE_SPARSE_PIN", sparse_umem.pin_pages(),
                  RDMA_SC_OK);
    sparse_umem.pages[1].iova.value += 2 * sparse_umem.page_size;
    sparse_umem.pages[2].iova.value += 4 * sparse_umem.page_size;
    hmc_ref = make_hmc_ref("pbl_validate_hmc", function_h, 32'h1234);
    pbl = null;
    expect_status("PBL_VALIDATE_PBL2_BUILD",
                  rdma_pbl_builder::build_multilevel(sparse_umem, pbl,
                                                      hmc_ref),
                  RDMA_SC_OK);
    pbl.directory_iova.value += pbl.page_size;
    expect_status("PBL_VALIDATE_DIRECTORY",
                  pbl.validate(), RDMA_SC_INVALID_ARGUMENT);
  endtask

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
    if (pbl == null || !pbl.active || pbl.mode != RDMA_MR_PBL0 ||
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
    test_umem_unaligned_range_uses_aligned_dma_span();
    test_umem_range_rejects_dma_gap();
    test_umem_unaligned_range_is_bounded();
    test_pbl_mode_follows_dma_contiguity();
    test_pbl_validate_rejects_inconsistent_snapshots();
    test_hmc_index_zero_requires_explicit_validity();
    phase.drop_objection(this);
  endtask
endclass
