// 目录：适配器接口层 adapter/rdma_host_mem_api.sv。
// 职责：实现 rdma_host_mem_api 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_host_mem_api.sv 属于适配器接口层，定义主机内存、PCIe、网络及上下文后端接口。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

virtual class rdma_host_mem_api extends uvm_object;

  // 功能：构造 rdma_host_mem_api，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_host_mem_api 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_host_mem_api");
    super.new(name);
  endfunction

  // 功能：在 rdma_host_mem_api 中，allocate 检查容量后预留资源并返回带 owner 证据的句柄/计划；失败时回滚已登记的局部状态。
  // 输入/输出及副作用：request_context（输入）、size（输入）、alignment（输入）、direction（输入）、mapping（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或
  //   output 发布新句柄/映射，且成功返回时 mapping 必须为非空的 opaque allocation identity。
  // 失败/边界：容量不足、范围非法、重复占用或身份过期时返回错误；失败不得泄漏半分配资源。
  //   实现若返回 success，则不得保留一个未通过 mapping 暴露的 allocation；success+null
  //   属于 adapter contract violation，调用方必须拒绝该结果并报告 INVALID_STATE。
  pure virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );

  // 功能：在 rdma_host_mem_api 中，write 把请求数据写入指定后端并保留返回状态；只有写入成功才允许本地游标继续推进。
  // 输入/输出及副作用：mapping（输入）、offset（输入）、data（输入）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending
  //   journal，并通过 output 返回结果。
  // 失败/边界：write 遇到后端拒绝、范围溢出或 DMA 权限不足时保留失败证据，不推进本地游标。
  pure virtual function rdma_status write(
    rdma_dma_mapping mapping,
    longint unsigned offset,
    byte data[]
  );

  // 功能：在 rdma_host_mem_api 中，read 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：mapping（输入）、offset（输入）、size（输入）、data（输出）；输入 handle/key/cursor 用于选择读取范围；返回值或 output 为 detached
  //   快照，读取不取得外部资源所有权。
  // 失败/边界：read 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  pure virtual function rdma_status read(
    rdma_dma_mapping mapping,
    longint unsigned offset,
    int unsigned size,
    output byte data[]
  );

  // 功能：在 rdma_host_mem_api 中，release 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：mapping（输入）；输入 handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：release 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  pure virtual function rdma_status \release (rdma_dma_mapping mapping);

  // 功能：release_opaque 在调用方发现 public mapping 字段异常时，仍使用
  //       manager 内部的不透明 allocation identity 完成一次回滚释放。
  // 输入/输出及副作用：mapping（输入）；成功时释放 manager 所拥有的 backing，
  //       不依赖调用方可修改的 route/geometry 字段；不改变 router 自身账本。
  // 失败/边界：默认实现回退到普通 release()，具体 manager 若维护独立 token/identity
  //       应覆盖本函数；mapping 为空、token 不存在或释放失败时返回明确错误。
  virtual function rdma_status release_opaque(rdma_dma_mapping mapping);
    return \release (mapping);
  endfunction
endclass
