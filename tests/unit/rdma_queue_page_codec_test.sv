// 目录：测试层 unit/rdma_queue_page_codec_test.sv。
// 职责：验证 rdma_queue_page_codec_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_queue_page_codec_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_hw_queue_pd_fault_codec extends rdma_hw_queue_pd_codec;
  `uvm_object_utils(rdma_hw_queue_pd_fault_codec)

  int unsigned call_count;
  int unsigned delegated_success_count;

  // 功能：构造 rdma_hw_queue_pd_fault_codec，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：call_count=0；delegated_success_count=0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_queue_pd_fault_codec 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_queue_pd_fault_codec");
    super.new(name);
    call_count = 0;
    delegated_success_count = 0;
  endfunction

  // 功能：在 rdma_hw_queue_pd_fault_codec 中，encode_entry 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：entry（输入）、bytes（输出）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_entry 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  virtual function rdma_status encode_entry(
    rdma_hw_queue_pd_entry entry,
    inout byte unsigned bytes[]
  );
    rdma_status status;

    call_count++;
    if (call_count == 2)
      return rdma_status::make(RDMA_SC_CODEC_ERROR,
                               "injected second-entry encode failure");
    status = super.encode_entry(entry, bytes);
    if (status.ok())
      delegated_success_count++;
    return status;
  endfunction
endclass

class rdma_hw_queue_pd_null_status_codec extends rdma_hw_queue_pd_codec;
  `uvm_object_utils(rdma_hw_queue_pd_null_status_codec)

  // 功能：构造返回空状态的 PD codec fixture，用于验证表编码器对 virtual
  //       encode_entry 边界的 fail-closed 处理。
  // 输入/输出及副作用：name 是 UVM 对象名；new 只初始化父类，不创建或拥有
  //       页面、DMA 映射或输出缓冲区。
  // 失败/边界：该 fixture 的 encode_entry 有意返回 null；只有被测
  //       encode_table 正确归一化状态后，测试才能得到 INVALID_STATE 而不是崩溃。
  function new(string name = "rdma_hw_queue_pd_null_status_codec");
    super.new(name);
  endfunction

  // 功能：模拟派生 codec 在第一个表项编码时错误地返回 null status。
  // 输入/输出及副作用：entry 只读，bytes 不写入；返回 null 以注入 virtual
  //       边界故障，不改变 caller 的 sentinel 缓冲区。
  // 失败/边界：无论 entry 是否有效都返回 null；生产代码必须将其转换为
  //       INVALID_STATE 并保持 encode_table 的原子输出契约。
  virtual function rdma_status encode_entry(
    rdma_hw_queue_pd_entry entry,
    inout byte unsigned bytes[]
  );
    return null;
  endfunction
endclass

