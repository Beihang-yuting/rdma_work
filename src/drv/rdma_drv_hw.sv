// 目录：驱动层 src/drv/rdma_drv_hw.sv。
// 职责：驱动访问硬件的三种原语：BAR 寄存器写（xtrdma_iowrite64be）、DMA 缓冲区
//   （xtrdma_alloc_dma_mem，按 IOVA 读写）、资源位图（alloc.c / rdma_main.h 的 bitmap 分配）。
// 依赖：rdma_host_mem_api、rdma_be、rdma_defs.svh。
// 所有权与生命周期：rdma_drv_hw 借用 host_mem 与 BAR；分配出的 rdma_drv_dma 归调用方，free 后失效。

// BAR 写端口：offset 为 BAR 内绝对偏移（xtrdma_hw.h 的 XTRDMA_PF_NTFE_*，即 0x2000 起）。
virtual class rdma_drv_bar extends uvm_object;
  // 功能：构造 BAR 端口。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无。
  function new(string name = "rdma_drv_bar");
    super.new(name);
  endfunction

  // 功能：写一个 8B 寄存器，value 按驱动 iowrite64be 的大端值传递。
  // 输入/输出及副作用：由实现转交设备。
  // 失败/边界：设备拒绝时 status 非成功。
  pure virtual task write64(bit [63:0] offset, bit [63:0] value, output rdma_status status);
endclass

// 一段驱动分配的 DMA 内存。
class rdma_drv_dma extends uvm_object;
  `rdma_object_utils(rdma_drv_dma)

  rdma_dma_mapping mapping;
  bit [63:0] iova;
  int unsigned size;

  // 功能：构造空缓冲区描述。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无。
  function new(string name = "rdma_drv_dma");
    super.new(name);
    mapping = null;
    iova = '0;
    size = 0;
  endfunction
endclass

// alloc.c 的资源位图：alloc_next 为轮转首次适配，alloc_first 为从 0 开始的首次适配。
class rdma_drv_bitmap extends uvm_object;
  `rdma_object_utils(rdma_drv_bitmap)

  protected bit used[];
  protected int unsigned next_pos;

  // 功能：构造空位图。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：未 init 前容量为 0。
  function new(string name = "rdma_drv_bitmap");
    super.new(name);
    next_pos = 0;
  endfunction

  // 功能：设置容量并清空，start 为轮转起点。
  // 输入/输出及副作用：重置全部位。
  // 失败/边界：start>=max 时按 0。
  function void init(int unsigned max, int unsigned start = 0);
    used = new[max];
    next_pos = 0;
    if (start < max)
      next_pos = start;
  endfunction

  // 功能：xtrdma_alloc_rsrc_from_next_pos：从 next_pos 找空位，到尾后从 0 找；成功后 next_pos=n+1。
  // 输入/输出及副作用：置位并推进 next_pos。
  // 失败/边界：位图已满返回 0。
  function bit alloc_next(output int unsigned n);
    n = 0;
    for (int unsigned k = 0; k < used.size(); k++) begin
      n = (next_pos + k) % used.size();
      if (!used[n]) begin
        used[n] = 1'b1;
        next_pos = (n + 1) % used.size();
        return 1'b1;
      end
    end
    return 1'b0;
  endfunction

  // 功能：xtrdma_alloc_rsrc_from_initial_pos：从 0 开始的首次适配。
  // 输入/输出及副作用：置位。
  // 失败/边界：位图已满返回 0。
  function bit alloc_first(output int unsigned n);
    n = 0;
    foreach (used[i])
      if (!used[i]) begin
        used[i] = 1'b1;
        n = i;
        return 1'b1;
      end
    return 1'b0;
  endfunction

  // 功能：预留指定位（如 QP0/QP1）。
  // 输入/输出及副作用：置位。
  // 失败/边界：越界忽略。
  function void reserve(int unsigned n);
    if (n < used.size())
      used[n] = 1'b1;
  endfunction

  // 功能：释放一位。
  // 输入/输出及副作用：清位。
  // 失败/边界：越界忽略。
  function void free(int unsigned n);
    if (n < used.size())
      used[n] = 1'b0;
  endfunction

  // 功能：已用位数。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
  function int unsigned count();
    int unsigned c;

    c = 0;
    foreach (used[i])
      c += used[i];
    return c;
  endfunction
endclass

