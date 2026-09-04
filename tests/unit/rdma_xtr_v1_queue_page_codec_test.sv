// 目录：测试层 unit/rdma_xtr_v1_queue_page_codec_test.sv。
// 职责：验证 rdma_xtr_v1_queue_page_codec_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_xtr_v1_queue_page_codec_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_xtr_v1_queue_pd_fault_codec extends rdma_xtr_v1_queue_pd_codec;
  `uvm_object_utils(rdma_xtr_v1_queue_pd_fault_codec)

  int unsigned call_count;
  int unsigned delegated_success_count;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_xtr_v1_queue_pd_fault_codec");
    super.new(name);
    call_count = 0;
    delegated_success_count = 0;
  endfunction

  // 功能：把输入模型字段按硬件布局编码到目标 image/缓冲区，并在写入前检查范围、重叠和保留位。
  // 输入/输出及副作用：参数 entry, bytes 用于执行 encode_entry；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：镜像长度、字段宽度、保留位或写入范围非法时不修改已写入字节。
  virtual function rdma_status encode_entry(
    rdma_xtr_v1_queue_pd_entry entry,
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

class rdma_xtr_v1_queue_page_codec_test extends uvm_test;
  `uvm_component_utils(rdma_xtr_v1_queue_page_codec_test)

  rdma_xtr_v1_queue_pd_codec codec;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_xtr_v1_queue_page_codec_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：在测试中检查调用结果、状态码和副作用是否符合契约；失败时报告可定位的验证信息。
  // 输入/输出及副作用：参数 label, status, expected 用于执行 expect_status；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：测试前置对象缺失时应报告断言错误并停止依赖该对象的后续检查。
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

  // 功能：依据输入请求创建对应的值对象或资源计划，并校验依赖、所有权和生命周期后返回结果。
  // 输入/输出及副作用：输入请求、容量和依赖用于构造/预留资源；返回独立对象或状态，不暴露内部可变集合。
  //   参数越界、容量不足或构造中途失败时回滚已登记的局部状态。
  // 失败/边界：依赖为空、参数越界、容量不足或构造步骤失败时清理局部结果并返回明确错误。
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

  // 功能：清理当前运行状态并建立新的复位/代际边界，使旧句柄或旧事务不能继续生效。
  // 输入/输出及副作用：参数 bytes 用于执行 reset_sentinel；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：复位参数为零、代际回退或存在未处理 pending 事务时拒绝更新 authority。
  function automatic void reset_sentinel(ref byte unsigned bytes[]);
    bytes = new[3];
    bytes[0] = 8'hde;
    bytes[1] = 8'had;
    bytes[2] = 8'ha5;
  endfunction

  // 功能：在测试中检查调用结果、状态码和副作用是否符合契约；失败时报告可定位的验证信息。
  // 输入/输出及副作用：参数 label, bytes 用于执行 expect_sentinel；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：测试前置对象缺失时应报告断言错误并停止依赖该对象的后续检查。
  function automatic void expect_sentinel(string label,
                                            byte unsigned bytes[]);
    if (bytes.size() != 3 || bytes[0] != 8'hde ||
        bytes[1] != 8'had || bytes[2] != 8'ha5)
      `uvm_error(label, "rejected input changed caller output")
  endfunction

  // 功能：驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase 控制 UVM 调度；task 驱动事务、断言和 objection，测试 fixture 由本层负责清理。
  //   阶段提前结束或前置 setup 失败时必须释放 objection 并停止后续访问。
  // 失败/边界：setup 失败或阶段被终止时停止新增事务，确保 objection、临时对象和外部引用按测试生命周期收尾。
  task run_phase(uvm_phase phase);
    rdma_xtr_v1_queue_pd_entry entry;
    rdma_xtr_v1_queue_pd_fault_codec fault_codec;
    rdma_queue_dma_page_ref pages[$];
    byte unsigned bytes[];
    byte unsigned expected[];

    phase.raise_objection(this);
    codec = rdma_xtr_v1_queue_pd_codec::type_id::create("codec");

    entry = rdma_xtr_v1_queue_pd_entry::type_id::create("entry");
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

    entry = rdma_xtr_v1_queue_pd_entry::type_id::create("unaligned_entry");
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
    fault_codec = rdma_xtr_v1_queue_pd_fault_codec::type_id::create(
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
