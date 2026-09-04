// 目录：适配器接口层 adapter/rdma_function_table_api.sv。
// 职责：实现 rdma_function_table_api 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_function_table_api.sv 属于适配器接口层，定义主机内存、PCIe、网络及上下文后端接口。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

virtual class rdma_function_table_api extends uvm_object;

  // 功能：构造 rdma_function_table_api，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_function_table_api 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_function_table_api");
    super.new(name);
  endfunction

  // 功能：在 rdma_function_table_api 中，program_notify 把 program_notify 的配置/编程请求提交到后端适配器，并返回后端确认状态。
  // 输入/输出及副作用：binding（输入）、status（输出）；program_notify 驱动下游事务，并写入 status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：program_notify 遇到后端拒绝、范围溢出或 DMA 权限不足时保留失败证据，不推进本地游标。
  pure virtual task program_notify(
    rdma_function_binding binding,
    output rdma_status status
  );

  // 功能：在 rdma_function_table_api 中，clear_notify 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：binding（输入）、status（输出）；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：clear_notify 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  pure virtual task clear_notify(
    rdma_function_binding binding,
    output rdma_status status
  );

  // 功能：在 rdma_function_table_api 中，program_dmi 把 program_dmi 的配置/编程请求提交到后端适配器，并返回后端确认状态。
  // 输入/输出及副作用：binding（输入）、status（输出）；program_dmi 驱动下游事务，并写入 status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：program_dmi 遇到后端拒绝、范围溢出或 DMA 权限不足时保留失败证据，不推进本地游标。
  pure virtual task program_dmi(
    rdma_function_binding binding,
    output rdma_status status
  );

  // 功能：在 rdma_function_table_api 中，clear_dmi 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：binding（输入）、status（输出）；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：clear_dmi 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  pure virtual task clear_dmi(
    rdma_function_binding binding,
    output rdma_status status
  );

  // 功能：在 rdma_function_table_api 中，program_vft 把 program_vft 的配置/编程请求提交到后端适配器，并返回后端确认状态。
  // 输入/输出及副作用：binding（输入）、status（输出）；program_vft 驱动下游事务，并写入 status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：program_vft 遇到后端拒绝、范围溢出或 DMA 权限不足时保留失败证据，不推进本地游标。
  pure virtual task program_vft(
    rdma_function_binding binding,
    output rdma_status status
  );

  // 功能：在 rdma_function_table_api 中，clear_vft 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：binding（输入）、status（输出）；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：clear_vft 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  pure virtual task clear_vft(
    rdma_function_binding binding,
    output rdma_status status
  );
endclass
