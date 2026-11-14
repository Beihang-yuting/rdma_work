// 目录/层次：外部组件层 adapters/host_mem/rdma_host_mem_pkg.sv。
// 职责：每个 Function 一个 rdma_host_mem 视图，在公共 host_mem_pool 对应 Host 的 manager 上分配并按 Function
//   记账。IOVA = Host 地址（PCIe 上无 IOMMU）；按 IOVA 的读写须落在本 Function 的一次分配内，否则以
//   DMA_TRANSLATION 失败（Function 间 DMA 隔离）。
// 依赖：外部 host_mem_pkg（唯一 manager 类型来源，经 HOST_MEM_ROOT）、rdma_types_pkg。
// 所有权：平台或独立模型拥有公共 pool，pool 唯一持有各 Host manager；本包不再维护 Host 映射或创建 backing。
//   rdma_host_mem 复用 host_mem_view 的非拥有 backing 引用，并拥有自己的分配账。
// 生命周期：创建者在发布视图前绑定 mem，之后禁止替换；pool/manager 必须覆盖全部视图及其未释放分配。

package rdma_host_mem_pkg;
  import uvm_pkg::*;
  import host_mem_pkg::*;
  import rdma_types_pkg::*;
  `include "uvm_macros.svh"

  typedef class rdma_host_mem;
  // RC 接收只借用业务账本；不会为 RDMA 创建第二个 allocator 或 IOVA 映射。
  class rdma_dma_view extends host_mem_view;
    rdma_host_mem	owner;
    // 功能：构造尚未绑定账本的 RC 视图。
    // 输入/输出及副作用：name 传给基类；owner 初始为空，不拥有账本。
    // 失败/边界：owner 和 backing 由 rdma_host_mem 绑定后才允许访问。
    extern function new(string name = "rdma_dma_view");
    // 功能：按 RDMA Function 活分配声明直接 Host 地址。
    // 输入/输出及副作用：addr 为 Host 地址；只检查 owner 账本。
    // 失败/边界：未绑定、已释放或其他 Function 的地址返回 0。
    extern virtual function bit claims_dma_address(bit [63:0] addr);
    // 功能：预检 RDMA 直接 DMA 完整范围。
    // 输入/输出及副作用：addr/size 为 Host 区间；write_access 无额外方向限制，why 返回账本状态。
    // 失败/边界：未绑定、越界或已释放时拒绝，不修改 backing。
    extern virtual function bit validate_dma_access(bit [63:0] addr, int unsigned size,
                                                   bit write_access, output string why);
    // 功能：读取账本保护的 Host 数据供 RC Completion 使用。
    // 输入/输出及副作用：addr/size 为直接地址；data 输出副本，file/line 为调用位置。
    // 失败/边界：无 owner 或账本拒绝时 data 为空，不访问其他 Function。
    extern virtual function void read_mem(bit [63:0] addr, int unsigned size,
                                          ref byte data[], input string file = "", input int line = 0);
    // 功能：写入账本保护的 Host 数据。
    // 输入/输出及副作用：addr/data 更新 owner 的共享 backing；file/line 保留 API 兼容。
    // 失败/边界：未绑定或区间不属于本 Function 时不写入。
    extern virtual function void write_mem(bit [63:0] addr, byte data[], string file = "", int line = 0);
  endclass

  // 按 Function 分账使共享 Host backing 不授予跨 Function 的 DMA 权限。
  // 设计约束：RDMA 访问必须经过本对象的 alloc/free/read/write 账本；公共
  // host_mem_view 只作为 backing 委托层保存，不向调用方发布为 RDMA 地址空间。
  class rdma_host_mem extends uvm_object;
    `uvm_object_utils(rdma_host_mem)

    // 公共 view 只借用 Host backing；mem 是兼容旧调用点的只读语义句柄，始终与
    // backing_view.backing() 同步，RDMA 的 alloc/read/write 仍由本类 ledger 门禁。
    host_mem_view backing_view;
    rdma_dma_view dma_view;
    host_mem_api  mem;

    // 本 Function 的分配：IOVA → 字节数。
    protected int unsigned	sizes[bit [63:0]];

    // 功能：构造未绑定 manager 的视图。
    // 输入/输出及副作用：name 为 UVM 名；mem 初始为 null，sizes 为空且由视图拥有。
    // 失败/边界：绑定前分配返回 INVALID_STATE。
    extern function new(string	name = "rdma_host_mem");

    // 功能：绑定公共 Host backing，供平台在发布 Function 视图前建立唯一引用。
    // 输入/输出及副作用：backing 交给 host_mem_view 记录为非拥有引用；why 输出拒绝原因。
    // 失败/边界：backing 为空或视图已绑定其他对象时返回 0，原绑定保持不变。
    extern function bit bind_host_mem(host_mem_api backing, output string why);

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
    backing_view = new({name, "_view"});
    dma_view = new({name, "_dma"});
    dma_view.owner = this;
    mem = null;
  endfunction

  // 功能：绑定公共 Host backing，供平台在发布 Function 视图前建立唯一引用。
  // 输入/输出及副作用：backing 交给 host_mem_view 记录为非拥有引用；why 输出拒绝原因。
  // 失败/边界：backing 为空或视图已绑定其他对象时返回 0，原绑定保持不变。
  function bit rdma_host_mem::bind_host_mem(host_mem_api backing, output string why);
    if (!backing_view.bind_backing(backing, why))
      return 0;
    if (!dma_view.bind_backing(backing, why))
      return 0;
    mem = backing_view.backing();
    return 1;
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
      backing_view.read_mem(iova, size, data, `__FILE__, `__LINE__);
    return rdma_status::success();
  endfunction

  // 功能：写 [iova, iova+data.size())。
  // 输入/输出及副作用：写 manager 的 backing。
  // 失败/边界：不在本 Function 的单次分配内返回 DMA_TRANSLATION。
  function rdma_status rdma_host_mem::write(bit [63:0]	iova, byte	data[]);
    if (!owns(iova, data.size()))
      return unmapped(iova, data.size());
    backing_view.write_mem(iova, data, `__FILE__, `__LINE__);
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

  // 功能：初始化非拥有的 DMA 账本视图。
  // 输入/输出及副作用：name 交给基类，owner 默认为空。
  // 失败/边界：未绑定 owner 时所有访问拒绝。
  function rdma_dma_view::new(string name = "rdma_dma_view");
    super.new(name);
    owner = null;
  endfunction

  // 功能：查询单字节地址是否属于 RDMA 活分配。
  // 输入/输出及副作用：addr 交给 owner.validate_range，无数据副作用。
  // 失败/边界：owner 为空或账本拒绝返回 0。
  function bit rdma_dma_view::claims_dma_address(bit [63:0] addr);
    rdma_status status;
    if (owner == null) begin
      return 0;
    end
    status = owner.validate_range(addr, 1);
    return status.ok();
  endfunction

  // 功能：验证 RDMA 直接 Host 区间的账本归属。
  // 输入/输出及副作用：addr/size 检查存活分配；write_access 无方向差异，why 返回状态描述。
  // 失败/边界：owner 为空、区间越界、已释放或跨 Function 时拒绝。
  function bit rdma_dma_view::validate_dma_access(bit [63:0] addr, int unsigned size,
                                                  bit write_access, output string why);
    rdma_status status;
    why = "RDMA DMA view has no owner";
    if (owner == null) begin
      return 0;
    end
    status = owner.validate_range(addr, size);
    why = status.ok() ? "" : status.convert2string();
    return status.ok();
  endfunction

  // 功能：读取账本所属 Host 字节供 RC 返回。
  // 输入/输出及副作用：addr/size 交给 owner.read，data 输出拷贝；file/line 不影响业务状态。
  // 失败/边界：无 owner 或权限失败时 data 为空。
  function void rdma_dma_view::read_mem(bit [63:0] addr, int unsigned size,
                                        ref byte data[], input string file = "", input int line = 0);
    data = new[0];
    if (owner != null) void'(owner.read(addr, size, data));
  endfunction

  // 功能：通过业务账本写入 Host 数据。
  // 输入/输出及副作用：addr/data 交给 owner.write；file/line 不改变地址解释。
  // 失败/边界：无 owner 或账本拒绝时不写入 backing。
  function void rdma_dma_view::write_mem(bit [63:0] addr, byte data[], string file = "", int line = 0);
    if (owner != null) void'(owner.write(addr, data));
  endfunction

endpackage
