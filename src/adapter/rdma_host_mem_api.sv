// 目录：适配器接口层 adapter/rdma_host_mem_api.sv。
// 职责：实现 rdma_host_mem_api 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。
virtual class rdma_host_mem_api extends uvm_object;

  // 功能：规范化 UMEM/PBL 下游返回的状态，null 转为 INVALID_STATE。
  // 输入/输出及副作用：operation 用作诊断前缀；非空状态原样返回。
  // 失败/边界：null 违反状态返回契约，调用方应停止读取 output 并清理本地半成品。
  protected function automatic rdma_status normalize_status(
    rdma_status candidate,
    string operation
  );
    return rdma_adapter_status_policy::normalize(
      candidate, "Host-memory", operation
    );
  endfunction

  // 功能：构造 Host-memory API 基对象。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无。
  function new(string name = "rdma_host_mem_api");
    super.new(name);
  endfunction

  // 功能：按 size/alignment/direction 分配资源并返回 opaque mapping。
  // 输入/输出及副作用：mapping 输出新分配的 allocation identity；成功时必须非空。
  // 失败/边界：容量不足、范围非法或身份过期返回错误且不泄漏半分配资源；success+null 属
  //   adapter contract violation，调用方应按 INVALID_STATE 拒绝。
  pure virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );

  // 功能：把 data 写入 mapping 的 offset 处。
  // 输入/输出及副作用：成功才允许调用方推进本地游标。
  // 失败/边界：后端拒绝、范围溢出或 DMA 权限不足时返回错误，不推进游标。
  pure virtual function rdma_status write(
    rdma_dma_mapping mapping,
    longint unsigned offset,
    byte data[]
  );

  // 功能：读取 mapping 中 offset 起 size 字节，返回 detached 快照。
  // 输入/输出及副作用：data 输出为拷贝，不取得外部资源所有权。
  // 失败/边界：mapping 缺失、范围非法或 generation/reset epoch 过期时返回错误。
  pure virtual function rdma_status read(
    rdma_dma_mapping mapping,
    longint unsigned offset,
    int unsigned size,
    output byte data[]
  );

  // 功能：按 owner/generation/幂等规则释放 mapping 并删除账本引用。
  // 输入/输出及副作用：成功时更新账本与生命周期，外部资源按 adapter 契约释放。
  // 失败/边界：owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果。
  pure virtual function rdma_status \release (rdma_dma_mapping mapping);

  // 功能：设备侧 DMA 的地址解析：找到完整覆盖 [iova, iova+size) 的 ACTIVE 映射。
  // 输入/输出及副作用：mapping/offset 输出；只读账本。
  // 失败/边界：基类不认识设备地址，返回 UNSUPPORTED_OPCODE；具体 host_mem 覆盖。
  virtual function rdma_status find_iova(
    bit [63:0] iova,
    int unsigned size,
    output rdma_dma_mapping mapping,
    output longint unsigned offset
  );
    mapping = null;
    offset = 0;
    return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                             "Host-memory manager does not resolve device IOVA");
  endfunction

  // 功能：设备按 IOVA 读取主机内存（等价 PCIe DMA read）。
  // 输入/输出及副作用：data 输出；不改账本。
  // 失败/边界：地址未落在单个 ACTIVE 映射内返回 find_iova 的错误。
  virtual function rdma_status dma_read(bit [63:0] iova, int unsigned size, output byte data[]);
    rdma_dma_mapping mapping;
    longint unsigned offset;
    rdma_status status;

    data = new[0];
    status = find_iova(iova, size, mapping, offset);
    if (!status.ok())
      return status;
    return read(mapping, offset, size, data);
  endfunction

  // 功能：设备按 IOVA 写主机内存（等价 PCIe DMA write）。
  // 输入/输出及副作用：写 backing。
  // 失败/边界：地址未落在单个 ACTIVE 映射内返回 find_iova 的错误。
  virtual function rdma_status dma_write(bit [63:0] iova, byte data[]);
    rdma_dma_mapping mapping;
    longint unsigned offset;
    rdma_status status;

    status = find_iova(iova, data.size(), mapping, offset);
    if (!status.ok())
      return status;
    return write(mapping, offset, data);
  endfunction

  // 功能：只读确认指定 allocation 的 release 满足 failure-atomic 契约。
  // 输入/输出及副作用：基类不访问 backing，不改 ledger。
  // 失败/边界：基类无法证明 release 顺序，始终返回 UNSUPPORTED_OPCODE（fail closed）。
  virtual function rdma_status validate_failure_atomic_release(
    rdma_dma_mapping mapping
  );
    return rdma_status::make(
      RDMA_SC_UNSUPPORTED_OPCODE,
      "Host-memory manager does not advertise failure-atomic release"
    );
  endfunction

  // 功能：用 manager 内部的不透明 allocation identity 做回滚释放。
  // 输入/输出及副作用：成功时释放 manager 拥有的 backing，不依赖调用方可改的 route/geometry。
  // 失败/边界：默认回退到 release()；有独立 token 的 manager 应覆盖；mapping 为空或 token
  //   不存在时返回错误。
  virtual function rdma_status release_opaque(rdma_dma_mapping mapping);
    return \release (mapping);
  endfunction

  // ABI v5 生命周期约束：mapping 的 release 只能由 owned record 触发一次；
  // borrowed mapping 的所有权仍留在外部 host-mem manager。
endclass
