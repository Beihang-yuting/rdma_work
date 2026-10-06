// 目录：测试层 mocks/rdma_mock_host_mem.sv。
// 层：测试替身。
// 职责：单元测试用主机内存：每个实例是一个独立 IOVA 域（不同实例可复用相同 IOVA 数值），按对齐
//   顺序分配 mapping，提供 mapping 内读写、设备按 IOVA 的 DMA 解析与释放。
// 依赖：rdma_host_mem_api、rdma_dma_mapping。
// 所有权：实例拥有全部 backing 字节；mapping 交给调用方，释放后不可再访问。
// 生命周期：随测试存在。
class rdma_mock_host_mem extends rdma_host_mem_api;
  `uvm_object_utils(rdma_mock_host_mem)

  localparam bit [63:0] IOVA_BASE = 64'h0000_0001_0000_0000;

  protected rdma_dma_mapping maps[$];
  protected byte unsigned store[$][];
  protected bit [63:0] next_iova;

  // 功能：构造空 IOVA 域。
  // 输入/输出及副作用：name 为 UVM 名。
  // 失败/边界：无。
  function new(string name = "rdma_mock_host_mem");
    super.new(name);
    next_iova = IOVA_BASE;
  endfunction

  // 功能：分配 size 字节（alignment 为 2 的幂），返回 ACTIVE mapping（IOVA = backing 地址）。
  // 输入/输出及副作用：mapping 输出；追加记录。
  // 失败/边界：size 为 0 或 alignment 非 2 的幂返回 INVALID_ARGUMENT。
  virtual function rdma_status allocate(rdma_dma_request_context request_context,
                                        int unsigned size, int unsigned alignment,
                                        rdma_dma_direction_e direction,
                                        output rdma_dma_mapping mapping);
    byte unsigned bytes[];
    bit [63:0] align;

    mapping = null;
    if (size == 0 || alignment == 0 || (alignment & (alignment - 1)) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "invalid allocation size or alignment");
    align = alignment;
    next_iova = (next_iova + align - 1) & ~(align - 1);
    mapping = rdma_dma_mapping::type_id::create($sformatf("mock_map_%0d", maps.size()));
    if (request_context != null)
      mapping.function_h = request_context.function_h;
    mapping.iova.value = next_iova;
    mapping.backing_addr.value = next_iova;
    mapping.size = size;
    mapping.direction = direction;
    mapping.state = RDMA_MAPPING_ACTIVE;
    next_iova += size;
    bytes = new[size];
    maps.push_back(mapping);
    store.push_back(bytes);
    return rdma_status::success();
  endfunction

  // 功能：写 mapping 的 offset 处。
  // 输入/输出及副作用：写 backing。
  // 失败/边界：mapping 未知/已释放或越界返回 INVALID_ARGUMENT。
  virtual function rdma_status write(rdma_dma_mapping mapping, longint unsigned offset,
                                     byte data[]);
    int idx;

    idx = locate(mapping, offset, data.size());
    if (idx < 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "write outside a live mapping");
    foreach (data[i])
      store[idx][offset + i] = data[i];
    return rdma_status::success();
  endfunction

  // 功能：读 mapping 的 offset 处 size 字节。
  // 输入/输出及副作用：data 输出副本。
  // 失败/边界：mapping 未知/已释放或越界返回 INVALID_ARGUMENT。
  virtual function rdma_status read(rdma_dma_mapping mapping, longint unsigned offset,
                                    int unsigned size, output byte data[]);
    int idx;

    data = new[0];
    idx = locate(mapping, offset, size);
    if (idx < 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "read outside a live mapping");
    data = new[size];
    foreach (data[i])
      data[i] = store[idx][offset + i];
    return rdma_status::success();
  endfunction

  // 功能：释放 mapping（state 置 RELEASED，backing 丢弃）。
  // 输入/输出及副作用：改 mapping 状态。
  // 失败/边界：未知或已释放返回 INVALID_ARGUMENT。
  virtual function rdma_status \release (rdma_dma_mapping mapping);
    int idx;

    idx = locate(mapping, 0, 0);
    if (idx < 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "release of an unknown mapping");
    mapping.state = RDMA_MAPPING_RELEASED;
    store[idx] = new[0];
    return rdma_status::success();
  endfunction

  // 功能：设备 DMA 地址解析：找到完整覆盖 [iova, iova+size) 的 ACTIVE mapping。
  // 输入/输出及副作用：mapping/offset 输出。
  // 失败/边界：不在本域任何 ACTIVE mapping 内返回 DMA_TRANSLATION。
  virtual function rdma_status find_iova(bit [63:0] iova, int unsigned size,
                                         output rdma_dma_mapping mapping,
                                         output longint unsigned offset);
    mapping = null;
    offset = 0;
    foreach (maps[i]) begin
      if (maps[i].state != RDMA_MAPPING_ACTIVE || iova < maps[i].iova.value ||
          iova + size > maps[i].iova.value + maps[i].size)
        continue;
      mapping = maps[i];
      offset = iova - maps[i].iova.value;
      return rdma_status::success();
    end
    return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                             $sformatf("IOVA %016h+%0d is not mapped", iova, size));
  endfunction

  // 功能：当前 ACTIVE mapping 数。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
  function int unsigned live_allocations();
    int unsigned count;

    count = 0;
    foreach (maps[i])
      if (maps[i].state == RDMA_MAPPING_ACTIVE)
        count++;
    return count;
  endfunction

  // 功能：mapping 的记录下标（须 ACTIVE 且 [offset, offset+size) 在范围内）。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：不满足返回 -1。
  protected function int locate(rdma_dma_mapping mapping, longint unsigned offset,
                                longint unsigned size);
    foreach (maps[i])
      if (maps[i] == mapping)
        return (mapping.state == RDMA_MAPPING_ACTIVE && offset + size <= mapping.size) ? i : -1;
    return -1;
  endfunction
endclass
