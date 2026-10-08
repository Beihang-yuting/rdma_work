// 目录：驱动层 src/drv/rdma_drv_mem.sv。
// 职责：alloc.c 的内核队列缓冲（xtrdma_alloc_kernel_buf：≤2MiB 且偏好大页时为一块连续 HUGE 缓冲，
//   否则为 4KiB 页 + 一张 PD 表的 INDIRECT 缓冲），以及 pble.c 的 PBLE 池（HMC PBL 页上的 8B 条目）。
// 依赖：rdma_drv_hw、rdma_be、rdma_defs.svh（RDMA_PD_ENTRY_*、RDMA_ALLOC_TYPE_*）。
// 所有权与生命周期：rdma_drv_kbuf 拥有其页与 PD 表，free 释放；PBLE 池只借用 HMC 页。

class rdma_drv_kbuf extends uvm_object;
  `rdma_object_utils(rdma_drv_kbuf)

  localparam int unsigned HUGE_PAGE_BYTES = 2 * 1024 * 1024;

  int unsigned alloc_type;
  int unsigned size;
  // HUGE：pages[0] 为整块缓冲；INDIRECT：pages 为 4KiB 数据页，pd_tbl 为 PD 表页。
  rdma_drv_dma pages[$];
  rdma_drv_dma pd_tbl;

  // 功能：构造空缓冲。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：默认 HUGE、size=0、pages 为空且 pd_tbl=null；alloc 成功前 base_iova 返回 0 且不可读写。
  function new(string name = "rdma_drv_kbuf");
    super.new(name);
    alloc_type = RDMA_ALLOC_TYPE_HUGE;
    size = 0;
    pd_tbl = null;
  endfunction

  // 功能：xtrdma_alloc_kernel_buf：prefer_huge 且 size≤2MiB 时分配连续 HUGE 缓冲；否则分配
  //   ceil(size/4KiB) 个数据页与一张 PD 表，表项为 PBA|VF_ID|VLD（大端）。
  // 输入/输出及副作用：分配 DMA、写 PD 表。
  // 失败/边界：任一分配失败返回错误并释放已分配部分。
  function rdma_status alloc(rdma_drv_hw hw, int unsigned bytes, bit prefer_huge,
                             int unsigned vf_id);
    rdma_drv_dma page;
    bit [63:0] entry;
    rdma_status status;

    size = bytes;
    if (prefer_huge && bytes <= HUGE_PAGE_BYTES) begin
      alloc_type = RDMA_ALLOC_TYPE_HUGE;
      status = hw.alloc_dma(bytes, RDMA_HMC_PAGE_BYTES, page);
      if (status.ok())
        pages.push_back(page);
      return status;
    end
    alloc_type = RDMA_ALLOC_TYPE_INDIRECT;
    if ((bytes + RDMA_HMC_PAGE_BYTES - 1) / RDMA_HMC_PAGE_BYTES > RDMA_HMC_PD_PER_SD)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "kernel buffer exceeds one PD table");
    status = hw.alloc_dma(RDMA_HMC_PAGE_BYTES, RDMA_HMC_PAGE_BYTES, pd_tbl);
    if (!status.ok())
      return status;
    for (int unsigned i = 0; i * RDMA_HMC_PAGE_BYTES < bytes; i++) begin
      status = hw.alloc_dma(RDMA_HMC_PAGE_BYTES, RDMA_HMC_PAGE_BYTES, page);
      if (!status.ok()) begin
        void'(free(hw));
        return status;
      end
      pages.push_back(page);
      entry = '0;
      entry[RDMA_PD_ENTRY_PBA_LSB +: RDMA_PD_ENTRY_PBA_WIDTH] = page.iova >> RDMA_PD_ENTRY_PBA_LSB;
      entry[RDMA_PD_ENTRY_VF_ID_LSB +: RDMA_PD_ENTRY_VF_ID_WIDTH] = vf_id;
      entry[RDMA_PD_ENTRY_VLD_LSB] = 1'b1;
      status = hw.write_qword(pd_tbl, i * 8, entry);
      if (!status.ok()) begin
        void'(free(hw));
        return status;
      end
    end
    return rdma_status::success();
  endfunction

  // 功能：xtrdma_get_kernel_buffer_base_iova：HUGE 为缓冲基址，INDIRECT 为 PD 表地址。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：未分配返回 0。
  function bit [63:0] base_iova();
    if (alloc_type == RDMA_ALLOC_TYPE_INDIRECT) begin
      if (pd_tbl == null)
        return 64'h0;
      return pd_tbl.iova;
    end
    if (pages.size() == 0)
      return 64'h0;
    return pages[0].iova;
  endfunction

  // 功能：写缓冲内 offset 处字节（驱动对 va 的直接写）。
  // 输入/输出及副作用：写主机内存。
  // 失败/边界：跨 INDIRECT 页的写按页拆分。
  function rdma_status write(rdma_drv_hw hw, int unsigned offset, byte unsigned bytes[]);
    rdma_status status;
    int unsigned done;
    int unsigned chunk;
    int unsigned page_offset;

    if (alloc_type != RDMA_ALLOC_TYPE_INDIRECT)
      return hw.write(pages[0], offset, bytes);
    done = 0;
    while (done < bytes.size()) begin
      page_offset = (offset + done) % RDMA_HMC_PAGE_BYTES;
      chunk = RDMA_HMC_PAGE_BYTES - page_offset;
      if (chunk > bytes.size() - done)
        chunk = bytes.size() - done;
      status = hw.write(pages[(offset + done) / RDMA_HMC_PAGE_BYTES], page_offset,
                        rdma_be::slice(bytes, done, chunk));
      if (!status.ok())
        return status;
      done += chunk;
    end
    return rdma_status::success();
  endfunction

  // 功能：读缓冲内 offset 处 size_arg 字节。
  // 输入/输出及副作用：bytes 输出。
  // 失败/边界：同 write。
  function rdma_status read(rdma_drv_hw hw, int unsigned offset, int unsigned size_arg,
                            output rdma_bytes_t bytes);
    rdma_bytes_t part;
    rdma_status status;
    int unsigned done;
    int unsigned chunk;
    int unsigned page_offset;

    if (alloc_type != RDMA_ALLOC_TYPE_INDIRECT)
      return hw.read(pages[0], offset, size_arg, bytes);
    bytes = new[size_arg];
    done = 0;
    while (done < size_arg) begin
      page_offset = (offset + done) % RDMA_HMC_PAGE_BYTES;
      chunk = RDMA_HMC_PAGE_BYTES - page_offset;
      if (chunk > size_arg - done)
        chunk = size_arg - done;
      status = hw.read(pages[(offset + done) / RDMA_HMC_PAGE_BYTES], page_offset, chunk, part);
      if (!status.ok())
        return status;
      foreach (part[i])
        bytes[done + i] = part[i];
      done += chunk;
    end
    return rdma_status::success();
  endfunction

  // 功能：xtrdma_free_kernel_buf。
  // 输入/输出及副作用：释放全部页与 PD 表。
  // 失败/边界：返回首个释放错误，仍继续释放其余。
  function rdma_status free(rdma_drv_hw hw);
    rdma_status status;
    rdma_status one;

    status = rdma_status::success();
    foreach (pages[i]) begin
      one = hw.free_dma(pages[i]);
      if (status.ok() && !one.ok())
        status = one;
    end
    pages.delete();
    one = hw.free_dma(pd_tbl);
    if (status.ok() && !one.ok())
      status = one;
    pd_tbl = null;
    return status;
  endfunction
endclass

// pble.c 的 PBLE 池：条目为 HMC PBL 页上的 8B 大端页描述符；get 按 ALIGN(cnt,4) 分配连续索引，
// 不超过一页时不跨页（单 chunk），否则从页首开始占用连续页。
class rdma_drv_pble extends uvm_object;
  `rdma_object_utils(rdma_drv_pble)

  localparam int unsigned PER_PAGE = RDMA_HMC_PAGE_BYTES / 8;

  protected rdma_drv_hw hw;
  protected rdma_drv_dma pages[$];
  protected bit used[];

  // 功能：构造空池。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：init 前 get 失败。
  function new(string name = "rdma_drv_pble");
    super.new(name);
    hw = null;
  endfunction

  // 功能：xtrdma_init_pble：以 HMC PBL 对象页作为池。
  // 输入/输出及副作用：保存非拥有引用。
  // 失败/边界：hw_arg 为 null 或页为空时仍建立零容量池，后续 get 失败；调用者管理页与 hw 生命周期。
  function void init(rdma_drv_hw hw_arg, rdma_drv_dma pbl_pages[$]);
    hw = hw_arg;
    pages = pbl_pages;
    used = new[pages.size() * PER_PAGE];
  endfunction

  // 功能：xtrdma_get_pble：分配 ALIGN(cnt,4) 个连续条目。
  // 输入/输出及副作用：first 输出首条目索引；置位。
  // 失败/边界：无连续空间返回 RESOURCE_EXHAUSTED。
  function rdma_status get(int unsigned cnt, output int unsigned first);
    int unsigned n;
    int unsigned run;

    n = (cnt + 3) / 4 * 4;
    first = 0;
    run = 0;
    foreach (used[i]) begin
      if (run == 0 && n <= PER_PAGE && (i % PER_PAGE) + n > PER_PAGE)
        continue;
      if (run == 0 && n > PER_PAGE && (i % PER_PAGE) != 0)
        continue;
      if (used[i]) begin
        run = 0;
        continue;
      end
      if (run == 0)
        first = i;
      run++;
      if (run == n) begin
        for (int unsigned k = first; k < first + n; k++)
          used[k] = 1'b1;
        return rdma_status::success();
      end
    end
    return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED, "PBLE pool is exhausted");
  endfunction

  // 功能：xtrdma_free_pble：释放 ALIGN(cnt,4) 个条目。
  // 输入/输出及副作用：清位。
  // 失败/边界：越界忽略。
  function void put(int unsigned first, int unsigned cnt);
    for (int unsigned k = first; k < first + (cnt + 3) / 4 * 4 && k < used.size(); k++)
      used[k] = 1'b0;
  endfunction

  // 功能：写第 idx 个 PBLE = be64(page_dma | VLD)。
  // 输入/输出及副作用：写 HMC PBL 页。
  // 失败/边界：越界返回 INVALID_ARGUMENT。
  function rdma_status write_entry(int unsigned idx, bit [63:0] page_dma);
    if (idx >= used.size())
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "PBLE index is out of range");
    return hw.write_qword(pages[idx / PER_PAGE], (idx % PER_PAGE) * 8, page_dma | 64'h1);
  endfunction

  // 功能：已分配条目数。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：init 前或零页池返回 0；按对齐后实际置位数统计，可能大于客户端请求 cnt。
  function int unsigned in_use();
    int unsigned c;

    c = 0;
    foreach (used[i])
      c += used[i];
    return c;
  endfunction
endclass
