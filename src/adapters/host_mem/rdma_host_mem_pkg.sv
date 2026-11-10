// 目录/层次：外部组件层 adapters/host_mem/rdma_host_mem_pkg.sv。
// 职责：每个 Function 一个 rdma_host_mem 视图，在公共 host_mem_pool 对应 Host 的 manager 上分配并按 Function
//   记账。IOVA = Host 地址（PCIe 上无 IOMMU）；按 IOVA 的读写须落在本 Function 的一次分配内，否则以
//   DMA_TRANSLATION 失败（Function 间 DMA 隔离）。
// 依赖：外部 host_mem_pkg（唯一 manager 类型来源，经 HOST_MEM_ROOT）、rdma_types_pkg。
// 所有权：平台或独立模型拥有公共 pool，pool 唯一持有各 Host manager；本包不再维护 Host 映射或创建 backing。
//   rdma_host_mem 只借用 manager，拥有自己的分配账。
// 生命周期：创建者在发布视图前绑定 mem，之后禁止替换；pool/manager 必须覆盖全部视图及其未释放分配。

package rdma_host_mem_pkg;
  import uvm_pkg::*;
  import host_mem_pkg::*;
  import rdma_types_pkg::*;
  `include "uvm_macros.svh"

  // 按 Function 分账使共享 Host backing 不授予跨 Function 的 DMA 权限。
  class rdma_host_mem extends uvm_object;
    `uvm_object_utils(rdma_host_mem)

    host_mem_api	mem;
    // 本 Function 的分配：IOVA → 字节数。
    protected int unsigned	sizes[bit [63:0]];

    // 功能：构造未绑定 manager 的视图。
    // 输入/输出及副作用：name 为 UVM 名；mem 初始为 null，sizes 为空且由视图拥有。
    // 失败/边界：绑定前分配返回 INVALID_STATE。
    extern function new(string	name = "rdma_host_mem");

    // 功能：分配 size 字节（align 对齐）并记账。
    // 输入/输出及副作用：size/align 传给 manager；iova 输出地址，成功把 size 记入本视图 sizes。
    // 失败/边界：未绑定返回 INVALID_STATE，size=0 返回 INVALID_ARGUMENT；manager 拒绝分配
    //   返回 RESOURCE_EXHAUSTED；失败 iova=0，align 的合法性由外部 manager 判定。
    extern function rdma_status alloc(int unsigned	size, int unsigned	align, output bit [63:0]	iova);

    // 功能：释放本 Function 在 iova 的分配。
    // 输入/输出及副作用：归还 manager，删除记账。
    // 失败/边界：非本 Function 分配起点（包括重复释放）返回 INVALID_ARGUMENT；成功后旧地址不可读写。
    extern function rdma_status free(bit [63:0]	iova);

    // 功能：读 [iova, iova+size)。
    // 输入/输出及副作用：data 输出副本。
    // 失败/边界：不在本 Function 的单次分配内返回 DMA_TRANSLATION，data 为空。
    extern function rdma_status read(bit [63:0]	iova, int unsigned	size, output byte	data[]);

    // 功能：写 [iova, iova+data.size())。
    // 输入/输出及副作用：写 manager 的 backing。
    // 失败/边界：不在本 Function 的单次分配内返回 DMA_TRANSLATION。
    extern function rdma_status write(bit [63:0]	iova, byte	data[]);

    // 功能：仅检查 DMA 完整区间是否属于本 Function 的单次存活分配。
    // 输入/输出及副作用：iova/size 为待访问区间；返回状态，不读写 manager backing 或改变账本。
    // 失败/边界：mem 为空返回 INVALID_STATE；跨分配、已释放或地址回绕返回 DMA_TRANSLATION；零长度沿用 owns 尾端语义。
    extern function rdma_status validate_range(bit [63:0]	iova, int unsigned	size);

    // 功能：本 Function 当前的分配数。
    // 输入/输出及副作用：返回 sizes.num()，不修改本 Function 或 manager 的状态。
    // 失败/边界：未绑定或尚未分配时返回 0；计数只含本视图账本，不统计同 Host 的其他 Function。
    extern function int unsigned live_allocations();

    // 功能：[iova, iova+n) 是否落在本 Function 的一次分配内。
    // 输入/输出及副作用：按 iova 查找最近分配起点，比较 65 位区间端点；返回 n 字节是否归属本视图。
    // 失败/边界：找不到起始分配返回 0；65 位端点加法拒绝地址回绕，n=0 允许落在分配闭合尾端。
    extern protected function bit owns(bit [63:0]	iova, int unsigned	n);

    // 功能：未映射访问的错误。
    // 输入/输出及副作用：按 iova/n 格式化错误地址，返回新 rdma_status，不访问 manager。
    // 失败/边界：任意 iova/n（含零长度）都生成 RDMA_SC_DMA_TRANSLATION，仅负责格式化而不查询账本。
    extern protected function rdma_status unmapped(bit [63:0]	iova, int unsigned	n);

  endclass

  // 功能：构造未绑定 manager 的视图。
  // 输入/输出及副作用：name 为 UVM 名；mem 初始为 null，sizes 为空且由视图拥有。
  // 失败/边界：绑定前分配返回 INVALID_STATE。
  function rdma_host_mem::new(string	name = "rdma_host_mem");
    super.new(name);
    mem = null;
  endfunction

  // 功能：分配 size 字节（align 对齐）并记账。
  // 输入/输出及副作用：size/align 传给 manager；iova 输出地址，成功把 size 记入本视图 sizes。
  // 失败/边界：未绑定返回 INVALID_STATE，size=0 返回 INVALID_ARGUMENT；manager 拒绝分配
  //   返回 RESOURCE_EXHAUSTED；失败 iova=0，align 的合法性由外部 manager 判定。
  function rdma_status rdma_host_mem::alloc(int unsigned	size, int unsigned	align, output bit [63:0]	iova);
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
  // 失败/边界：非本 Function 分配起点（包括重复释放）返回 INVALID_ARGUMENT；成功后旧地址不可读写。
  function rdma_status rdma_host_mem::free(bit [63:0]	iova);
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
  function rdma_status rdma_host_mem::read(bit [63:0]	iova, int unsigned	size, output byte	data[]);
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
  function rdma_status rdma_host_mem::write(bit [63:0]	iova, byte	data[]);
    if (!owns(iova, data.size()))
      return unmapped(iova, data.size());
    mem.write_mem(iova, data, `__FILE__, `__LINE__);
    return rdma_status::success();
  endfunction

  // 功能：仅检查 DMA 完整区间是否属于本 Function 的单次存活分配。
  // 输入/输出及副作用：iova/size 为待访问区间；返回状态，不读写 manager backing 或改变账本。
  // 失败/边界：mem 为空返回 INVALID_STATE；跨分配、已释放或地址回绕返回 DMA_TRANSLATION；零长度沿用 owns 尾端语义。
  function rdma_status rdma_host_mem::validate_range(bit [63:0]	iova, int unsigned	size);
    if (mem == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "host memory is not bound");
    if (!owns(iova, size))
      return unmapped(iova, size);
    return rdma_status::success();
  endfunction

  // 功能：本 Function 当前的分配数。
  // 输入/输出及副作用：返回 sizes.num()，不修改本 Function 或 manager 的状态。
  // 失败/边界：未绑定或尚未分配时返回 0；计数只含本视图账本，不统计同 Host 的其他 Function。
  function int unsigned rdma_host_mem::live_allocations();
    return sizes.num();
  endfunction

  // 功能：[iova, iova+n) 是否落在本 Function 的一次分配内。
  // 输入/输出及副作用：按 iova 查找最近分配起点，比较 65 位区间端点；返回 n 字节是否归属本视图。
  // 失败/边界：找不到起始分配返回 0；65 位端点加法拒绝地址回绕，n=0 允许落在分配闭合尾端。
  function bit rdma_host_mem::owns(bit [63:0]	iova, int unsigned	n);
    bit [63:0]	base;

    base = iova;
    if (!sizes.exists(base) && !sizes.prev(base))
      return 1'b0;
    return {1'b0, iova} + n <= {1'b0, base} + sizes[base];
  endfunction

  // 功能：未映射访问的错误。
  // 输入/输出及副作用：按 iova/n 格式化错误地址，返回新 rdma_status，不访问 manager。
  // 失败/边界：任意 iova/n（含零长度）都生成 RDMA_SC_DMA_TRANSLATION，仅负责格式化而不查询账本。
  function rdma_status rdma_host_mem::unmapped(bit [63:0]	iova, int unsigned	n);
    return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                             $sformatf("IOVA %016h+%0d is not mapped", iova, n));
  endfunction

endpackage
