// 目录：外部组件层 adapters/host_mem/rdma_host_mem_pkg.sv。
// 职责：直接使用外部 host_mem 作主机内存：每个 Host 一个 host_mem_manager（rdma_host_mems 建立，地址区间
//   按 Host 错开）；每个 Function 一个 rdma_host_mem 视图，在所属 Host 的 manager 上分配并按 Function
//   记账。IOVA = Host 地址（PCIe 上无 IOMMU）；按 IOVA 的读写须落在本 Function 的一次分配内，否则以
//   DMA_TRANSLATION 失败（Function 间 DMA 隔离）。
// 依赖：外部 host_mem（host_mem_pkg 与 host_mem_manager.sv，经 HOST_MEM_ROOT）、rdma_types_pkg。
// 所有权：rdma_host_mems 拥有各 Host 的 manager；rdma_host_mem 只借用 manager，拥有自己的分配账。
// 生命周期：随仿真存在。

package rdma_host_mem_pkg;
  import uvm_pkg::*;
  import host_mem_pkg::*;
  import rdma_types_pkg::*;
  `include "uvm_macros.svh"
  // 外部 host_mem_manager 以 compilation-unit 文件提供；包进本 package 只改变可见域，不复制源码。
  `include "host_mem_manager.sv"

  // 一个 Function 的主机内存视图。
  class rdma_host_mem extends uvm_object;
    `uvm_object_utils(rdma_host_mem)

    host_mem_api mem;
    // 本 Function 的分配：IOVA → 字节数。
    protected int unsigned sizes[bit [63:0]];

    // 功能：构造未绑定 manager 的视图。
    // 输入/输出及副作用：name 为 UVM 名。
    // 失败/边界：绑定前分配返回 INVALID_STATE。
    function new(string name = "rdma_host_mem");
      super.new(name);
      mem = null;
    endfunction

    // 功能：分配 size 字节（align 对齐）并记账。
    // 输入/输出及副作用：iova 输出。
    // 失败/边界：未绑定、size 为 0 或空间不足返回错误，iova 为 0。
    function rdma_status alloc(int unsigned size, int unsigned align, output bit [63:0] iova);
      iova = '0;
      if (mem == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE, "host memory is not bound");
      if (size == 0)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "zero-byte host allocation");
      iova = mem.alloc(size, align, `__FILE__, `__LINE__);
      if (iova == '1) begin
        iova = '0;
        return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED, "host memory is exhausted");
      end
      sizes[iova] = size;
      return rdma_status::success();
    endfunction

    // 功能：释放本 Function 在 iova 的分配。
    // 输入/输出及副作用：归还 manager，删除记账。
    // 失败/边界：不是本 Function 的分配返回 INVALID_ARGUMENT。
    function rdma_status free(bit [63:0] iova);
      if (!sizes.exists(iova))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 $sformatf("free of unknown host allocation %016h", iova));
      mem.free(iova, `__FILE__, `__LINE__);
      sizes.delete(iova);
      return rdma_status::success();
    endfunction

    // 功能：读 [iova, iova+size)。
    // 输入/输出及副作用：data 输出副本。
    // 失败/边界：不在本 Function 的单次分配内返回 DMA_TRANSLATION，data 为空。
    function rdma_status read(bit [63:0] iova, int unsigned size, output byte data[]);
      data = new[0];
      if (!owns(iova, size))
        return unmapped(iova, size);
      if (size != 0)
        mem.read_mem(iova, size, data, `__FILE__, `__LINE__);
      return rdma_status::success();
    endfunction

    // 功能：写 [iova, iova+data.size())。
    // 输入/输出及副作用：写 manager 的 backing。
    // 失败/边界：不在本 Function 的单次分配内返回 DMA_TRANSLATION。
    function rdma_status write(bit [63:0] iova, byte data[]);
      if (!owns(iova, data.size()))
        return unmapped(iova, data.size());
      mem.write_mem(iova, data, `__FILE__, `__LINE__);
      return rdma_status::success();
    endfunction

    // 功能：本 Function 当前的分配数。
    // 输入/输出及副作用：纯查询。
    // 失败/边界：无。
    function int unsigned live_allocations();
      return sizes.num();
    endfunction

    // 功能：[iova, iova+n) 是否落在本 Function 的一次分配内。
    // 输入/输出及副作用：纯查询。
    // 失败/边界：无。
    protected function bit owns(bit [63:0] iova, int unsigned n);
      bit [63:0] base;

      base = iova;
      if (!sizes.exists(base) && !sizes.prev(base))
        return 1'b0;
      return {1'b0, iova} + n <= {1'b0, base} + sizes[base];
    endfunction

    // 功能：未映射访问的错误。
    // 输入/输出及副作用：纯函数。
    // 失败/边界：无。
    protected function rdma_status unmapped(bit [63:0] iova, int unsigned n);
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               $sformatf("IOVA %016h+%0d is not mapped", iova, n));
    endfunction
  endclass

  // 各 Host 的 host_mem manager 与 Function 视图的工厂。
  class rdma_host_mems extends uvm_object;
    `uvm_object_utils(rdma_host_mems)

    localparam bit [63:0] REGION_BASE = 64'h0000_0040_0000_0000;
    localparam bit [63:0] REGION_STRIDE = 64'h0000_0001_0000_0000;
    localparam bit [63:0] REGION_BYTES = 64'h0000_0000_1000_0000;

    host_mem_api managers[int unsigned];

    // 功能：构造。
    // 输入/输出及副作用：name 为 UVM 名。
    // 失败/边界：无。
    function new(string name = "rdma_host_mems");
      super.new(name);
    endfunction

    // 功能：Host host 上一个 Function 的内存视图（Host 的 manager 首次使用时建立，区间 256 MiB）。
    // 输入/输出及副作用：可能新建 manager；返回新视图。
    // 失败/边界：无。
    function rdma_host_mem make(int unsigned host, string name);
      host_mem_manager manager;
      rdma_host_mem view;

      if (!managers.exists(host)) begin
        manager = host_mem_manager::type_id::create($sformatf("host_mem%0d", host));
        manager.init_region(REGION_BASE + host * REGION_STRIDE,
                            REGION_BASE + host * REGION_STRIDE + REGION_BYTES - 1, MODE_BUDDY, 16);
        manager.set_host_id(host);
        managers[host] = manager;
      end
      view = rdma_host_mem::type_id::create(name);
      view.mem = managers[host];
      return view;
    endfunction
  endclass
endpackage
