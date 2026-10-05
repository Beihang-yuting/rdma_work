// 目录：硬件编解码层 codec/rdma/rdma_queue_page_codec.sv。
// 职责：把 queue 的 DMA page 引用编码为 PD 表项（8 字节/页）和整张 PD 表。
// 依赖：本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源仅保存非拥有引用，生命周期由调用方管理。

// // 阅读提示：先看公开接口，再看实现；失败路径应保持状态与资源所有权可追踪。

class rdma_hw_queue_pd_entry extends uvm_object;
  `rdma_object_utils(rdma_hw_queue_pd_entry)

  rdma_iova_t page_iova;
  int unsigned rdma_vf_id;
  bit valid;

  // 功能：构造 queue PD 表项，默认 page_iova=0、rdma_vf_id=0、valid=0。
  // 输入/输出及副作用：name 传给 super.new。
  // 失败/边界：无。
  function new(string name = "rdma_hw_queue_pd_entry");
    super.new(name);
    page_iova = '0;
    rdma_vf_id = 0;
    valid = 1'b0;
  endfunction
endclass

class rdma_hw_queue_pd_codec extends uvm_object;
  `rdma_object_utils(rdma_hw_queue_pd_codec)

  localparam int unsigned PAGE_BYTES = 4096;
  localparam int unsigned MAX_PAGES = 512;
  localparam int unsigned TABLE_BYTES = MAX_PAGES * 8;

  // 功能：构造 queue PD 表项/表 codec。
  // 输入/输出及副作用：name 传给 super.new。
  // 失败/边界：无。
  function new(string name = "rdma_hw_queue_pd_codec");
    super.new(name);
  endfunction

  // 功能：把一个 PD 表项编码为 8 字节（页 IOVA、VF ID、valid）。
  // 输入/输出及副作用：entry 只读；bytes 成功时输出 8 字节。
  // 失败/边界：entry 为空、IOVA 未按 4KB 对齐或 VF ID 超过 8 位返回 INVALID_ARGUMENT，不改 bytes。
  virtual function rdma_status encode_entry(
    rdma_hw_queue_pd_entry entry,
    inout byte unsigned bytes[]
  );
    bit [63:0] word;
    byte unsigned encoded[];

    if (entry == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "queue PD entry is null");
    if (!rdma_queue_aligned(entry.page_iova.value, PAGE_BYTES))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "queue PD entry IOVA is unaligned");
    if (entry.rdma_vf_id > 8'hff)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "queue PD entry VF ID exceeds eight bits");

    word = (entry.page_iova.value & 64'hffff_ffff_ffff_f000) |
           ((longint'(entry.rdma_vf_id) & 64'hff) << 4) |
           longint'(entry.valid);
    encoded = new[8];
    for (int unsigned i = 0; i < 8; i++)
      encoded[i] = word[63 - i*8 -: 8];
    bytes = encoded;
    return rdma_status::success();
  endfunction

  // 功能：把 DMA page 列表编码为整张 PD 表（TABLE_BYTES，按逻辑页下标放置各表项）。
  // 输入/输出及副作用：pages、rdma_vf_id 输入；bytes 成功时输出整表。
  // 失败/边界：VF ID 超 8 位、页数不在 1..512、页为空/校验失败/偏移不连续返回 INVALID_ARGUMENT；表项编码失败或字节数异常返回对应错误，不发布部分表。
  function rdma_status encode_table(
    rdma_queue_dma_page_ref pages[$],
    int unsigned rdma_vf_id,
    inout byte unsigned bytes[]
  );
    rdma_status status;
    byte unsigned encoded[];
    byte unsigned entry_bytes[];
    rdma_hw_queue_pd_entry entry;
    longint unsigned expected_offset;
    longint unsigned logical_index;

    if (rdma_vf_id > 8'hff)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "queue PD table VF ID exceeds eight bits");
    if (pages.size() == 0 || pages.size() > MAX_PAGES)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "queue PD table page count is outside 1..512");

    // // 先预检所有页，再分配并发布输出。
    foreach (pages[i]) begin
      if (pages[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "queue PD table contains a null page");
      status = rdma_status::nonnull(
        pages[i].validate(),
        "queue PD page validation returned null status"
      );
      if (!status.ok())
        return status;
      expected_offset = longint'(i) * PAGE_BYTES;
      if (pages[i].logical_page_offset != expected_offset)
        return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "queue PD table logical page offsets are not contiguous");
    end

    encoded = new[TABLE_BYTES];
    foreach (encoded[i])
      encoded[i] = 8'h00;

    foreach (pages[i]) begin
      logical_index = pages[i].logical_page_offset / PAGE_BYTES;
      entry = rdma_hw_queue_pd_entry::type_id::create(
          $sformatf("queue_pd_entry_%0d", logical_index));
      entry.page_iova = pages[i].page_iova;
      entry.rdma_vf_id = rdma_vf_id;
      entry.valid = 1'b1;
      entry_bytes = new[0];
      status = rdma_status::nonnull(
        encode_entry(entry, entry_bytes),
        "queue PD entry encoder returned null status"
      );
      if (!status.ok())
        return status;

      if (entry_bytes.size() != 8)
        return rdma_status::make(
            RDMA_SC_CODEC_ERROR,
            "queue PD entry encoder returned an invalid byte count");

      for (int unsigned j = 0; j < 8; j++)
        encoded[(logical_index * 8) + j] = entry_bytes[j];
    end

    bytes = encoded;
    return rdma_status::success();
  endfunction
endclass
