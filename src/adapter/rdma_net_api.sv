// 目录：适配器接口层 adapter/rdma_net_api.sv。
// 职责：实现 rdma_net_api 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_net_api.sv 属于适配器接口层，定义主机内存、PCIe、网络及上下文后端接口。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

virtual class rdma_net_observer extends uvm_object;

  // 功能：构造 rdma_net_observer，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_net_observer 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_net_observer");
    super.new(name);
  endfunction

  // 功能：在 rdma_net_observer 中，write 把请求数据写入指定后端并保留返回状态；只有写入成功才允许本地游标继续推进。
  // 输入/输出及副作用：packet（输入）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过 output 返回结果。
  // 失败/边界：write 遇到后端拒绝、范围溢出或 DMA 权限不足时保留失败证据，不推进本地游标。
  pure virtual function void write(rdma_packet packet);
endclass

virtual class rdma_net_api extends uvm_object;

  // 功能：构造 rdma_net_api，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_net_api 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_net_api");
    super.new(name);
  endfunction

  // 功能：在 rdma_net_api 中，send_packet 推进队列/事务游标或执行对应 I/O，并把结果写回声明的输出参数。
  // 输入/输出及副作用：packet（输入）、status（输出）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过
  //   output 返回结果。
  // 失败/边界：队列未激活、credit 不足、请求身份过期或后端写入失败时返回错误；不得提前推进游标或重复提交。
  pure virtual task send_packet(
    rdma_packet packet,
    output rdma_status status
  );

  // 功能：在 rdma_net_api 中，receive_packet 推进队列/事务游标或执行对应 I/O，并把结果写回声明的输出参数。
  // 输入/输出及副作用：packet（输出）、status（输出）；receive_packet 驱动下游事务，并写入 packet、status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：receive_packet 失败或超时通过 packet、status 明确发布；该路径不隐式重试，也不转移未声明资源。
  pure virtual task receive_packet(
    output rdma_packet packet,
    output rdma_status status
  );

  // 功能：在 rdma_net_api 中，register_observer 把 register_observer 指定的资源或后端能力绑定到当前对象索引，并校验 Function、generation 和队列类型一致。
  // 输入/输出及副作用：observer（输入）；register_observer 先依据 依赖存在性、authority 和 generation 条件 校验 observer；成功时更新本对象配置/状态并保存非拥有引用，返回 void。
  // 失败/边界：资源不存在、类型不符、重复登记或跨 Function 串线时拒绝绑定并保持索引不变。
  pure virtual function void register_observer(rdma_net_observer observer);

  // 功能：在 rdma_net_api 中，configure_response_policy 校验依赖和 binding 后建立运行边界，只保存非拥有引用并拒绝重复配置。
  // 输入/输出及副作用：policy（输入）；configure_response_policy 先依据 依赖存在性、authority 和 generation 条件 校验 policy；成功时更新本对象配置/状态并保存非拥有引用，返回 rdma_status。
  // 失败/边界：实现中的空依赖、重复登记、状态或 generation/authority 校验失败时返回错误；失败时保留旧配置。
  pure virtual function rdma_status configure_response_policy(
    rdma_net_response_policy policy
  );

  // 功能：在 rdma_net_api 中，inject_fault 将 fault 注入请求交给网络适配器的故障注入通道，供恢复测试观察确定的错误路径。
  // 输入/输出及副作用：fault（输入）；inject_fault 读取 fault.kind、fault.function_uid 和 fault.resource_id，不修改调用方对象；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：inject_fault 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  pure virtual function rdma_status inject_fault(rdma_net_fault fault);
endclass
