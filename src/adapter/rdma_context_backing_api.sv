// 目录：适配器接口层 adapter/rdma_context_backing_api.sv。
// 职责：实现 rdma_context_backing_api 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_context_backing_api.sv 属于适配器接口层，定义主机内存、PCIe、网络及上下文后端接口；
//   read 是可选的 host-visible runtime shadow 观察能力，不改变原有生命周期 ABI。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

virtual class rdma_context_backing_api extends uvm_object;

  // 功能：构造 rdma_context_backing_api，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_context_backing_api 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_context_backing_api");
    super.new(name);
  endfunction

  // 功能：在 rdma_context_backing_api 中，acquire 检查容量后预留资源并返回带 owner 证据的句柄/计划；失败时回滚已登记的局部状态。
  // 输入/输出及副作用：binding（输入）、resource_kind（输入）、local_id（输入）、context_ref（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或 output
  //   发布新句柄/映射。
  // 失败/边界：容量不足、范围非法、重复占用或身份过期时返回错误；失败不得泄漏半分配资源。
  pure virtual function rdma_status acquire(
    rdma_function_binding binding,
    rdma_resource_kind_e resource_kind,
    int unsigned local_id,
    output rdma_context_backing_ref context_ref
  );

  // RDMA_RESOURCE_QP uses the same stable contract: acquire returns an opaque
  // control-plane-owned 512-byte, 512-byte-aligned QPC slot authority.  The
  // four method signatures intentionally remain shared with CQ/SRQ backing.

  // 功能：在 rdma_context_backing_api 中，write 把请求数据写入指定后端并保留返回状态；只有写入成功才允许本地游标继续推进。
  // 输入/输出及副作用：context_ref（输入）、offset（输入）、data（输入）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending
  //   journal，并通过 output 返回结果。
  // 失败/边界：write 遇到后端拒绝、范围溢出或 DMA 权限不足时保留失败证据，不推进本地游标。
  pure virtual function rdma_status write(
    rdma_context_backing_ref context_ref,
    longint unsigned offset,
    byte unsigned data[]
  );

  // 功能：read 从指定 context backing 读取固定范围的 host-visible bytes，供
  //   QPC runtime shadow 等硬件写回观察路径使用；默认实现不宣称所有 context
  //   adapter 都具备读能力。
  // 输入/输出及副作用：context_ref、offset、size 为输入，data 为输出；成功时
  //   data 是 detached byte 快照，不修改 context authority、生命周期或 owner。
  // 失败/边界：基类默认返回 UNSUPPORTED_OPCODE 且 data 为空；具体 adapter 必须
  //   自行校验完整 handle/generation、范围和释放状态，不能把缺失读能力伪装成零。
  virtual function rdma_status read(
    rdma_context_backing_ref context_ref,
    longint unsigned offset,
    int unsigned size,
    output byte unsigned data[]
  );
    data = new[0];
    return rdma_status::make(
      RDMA_SC_UNSUPPORTED_OPCODE,
      "context backing read is not supported by this adapter"
    );
  endfunction

  // 功能：在 rdma_context_backing_api 中，release 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：context_ref（输入）；输入 handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：release 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  pure virtual function rdma_status \release (rdma_context_backing_ref context_ref);

  // 功能：在 rdma_context_backing_api 中，query_release_completion 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：context_ref（输入）、complete（输出）；query_release_completion 读取 context_ref 的 mapping、release_authority 和 release_complete，并写入 complete；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：query_release_completion 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  pure virtual function rdma_status query_release_completion(
    rdma_context_backing_ref context_ref,
    output bit complete
  );

  // ABI v5 生命周期约束：context backing 的 acquire/release 由 ABI adapter
  // 以完整 Function snapshot 调用；borrowed context 只登记引用，不调用 release。
endclass