class rdma_queue_page_codec_test extends uvm_test;
  `uvm_component_utils(rdma_queue_page_codec_test)

  rdma_hw_queue_pd_codec codec;

  // 功能：构造 rdma_queue_page_codec_test，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_page_codec_test 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_page_codec_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：在 rdma_queue_page_codec_test 中，expect_status 在测试中执行 expect_status 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、status（输入）、expected（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_status 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function automatic void expect_status(
    string label,
    rdma_status status,
    rdma_status_code_e expected
  );
    if (status == null)
      `uvm_error(label, "codec returned a null status")
    else if (status.code != expected)
      `uvm_error(label,
                 $sformatf("expected %s, got %s (%s)", expected.name(),
                           status.code.name(), status.convert2string()))
  endfunction

  // 功能：make_page 创建独立的 rdma_queue_dma_page_ref；根据 name、page_iova、logical_page_offset 设置字段 page、mapping、iova.value、mapping.size、mapping.state、page.role、page.mapping、page.mapping_offset、page.logical_page_offset、page_iova.value，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、page_iova（输入）、logical_page_offset（输入）；make_page 读取 name、page_iova、logical_page_offset 并使用字段 page、mapping、iova.value、mapping.size、mapping.state、page.role、page.mapping、page.mapping_offset；函数返回 rdma_queue_dma_page_ref，不取得调用方资源所有权。
  // 失败/边界：make_page 的结果直接由 return page 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_queue_dma_page_ref make_page(
    string name,
    longint unsigned page_iova,
    longint unsigned logical_page_offset
  );
    rdma_queue_dma_page_ref page;
    rdma_dma_mapping mapping;

    page = rdma_queue_dma_page_ref::type_id::create(name);
    mapping = rdma_dma_mapping::type_id::create({name, "_mapping"});
    mapping.iova.value = page_iova;
    mapping.size = 4096;
    mapping.state = RDMA_MAPPING_ACTIVE;
    page.role = RDMA_QUEUE_ROLE_CQ_RING;
    page.mapping = mapping;
    page.mapping_offset = 0;
    page.logical_page_offset = logical_page_offset;
    page.page_iova.value = page_iova;
    return page;
  endfunction

  // 功能：在 rdma_queue_page_codec_test 中，reset_sentinel reset_sentinel 清理当前运行状态并建立新的复位/代际边界，使旧句柄或旧事务不能继续生效。
  // 输入/输出及副作用：bytes（输入）；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：复位参数为零、代际回退或存在未处理 pending 事务时拒绝更新 authority。
  function automatic void reset_sentinel(ref byte unsigned bytes[]);
    bytes = new[3];
    bytes[0] = 8'hde;
    bytes[1] = 8'had;
    bytes[2] = 8'ha5;
  endfunction

  // 功能：在 rdma_queue_page_codec_test 中，expect_sentinel 在测试中执行 expect_sentinel 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、bytes（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_sentinel 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function automatic void expect_sentinel(string label,
                                            byte unsigned bytes[]);
    if (bytes.size() != 3 || bytes[0] != 8'hde ||
        bytes[1] != 8'had || bytes[2] != 8'ha5)
      `uvm_error(label, "rejected input changed caller output")
  endfunction

  // 功能：在 rdma_queue_page_codec_test 中，run_phase 驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：run_phase 的 setup/阶段驱动失败时停止新增事务，并按测试生命周期清理 objection 与临时引用。
  task run_phase(uvm_phase phase);
    rdma_hw_queue_pd_entry entry;
    rdma_hw_queue_pd_fault_codec fault_codec;
    rdma_hw_queue_pd_null_status_codec null_status_codec;
    rdma_queue_dma_page_ref pages[$];
    byte unsigned bytes[];
    byte unsigned expected[];

    phase.raise_objection(this);
    codec = rdma_hw_queue_pd_codec::type_id::create("codec");

    entry = rdma_hw_queue_pd_entry::type_id::create("entry");
    entry.page_iova.value = 64'h1234_5678_9abc_d000;
    entry.rdma_vf_id = 8'h5a;
    entry.valid = 1'b1;
    expect_status("PD_ENTRY", codec.encode_entry(entry, bytes), RDMA_SC_OK);
    expected = '{8'h12, 8'h34, 8'h56, 8'h78,
                 8'h9a, 8'hbc, 8'hd5, 8'ha1};
    if (bytes != expected)
      `uvm_error("PD_ENTRY", "PD entry is not 12 34 56 78 9a bc d5 a1")

    reset_sentinel(bytes);
    entry = null;
    expect_status("ENTRY_NULL", codec.encode_entry(entry, bytes),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_sentinel("ENTRY_NULL_ATOMIC", bytes);

    entry = rdma_hw_queue_pd_entry::type_id::create("unaligned_entry");
    entry.page_iova.value = 64'h1234_5678_9abc_d001;
    entry.rdma_vf_id = 8'h5a;
    entry.valid = 1'b1;
    reset_sentinel(bytes);
    expect_status("ENTRY_UNALIGNED", codec.encode_entry(entry, bytes),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_sentinel("ENTRY_UNALIGNED_ATOMIC", bytes);

    entry.page_iova.value = 64'h1234_5678_9abc_d000;
    entry.rdma_vf_id = 256;
    reset_sentinel(bytes);
    expect_status("ENTRY_VF_RANGE", codec.encode_entry(entry, bytes),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_sentinel("ENTRY_VF_RANGE_ATOMIC", bytes);

    pages.delete();
    pages.push_back(make_page("page0", 64'h0000_0001_0000_0000, 0));
    pages.push_back(make_page("page1", 64'h0000_0001_0000_1000, 4096));
    expect_status("PD_TABLE", codec.encode_table(pages, 8'h05, bytes),
                  RDMA_SC_OK);
    if (bytes.size() != 4096)
      `uvm_error("PD_TABLE", "PD table is not exactly 4096 bytes")
    else begin
      expected = '{8'h00, 8'h00, 8'h00, 8'h01,
                   8'h00, 8'h00, 8'h00, 8'h51,
                   8'h00, 8'h00, 8'h00, 8'h01,
                   8'h00, 8'h00, 8'h10, 8'h51};
      for (int unsigned i = 0; i < 16; i++) begin
        if (bytes[i] != expected[i])
          `uvm_error("PD_TABLE_GOLDEN",
                     $sformatf("byte %0d expected %02x got %02x", i,
                               expected[i], bytes[i]))
      end
      for (int unsigned i = 16; i < 4096; i++) begin
        if (bytes[i] != 0) begin
          `uvm_error("PD_TABLE_ZERO",
                     $sformatf("unused byte %0d is nonzero", i))
          break;
        end
      end
    end

    pages.delete();
    reset_sentinel(bytes);
    expect_status("TABLE_ZERO_PAGES", codec.encode_table(pages, 8'h05, bytes),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_sentinel("TABLE_ZERO_PAGES_ATOMIC", bytes);

    for (int unsigned i = 0; i < 513; i++)
      pages.push_back(make_page($sformatf("many_page_%0d", i),
                                64'h0000_0010_0000_0000 +
                                  (longint'(i) << 12),
                                longint'(i) << 12));
    reset_sentinel(bytes);
    expect_status("TABLE_TOO_MANY_PAGES",
                  codec.encode_table(pages, 8'h05, bytes),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_sentinel("TABLE_TOO_MANY_PAGES_ATOMIC", bytes);

    pages.delete();
    pages.push_back(null);
    reset_sentinel(bytes);
    expect_status("TABLE_NULL_PAGE", codec.encode_table(pages, 8'h05, bytes),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_sentinel("TABLE_NULL_PAGE_ATOMIC", bytes);

    pages.delete();
    pages.push_back(make_page("bad_role", 64'h0000_0002_0000_0000, 0));
    pages[0].role = RDMA_QUEUE_ROLE_CQ_PD;
    reset_sentinel(bytes);
    expect_status("TABLE_PAGE_ROLE", codec.encode_table(pages, 8'h05, bytes),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_sentinel("TABLE_PAGE_ROLE_ATOMIC", bytes);

    pages[0] = make_page("bad_value", 64'h0000_0002_0000_0000, 0);
    pages[0].page_iova.value = 64'h0000_0002_0000_1000;
    reset_sentinel(bytes);
    expect_status("TABLE_PAGE_VALUE", codec.encode_table(pages, 8'h05, bytes),
                  RDMA_SC_DMA_TRANSLATION);
    expect_sentinel("TABLE_PAGE_VALUE_ATOMIC", bytes);

    pages.delete();
    pages.push_back(make_page("table_unaligned",
                              64'h0000_0002_1000_0001, 0));
    reset_sentinel(bytes);
    expect_status("TABLE_PAGE_UNALIGNED",
                  codec.encode_table(pages, 8'h05, bytes),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_sentinel("TABLE_PAGE_UNALIGNED_ATOMIC", bytes);

    pages.delete();
    pages.push_back(make_page("fault_page0", 64'h0000_0002_2000_0000, 0));
    pages.push_back(make_page("fault_page1", 64'h0000_0002_2000_1000,
                              4096));
    fault_codec = rdma_hw_queue_pd_fault_codec::type_id::create(
        "fault_codec");
    bytes = '{8'hc3, 8'h5a, 8'h00, 8'hff, 8'h19, 8'he7, 8'h42};
    expected = '{8'hc3, 8'h5a, 8'h00, 8'hff, 8'h19, 8'he7, 8'h42};
    expect_status("TABLE_LATE_ENTRY_FAILURE",
                  fault_codec.encode_table(pages, 8'h05, bytes),
                  RDMA_SC_CODEC_ERROR);
    if (fault_codec.call_count != 2 ||
        fault_codec.delegated_success_count != 1)
      `uvm_error("TABLE_LATE_ENTRY_PATH",
                 "fault was not injected after one encoded temporary entry")
    if (bytes != expected)
      `uvm_error("TABLE_LATE_ENTRY_ATOMIC",
                 "later entry failure changed caller table output")

    pages.delete();
    pages.push_back(make_page("null_status_page", 64'h0000_0002_3000_0000, 0));
    null_status_codec = rdma_hw_queue_pd_null_status_codec::type_id::create(
        "null_status_codec");
    reset_sentinel(bytes);
    expect_status("TABLE_NULL_STATUS",
                  null_status_codec.encode_table(pages, 8'h05, bytes),
                  RDMA_SC_INVALID_STATE);
    expect_sentinel("TABLE_NULL_STATUS_ATOMIC", bytes);

    pages.delete();
    pages.push_back(make_page("gap0", 64'h0000_0003_0000_0000, 0));
    pages.push_back(make_page("gap2", 64'h0000_0003_0000_2000, 8192));
    reset_sentinel(bytes);
    expect_status("TABLE_LOGICAL_GAP", codec.encode_table(pages, 8'h05, bytes),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_sentinel("TABLE_LOGICAL_GAP_ATOMIC", bytes);

    pages.delete();
    pages.push_back(make_page("dup0a", 64'h0000_0004_0000_0000, 0));
    pages.push_back(make_page("dup0b", 64'h0000_0004_0000_1000, 0));
    reset_sentinel(bytes);
    expect_status("TABLE_LOGICAL_DUP", codec.encode_table(pages, 8'h05, bytes),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_sentinel("TABLE_LOGICAL_DUP_ATOMIC", bytes);

    pages.delete();
    pages.push_back(make_page("reverse1", 64'h0000_0005_0000_1000, 4096));
    pages.push_back(make_page("reverse0", 64'h0000_0005_0000_0000, 0));
    reset_sentinel(bytes);
    expect_status("TABLE_LOGICAL_REVERSE",
                  codec.encode_table(pages, 8'h05, bytes),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_sentinel("TABLE_LOGICAL_REVERSE_ATOMIC", bytes);

    pages.delete();
    pages.push_back(make_page("table_vf", 64'h0000_0006_0000_0000, 0));
    reset_sentinel(bytes);
    expect_status("TABLE_VF_RANGE", codec.encode_table(pages, 256, bytes),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_sentinel("TABLE_VF_RANGE_ATOMIC", bytes);

    phase.drop_objection(this);
  endtask
endclass