// 驱动的硬件访问上下文：一个 Function 的 BAR 与 DMA 分配器。
class rdma_drv_hw extends uvm_object;
  `rdma_object_utils(rdma_drv_hw)

  rdma_host_mem_api host_mem;
  rdma_drv_bar bar;
  protected rdma_dma_request_context dma_ctx;

  // 功能：构造未绑定的硬件上下文。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：bind 前所有操作返回 INVALID_STATE。
  function new(string name = "rdma_drv_hw");
    super.new(name);
    host_mem = null;
    bar = null;
    dma_ctx = null;
  endfunction

  // 功能：绑定 BAR、主机内存与 DMA 请求身份（Function 句柄）。
  // 输入/输出及副作用：保存非拥有引用。
  // 失败/边界：参数为 null 返回 INVALID_ARGUMENT。
  function rdma_status bind_hw(rdma_drv_bar bar_arg, rdma_host_mem_api host_mem_arg,
                               rdma_function_handle function_h);
    if (bar_arg == null || host_mem_arg == null || function_h == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "driver hardware binding is incomplete");
    bar = bar_arg;
    host_mem = host_mem_arg;
    dma_ctx = rdma_dma_request_context::type_id::create("drv_dma_ctx");
    dma_ctx.function_h = function_h;
    return rdma_status::success();
  endfunction

  // 功能：xtrdma_alloc_dma_mem：分配 size 字节、align 对齐的 DMA 内存并清零。
  // 输入/输出及副作用：mem_buf 输出新缓冲区。
  // 失败/边界：分配或清零失败返回其 status，mem_buf 为 null。
  function rdma_status alloc_dma(int unsigned size, int unsigned align,
                                 output rdma_drv_dma mem_buf);
    rdma_dma_mapping mapping;
    rdma_status status;

    mem_buf = null;
    if (host_mem == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "driver hardware is not bound");
    status = host_mem.allocate(dma_ctx, size, align, RDMA_DMA_BIDIRECTIONAL, mapping);
    if (!status.ok())
      return status;
    mem_buf = rdma_drv_dma::type_id::create("drv_dma");
    mem_buf.mapping = mapping;
    mem_buf.iova = mapping.iova.value;
    mem_buf.size = size;
    status = write(mem_buf, 0, rdma_be::zeros(size));
    if (!status.ok())
      mem_buf = null;
    return status;
  endfunction

  // 功能：释放 DMA 内存。
  // 输入/输出及副作用：释放 mapping；mem_buf 不再可用。
  // 失败/边界：null 视为成功。
  function rdma_status free_dma(rdma_drv_dma mem_buf);
    if (mem_buf == null || mem_buf.mapping == null)
      return rdma_status::success();
    return host_mem.\release (mem_buf.mapping);
  endfunction

  // 功能：写缓冲区 offset 处的字节。
  // 输入/输出及副作用：写主机内存。
  // 失败/边界：越界或写失败返回错误。
  function rdma_status write(rdma_drv_dma mem_buf, int unsigned offset, byte unsigned bytes[]);
    byte data[];

    data = new[bytes.size()];
    foreach (data[i])
      data[i] = bytes[i];
    return host_mem.write(mem_buf.mapping, offset, data);
  endfunction

  // 功能：读缓冲区 offset 处 size 字节。
  // 输入/输出及副作用：bytes 输出。
  // 失败/边界：读失败返回错误，bytes 为空。
  function rdma_status read(rdma_drv_dma mem_buf, int unsigned offset, int unsigned size,
                            output rdma_bytes_t bytes);
    byte data[];
    rdma_status status;

    bytes = new[0];
    status = host_mem.read(mem_buf.mapping, offset, size, data);
    if (!status.ok())
      return status;
    bytes = new[data.size()];
    foreach (data[i])
      bytes[i] = data[i];
    return status;
  endfunction

  // 功能：写一个大端 qword（set_64bit_val）。
  // 输入/输出及副作用：写主机内存。
  // 失败/边界：同 write。
  function rdma_status write_qword(rdma_drv_dma mem_buf, int unsigned offset, bit [63:0] value);
    rdma_bytes_t bytes;

    bytes = rdma_be::zeros(8);
    rdma_be::put_qword(bytes, 0, value);
    return write(mem_buf, offset, bytes);
  endfunction

  // 功能：读一个大端 qword（get_64bit_val）。
  // 输入/输出及副作用：value 输出。
  // 失败/边界：同 read。
  function rdma_status read_qword(rdma_drv_dma mem_buf, int unsigned offset,
                                  output bit [63:0] value);
    rdma_bytes_t bytes;
    rdma_status status;

    status = read(mem_buf, offset, 8, bytes);
    value = rdma_be::qword(bytes, 0);
    return status;
  endfunction

  // 功能：写 notify 窗口寄存器（XTRDMA_PF_NTFE_BAR_OFFSET + 窗口内偏移）。
  // 输入/输出及副作用：转交 BAR 端口。
  // 失败/边界：未绑定返回 INVALID_STATE。
  task notify(bit [63:0] window_offset, bit [63:0] value, output rdma_status status);
    if (bar == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE, "driver BAR is not bound");
      return;
    end
    bar.write64(RDMA_NOTIFY_WINDOW_OFFSET + window_offset, value, status);
  endtask
endclass
