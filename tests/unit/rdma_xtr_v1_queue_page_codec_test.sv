class rdma_xtr_v1_queue_pd_fault_codec extends rdma_xtr_v1_queue_pd_codec;
  `uvm_object_utils(rdma_xtr_v1_queue_pd_fault_codec)

  int unsigned call_count;
  int unsigned delegated_success_count;

  function new(string name = "rdma_xtr_v1_queue_pd_fault_codec");
    super.new(name);
    call_count = 0;
    delegated_success_count = 0;
  endfunction

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

  function new(string name = "rdma_xtr_v1_queue_page_codec_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

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

  function automatic void reset_sentinel(ref byte unsigned bytes[]);
    bytes = new[3];
    bytes[0] = 8'hde;
    bytes[1] = 8'had;
    bytes[2] = 8'ha5;
  endfunction

  function automatic void expect_sentinel(string label,
                                            byte unsigned bytes[]);
    if (bytes.size() != 3 || bytes[0] != 8'hde ||
        bytes[1] != 8'had || bytes[2] != 8'ha5)
      `uvm_error(label, "rejected input changed caller output")
  endfunction

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
