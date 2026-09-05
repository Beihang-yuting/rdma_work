// 目录：测试层 mocks/rdma_mock_adapters.sv。
// 职责：验证 rdma_mock_adapters 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_mock_adapters.sv 属于测试替身，为单元测试提供可控的适配器和控制面行为。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

// 功能：在 rdma_mock_adapters 中，rdma_mock_clone_status 为 mock trace 深拷贝输入对象，防止被测代码后续修改影响已记录的调用证据。
// 输入/输出及副作用：source（输入）；rdma_mock_clone_status 读取 source 并使用字段 result、result.category、result.code、result.hardware_code、result.hardware_code_valid、result.source_engine、result.function_uid、result.generation；函数返回 rdma_status，不取得调用方资源所有权。
// 失败/边界：rdma_mock_clone_status 输入对象为空或查找未命中时返回 null；该路径不隐式重试，也不转移未声明资源。
function automatic rdma_status rdma_mock_clone_status(rdma_status source);
  rdma_status result;

  if (source == null)
    return null;
  result = rdma_status::type_id::create("mock_status_copy");
  result.category = source.category;
  result.code = source.code;
  result.hardware_code = source.hardware_code;
  result.hardware_code_valid = source.hardware_code_valid;
  result.source_engine = source.source_engine;
  result.function_uid = source.function_uid;
  result.generation = source.generation;
  result.resource_id = source.resource_id;
  result.command_id = source.command_id;
  result.wr_id = source.wr_id;
  result.severity = source.severity;
  result.retryable = source.retryable;
  result.message = source.message;
  return result;
endfunction

class rdma_mock_call_trace extends uvm_object;
  `uvm_object_utils(rdma_mock_call_trace)

  string calls[$];

  // 功能：构造 rdma_mock_call_trace，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_mock_call_trace 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_mock_call_trace");
    super.new(name);
    calls.delete();
  endfunction

  // 功能：在 rdma_mock_call_trace 中，record 记录 record 的调用名称和顺序，供测试断言转发路径；不改变被测事务业务结果。
  // 输入/输出及副作用：method_name（输入）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过 output
  //   返回结果。
  // 失败/边界：记录操作仅影响测试 trace；不得因注入记录故障改变生产状态或吞掉真实错误。
  function void record(string method_name);
    calls.push_back(method_name);
  endfunction

  // 功能：在 rdma_mock_call_trace 中，clear 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：无显式参数；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：clear 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  function void clear();
    calls.delete();
  endfunction
endclass

// 功能：在 rdma_mock_call_trace 中，rdma_mock_clone_function_handle 为 mock trace 深拷贝输入对象，防止被测代码后续修改影响已记录的调用证据。
// 输入/输出及副作用：source（输入）；rdma_mock_clone_function_handle 读取 source 并使用字段 cloned_object；函数返回 rdma_function_handle，不取得调用方资源所有权。
// 失败/边界：rdma_mock_clone_function_handle 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（function handle clone type mismatch），不保留部分有效快照。
function automatic rdma_function_handle rdma_mock_clone_function_handle(
  rdma_function_handle source
);
  uvm_object cloned_object;
  rdma_function_handle result;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(result, cloned_object))
    `uvm_fatal("MOCK_COPY", "function handle clone type mismatch")
  return result;
endfunction

// 功能：在 rdma_mock_call_trace 中，rdma_mock_clone_dma_context 为 mock trace 深拷贝输入对象，防止被测代码后续修改影响已记录的调用证据。
// 输入/输出及副作用：source（输入）；rdma_mock_clone_dma_context 读取 source 并使用字段 cloned_object；函数返回 rdma_dma_request_context，不取得调用方资源所有权。
// 失败/边界：rdma_mock_clone_dma_context 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（DMA request context clone type mismatch），不保留部分有效快照。
function automatic rdma_dma_request_context rdma_mock_clone_dma_context(
  rdma_dma_request_context source
);
  uvm_object cloned_object;
  rdma_dma_request_context result;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(result, cloned_object))
    `uvm_fatal("MOCK_COPY", "DMA request context clone type mismatch")
  return result;
endfunction

// 功能：在 rdma_mock_call_trace 中，rdma_mock_clone_mapping 为 mock trace 深拷贝输入对象，防止被测代码后续修改影响已记录的调用证据。
// 输入/输出及副作用：source（输入）；rdma_mock_clone_mapping 读取 source 并使用字段 cloned_object；函数返回 rdma_dma_mapping，不取得调用方资源所有权。
// 失败/边界：rdma_mock_clone_mapping 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（DMA mapping clone type mismatch），不保留部分有效快照。
function automatic rdma_dma_mapping rdma_mock_clone_mapping(
  rdma_dma_mapping source
);
  uvm_object cloned_object;
  rdma_dma_mapping result;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(result, cloned_object))
    `uvm_fatal("MOCK_COPY", "DMA mapping clone type mismatch")
  return result;
endfunction

// 功能：在 rdma_mock_call_trace 中，rdma_mock_clone_binding 为 mock trace 深拷贝输入对象，防止被测代码后续修改影响已记录的调用证据。
// 输入/输出及副作用：source（输入）；rdma_mock_clone_binding 读取 source 并使用字段 cloned_object；函数返回 rdma_function_binding，不取得调用方资源所有权。
// 失败/边界：rdma_mock_clone_binding 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（function binding clone type mismatch），不保留部分有效快照。
function automatic rdma_function_binding rdma_mock_clone_binding(
  rdma_function_binding source
);
  uvm_object cloned_object;
  rdma_function_binding result;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(result, cloned_object))
    `uvm_fatal("MOCK_COPY", "function binding clone type mismatch")
  return result;
endfunction

// 功能：在 rdma_mock_call_trace 中，rdma_mock_clone_packet 为 mock trace 深拷贝输入对象，防止被测代码后续修改影响已记录的调用证据。
// 输入/输出及副作用：source（输入）；rdma_mock_clone_packet 读取 source 并使用字段 cloned_object；函数返回 rdma_packet，不取得调用方资源所有权。
// 失败/边界：rdma_mock_clone_packet 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（packet clone type mismatch），不保留部分有效快照。
function automatic rdma_packet rdma_mock_clone_packet(rdma_packet source);
  uvm_object cloned_object;
  rdma_packet result;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(result, cloned_object))
    `uvm_fatal("MOCK_COPY", "packet clone type mismatch")
  return result;
endfunction

// 功能：在 rdma_mock_call_trace 中，rdma_mock_clone_policy 为 mock trace 深拷贝输入对象，防止被测代码后续修改影响已记录的调用证据。
// 输入/输出及副作用：source（输入）；rdma_mock_clone_policy 读取 source 并使用字段 cloned_object；函数返回 rdma_net_response_policy，不取得调用方资源所有权。
// 失败/边界：rdma_mock_clone_policy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（response policy clone type mismatch），不保留部分有效快照。
function automatic rdma_net_response_policy rdma_mock_clone_policy(
  rdma_net_response_policy source
);
  uvm_object cloned_object;
  rdma_net_response_policy result;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(result, cloned_object))
    `uvm_fatal("MOCK_COPY", "response policy clone type mismatch")
  return result;
endfunction

// 功能：在 rdma_mock_call_trace 中，rdma_mock_clone_fault 为 mock trace 深拷贝输入对象，防止被测代码后续修改影响已记录的调用证据。
// 输入/输出及副作用：source（输入）；rdma_mock_clone_fault 读取 source 并使用字段 cloned_object；函数返回 rdma_net_fault，不取得调用方资源所有权。
// 失败/边界：rdma_mock_clone_fault 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（network fault clone type mismatch），不保留部分有效快照。
function automatic rdma_net_fault rdma_mock_clone_fault(rdma_net_fault source);
  uvm_object cloned_object;
  rdma_net_fault result;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(result, cloned_object))
    `uvm_fatal("MOCK_COPY", "network fault clone type mismatch")
  return result;
endfunction

// 功能：在 rdma_mock_call_trace 中，rdma_mock_clone_function_info 为 mock trace 深拷贝输入对象，防止被测代码后续修改影响已记录的调用证据。
// 输入/输出及副作用：source（输入）；rdma_mock_clone_function_info 读取 source 并使用字段 cloned_object；函数返回 rdma_pcie_function_info，不取得调用方资源所有权。
// 失败/边界：rdma_mock_clone_function_info 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（PCIe function info clone type mismatch），不保留部分有效快照。
function automatic rdma_pcie_function_info rdma_mock_clone_function_info(
  rdma_pcie_function_info source
);
  uvm_object cloned_object;
  rdma_pcie_function_info result;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(result, cloned_object))
    `uvm_fatal("MOCK_COPY", "PCIe function info clone type mismatch")
  return result;
endfunction

// 功能：在 rdma_mock_call_trace 中，rdma_mock_clone_bar_decode 为 mock trace 深拷贝输入对象，防止被测代码后续修改影响已记录的调用证据。
// 输入/输出及副作用：source（输入）；rdma_mock_clone_bar_decode 读取 source 并使用字段 cloned_object；函数返回 rdma_bar_decode，不取得调用方资源所有权。
// 失败/边界：rdma_mock_clone_bar_decode 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（BAR decode clone type mismatch），不保留部分有效快照。
function automatic rdma_bar_decode rdma_mock_clone_bar_decode(
  rdma_bar_decode source
);
  uvm_object cloned_object;
  rdma_bar_decode result;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(result, cloned_object))
    `uvm_fatal("MOCK_COPY", "BAR decode clone type mismatch")
  return result;
endfunction

class rdma_mock_host_mem_call extends uvm_object;
  `uvm_object_utils(rdma_mock_host_mem_call)

  longint unsigned call_sequence;
  string method_name;
  rdma_dma_request_context request_context;
  rdma_dma_mapping mapping;
  int unsigned size;
  int unsigned alignment;
  rdma_dma_direction_e direction;
  longint unsigned offset;
  byte data[];

  // 功能：构造 rdma_mock_host_mem_call，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：call_sequence=0；method_name=""；request_context=null；mapping=null；size=0；alignment=0；direction=RDMA_DMA_DEVICE_READ；offset=0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_mock_host_mem_call 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_mock_host_mem_call");
    super.new(name);
    call_sequence = 0;
    method_name = "";
    request_context = null;
    mapping = null;
    size = 0;
    alignment = 0;
    direction = RDMA_DMA_DEVICE_READ;
    offset = 0;
  endfunction
endclass

class rdma_mock_release_seal extends uvm_object;

  // 功能：构造 rdma_mock_release_seal，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_mock_release_seal 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_mock_release_seal");
    super.new(name);
  endfunction
endclass

class rdma_mock_release_completion extends uvm_object;
  local rdma_mock_release_seal release_seal;
  local bit release_complete;

  // 功能：构造 rdma_mock_release_completion，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：release_seal=null；release_complete=1'b0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_mock_release_completion 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_mock_release_completion");
    super.new(name);
    release_seal = null;
    release_complete = 1'b0;
  endfunction

  // 功能：在 rdma_mock_release_completion 中，initialize 校验依赖和 binding 后建立运行边界，只保存非拥有引用并拒绝重复配置。
  // 输入/输出及副作用：seal（输入）；initialize 先依据 seal == null；release_seal != null 校验 seal；成功时更新本对象配置/状态并保存非拥有引用，返回 rdma_status。
  // 失败/边界：实现中的空依赖、重复登记、状态或 generation/authority 校验失败时返回错误；失败时保留旧配置。
  function rdma_status initialize(rdma_mock_release_seal seal);
    if (seal == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "mock release seal is null");
    if (release_seal != null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "mock release completion is already sealed");
    release_seal = seal;
    return rdma_status::success();
  endfunction

  // 功能：执行 mark_complete 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：seal（输入）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过 output 返回结果。
  // 失败/边界：mark_complete 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  function rdma_status mark_complete(rdma_mock_release_seal seal);
    if (seal == null || release_seal == null || seal != release_seal)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "mock release completion seal is invalid");
    if (release_complete)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "mock release is already complete");
    release_complete = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：completion_status 校验 complete 与当前对象状态的一致性，并显式处理“mock release completion is not sealed”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：complete（输出）；completion_status 读取 complete 并使用字段 complete，并写入 complete；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：completion_status 返回 RDMA_SC_INVALID_STATE；典型拒绝条件为“mock release completion is not sealed”；失败路径不提交部分状态或转移未声明资源。
  function rdma_status completion_status(output bit complete);
    complete = 1'b0;
    if (release_seal == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "mock release completion is not sealed");
    complete = release_complete;
    return rdma_status::success();
  endfunction
endclass

class rdma_mock_dma_mapping extends rdma_dma_mapping;
  `uvm_object_utils(rdma_mock_dma_mapping)

  local longint unsigned allocation_token;
  local bit allocation_token_initialized;
  local rdma_mock_release_completion release_completion;
  local static longint unsigned next_token = 1;

  // 功能：构造 rdma_mock_dma_mapping，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：allocation_token=0；allocation_token_initialized=1'b0；release_completion=null。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_mock_dma_mapping 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_mock_dma_mapping");
    super.new(name);
    allocation_token = 0;
    allocation_token_initialized = 1'b0;
    release_completion = null;
  endfunction

  // 功能：initialize_allocation_token 更新字段 allocation_token、allocation_token_initialized、release_completion、status，并在提交前保持 Function authority、generation 和资源所有权约束。
  // 输入/输出及副作用：release_seal（输入）；initialize_allocation_token 先依据 allocation_token_initialized；next_token == 0；status == null || !status.ok( 校验 release_seal；成功时更新本对象配置/状态并保存非拥有引用，返回 rdma_status。
  // 失败/边界：initialize_allocation_token 返回 RDMA_SC_INVALID_STATE、RDMA_SC_RESOURCE_EXHAUSTED；典型拒绝条件为“allocation token is already initialized”“allocation tokens are exhausted”；失败路径不提交部分状态或转移未声明资源。
  function rdma_status initialize_allocation_token(
    rdma_mock_release_seal release_seal
  );
    rdma_status status;

    if (allocation_token_initialized)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "allocation token is already initialized");
    if (next_token == 0)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "allocation tokens are exhausted");
    allocation_token = next_token;
    allocation_token_initialized = 1'b1;
    next_token++;
    release_completion = new({get_name(), "_release_completion"});
    status = release_completion.initialize(release_seal);
    if (status == null || !status.ok()) begin
      allocation_token = 0;
      allocation_token_initialized = 1'b0;
      release_completion = null;
      if (status == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "mock release completion initialization returned null"
        );
      return status;
    end
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_mock_dma_mapping 中由 same_allocation 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_allocation 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  function bit same_allocation(rdma_mock_dma_mapping rhs);
    if (rhs == null)
      return 1'b0;
    return allocation_token_initialized && rhs.allocation_token_initialized &&
           allocation_token == rhs.allocation_token &&
           release_completion != null &&
           release_completion == rhs.release_completion;
  endfunction

  // 功能：在 rdma_mock_dma_mapping 中，mark_release_complete 执行 mark_release_complete 的mark_release_complete 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：release_seal（输入）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过 output
  //   返回结果。
  // 失败/边界：mark_release_complete 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  function rdma_status mark_release_complete(
    rdma_mock_release_seal release_seal
  );
    if (release_completion == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "mock release completion is not initialized");
    return release_completion.mark_complete(release_seal);
  endfunction

  // 功能：在 rdma_mock_dma_mapping 中，release_completion_status 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：release_complete（输出）；release_completion_status 可能更新本对象明确拥有的状态，并写入 release_complete；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：release_completion_status 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  virtual function rdma_status release_completion_status(
    output bit release_complete
  );
    release_complete = 1'b0;
    if (release_completion == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "mock release completion is not initialized");
    return release_completion.completion_status(release_complete);
  endfunction

  // 功能：在 rdma_mock_dma_mapping 中，snapshot_release_authority 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：snapshot（输出）；snapshot_release_authority 读取 snapshot 并使用字段 snapshot、candidate、candidate.allocation_token、candidate.allocation_token_initialized、candidate.release_completion，并写入 snapshot；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：snapshot_release_authority 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  virtual function rdma_status snapshot_release_authority(
    output rdma_dma_mapping snapshot
  );
    rdma_mock_dma_mapping candidate;

    snapshot = null;
    if (!allocation_token_initialized)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, "allocation token is not initialized"
      );
    candidate = rdma_mock_dma_mapping::type_id::create(
      {get_name(), "_authority"}
    );
    if (candidate == null)
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "mock allocation authority creation failed"
      );
    candidate.allocation_token = allocation_token;
    candidate.allocation_token_initialized = 1'b1;
    candidate.release_completion = release_completion;
    snapshot = candidate;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_mock_dma_mapping 中，release_authority_status 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：snapshot（输入）；release_authority_status 可能更新本对象明确拥有的状态；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：release_authority_status 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  virtual function rdma_status release_authority_status(
    rdma_dma_mapping snapshot
  );
    rdma_mock_dma_mapping typed_snapshot;

    if (!$cast(typed_snapshot, snapshot) || typed_snapshot == null ||
        !same_allocation(typed_snapshot))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "mock allocation release authority changed"
      );
    return rdma_status::success();
  endfunction

  // 功能：将 rhs 中 rdma_mock_dma_mapping 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（mock DMA mapping copy type mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_mock_dma_mapping rhs_mapping;
    bit destination_was_initialized;
    longint unsigned destination_token;
    rdma_mock_release_completion destination_completion;

    destination_was_initialized = allocation_token_initialized;
    destination_token = allocation_token;
    destination_completion = release_completion;
    super.do_copy(rhs);
    if (!$cast(rhs_mapping, rhs))
      `uvm_fatal("MOCK_COPY", "mock DMA mapping copy type mismatch")
    if (destination_was_initialized) begin
      // Public mapping fields may be copied, but established identity is fixed.
      allocation_token = destination_token;
      allocation_token_initialized = 1'b1;
      release_completion = destination_completion;
    end
    else begin
      allocation_token = rhs_mapping.allocation_token;
      allocation_token_initialized = rhs_mapping.allocation_token_initialized;
      release_completion = rhs_mapping.release_completion;
    end
  endfunction
endclass

class rdma_mock_memory_region extends uvm_object;
  `uvm_object_utils(rdma_mock_memory_region)

  rdma_dma_mapping mapping;
  byte data[];

  // 功能：构造 rdma_mock_memory_region，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：mapping=null。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_mock_memory_region 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_mock_memory_region");
    super.new(name);
    mapping = null;
  endfunction
endclass

class rdma_mock_host_mem extends rdma_host_mem_api;
  `uvm_object_utils(rdma_mock_host_mem)

  rdma_mock_host_mem_call calls[$];
  rdma_mock_memory_region regions[$];
  rdma_status failures[string];
  // Deterministic method/role/ordinal fault script.  Roles are carried in the
  // key for machine-readable tests; adapters that cannot infer a role consume
  // the oldest matching method+ordinal entry.
  rdma_status role_failures[string];
  int unsigned method_ordinals[string];
  rdma_queue_backing_role_e mapping_roles[longint unsigned];
  longint unsigned next_sequence;
  longint unsigned next_address;
  rdma_mock_call_trace call_trace;
  int writes_until_failure;
  rdma_status delayed_write_failure;
  bit corrupt_next_readback;
  local rdma_mock_release_seal release_seal;

  // 功能：构造 rdma_mock_host_mem，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：next_sequence=0；next_address=64'h0000_0001_0000_0000；call_trace=null；writes_until_failure=-1；delayed_write_failure=null；corrupt_next_readback=1'b0；release_seal=new("mock_adapter_release_seal")。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_mock_host_mem 构造只建立本地初始状态；本地 semaphore/ledger 等按构造体显式分配，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_mock_host_mem");
    super.new(name);
    next_sequence = 0;
    next_address = 64'h0000_0001_0000_0000;
    call_trace = null;
    writes_until_failure = -1;
    delayed_write_failure = null;
    corrupt_next_readback = 1'b0;
    release_seal = new("mock_adapter_release_seal");
  endfunction

  // 功能：在 rdma_mock_host_mem 中，set_call_trace 记录 set_call_trace 的调用名称和顺序，供测试断言转发路径；不改变被测事务业务结果。
  // 输入/输出及副作用：trace（输入）；set_call_trace 先依据 依赖存在性、authority 和 generation 条件 校验 trace；成功时更新本对象配置/状态并保存非拥有引用，返回 void。
  // 失败/边界：记录操作仅影响测试 trace；不得因注入记录故障改变生产状态或吞掉真实错误。
  function void set_call_trace(rdma_mock_call_trace trace);
    call_trace = trace;
  endfunction

  // 功能：在 rdma_mock_host_mem 中，live_allocations 只读查询当前运行时/测试账本，返回槽位、对象或恢复记录的快照而不推进事务。
  // 输入/输出及副作用：无显式参数；live_allocations 读取 对象字段：regions、mapping、mapping.state 并使用字段 count；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：live_allocations 的结果直接由 return count 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function int unsigned live_allocations();
    int unsigned count;

    count = 0;
    foreach (regions[i])
      if (regions[i].mapping != null &&
          regions[i].mapping.state == RDMA_MAPPING_ACTIVE)
        count++;
    return count;
  endfunction

  // 功能：在 rdma_mock_host_mem 中，fail_write_at 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：ordinal（输入）、status（输入）；fail_write_at 读取 ordinal、status 并使用字段 writes_until_failure、delayed_write_failure；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：fail_write_at 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“write failure ordinal/status is invalid”；失败路径不提交部分状态或转移未声明资源。
  function rdma_status fail_write_at(
    int unsigned ordinal,
    rdma_status status
  );
    if (ordinal == 0 || status == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "write failure ordinal/status is invalid");
    writes_until_failure = ordinal - 1;
    delayed_write_failure = rdma_mock_clone_status(status);
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_mock_host_mem 中，fail_next 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：method_name（输入）、status（输入）；fail_next 读取 method_name、status 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：fail_next 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“unknown host memory method”“failure status is null”；失败路径不提交部分状态或转移未声明资源。
  function rdma_status fail_next(string method_name, rdma_status status);
    if (!(method_name inside {"allocate", "write", "read", "release",
                              "release_opaque"}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "unknown host memory method");
    if (status == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "failure status is null");
    failures[method_name] = rdma_mock_clone_status(status);
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_mock_host_mem 中，fail_role_call 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：method_name（输入）、role（输入）、ordinal（输入）、status（输入）；fail_role_call 读取 method_name、role、ordinal、status 并使用字段 key；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：fail_role_call 无返回值，仅执行 key=$sformatf("%s:%0d:%0d", method_name, role, ordinal)；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  function void fail_role_call(string method_name,
                               rdma_queue_backing_role_e role,
                               int unsigned ordinal,
                               rdma_status status);
    string key;
    if (status == null || ordinal == 0)
      return;
    key = $sformatf("%s:%0d:%0d", method_name, role, ordinal);
    role_failures[key] = rdma_mock_clone_status(status);
  endfunction

  // 功能：在 rdma_mock_host_mem 中，reset reset 清理当前运行状态并建立新的复位/代际边界，使旧句柄或旧事务不能继续生效。
  // 输入/输出及副作用：无显式参数；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：复位参数为零、代际回退或存在未处理 pending 事务时拒绝更新 authority。
  function void reset();
    calls.delete(); regions.delete(); failures.delete();
    role_failures.delete(); method_ordinals.delete();
    mapping_roles.delete();
    next_sequence = 0;
    next_address = 64'h0000_0001_0000_0000;
    writes_until_failure = -1; delayed_write_failure = null;
  endfunction

  // 功能：在 rdma_mock_host_mem 中，take_failure 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：method_name（输入）；take_failure 读取 method_name 并使用字段 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：take_failure 输入对象为空或查找未命中时返回 null；该路径不隐式重试，也不转移未声明资源。
  function automatic rdma_status take_failure(string method_name);
    rdma_status result;

    if (!failures.exists(method_name))
      return null;
    result = rdma_mock_clone_status(failures[method_name]);
    failures.delete(method_name);
    return result;
  endfunction

  // 功能：在 rdma_mock_host_mem 中，take_role_failure 执行 take_role_failure 的take_role_failure 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：method_name（输入）、role（输入）；take_role_failure 读取 method_name、role 并使用字段 ordinal、key、result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：take_role_failure 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  function automatic rdma_status take_role_failure(
    string method_name,
    rdma_queue_backing_role_e role
  );
    rdma_status result;
    int unsigned ordinal;
    string key;

    ordinal = method_ordinals.exists(method_name) ? method_ordinals[method_name] : 0;
    key = $sformatf("%s:%0d:%0d", method_name, role, ordinal);
    if (role_failures.exists(key)) begin
      result = rdma_mock_clone_status(role_failures[key]);
      role_failures.delete(key);
      return result;
    end
    return null;
  endfunction

  // 功能：mapping_role 比较 mapping、role 与当前 authority/状态字段，返回布尔结果供上层执行精确分支。
  // 输入/输出及副作用：mapping（输入）、role（输出）；mapping_role 读取 mapping、role 并使用字段 role，并写入 role；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：mapping_role 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  function automatic bit mapping_role(
    rdma_dma_mapping mapping,
    output rdma_queue_backing_role_e role
  );
    role = RDMA_QUEUE_ROLE_CQ_RING;
    if (mapping == null || !mapping_roles.exists(mapping.iova.value))
      return 1'b0;
    role = mapping_roles[mapping.iova.value];
    return 1'b1;
  endfunction

  // 功能：request_role 使用 request_context、size、alignment 计算并返回 rdma_queue_backing_role_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：request_context（输入）、size（输入）、alignment（输入）；request_role 读取 request_context、size、alignment 并使用字段 kind、ordinal；函数返回 rdma_queue_backing_role_e，不取得调用方资源所有权。

  // 失败/边界：request_role 是只读访问器，返回 rdma_queue_backing_role_e'(request_context.queue_role)；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  function automatic rdma_queue_backing_role_e request_role(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment
  );
    rdma_resource_kind_e kind;
    int unsigned ordinal;

    if (request_context != null && request_context.queue_role_valid &&
        request_context.queue_role <=
          int'(RDMA_QUEUE_ROLE_SRFQC_CONTEXT_SHADOW))
      return rdma_queue_backing_role_e'(request_context.queue_role);
    if (request_context == null || request_context.owner_h == null)
      return RDMA_QUEUE_ROLE_CQ_RING;
    kind = request_context.owner_h.kind;
    ordinal = method_ordinals.exists("allocate") ?
      method_ordinals["allocate"] : 1;
    case (kind)
      RDMA_RESOURCE_CQ:
        return (size == 4096 && alignment == 4096) ?
          RDMA_QUEUE_ROLE_CQ_PD : RDMA_QUEUE_ROLE_CQ_RING;
      RDMA_RESOURCE_SRQ: begin
        if (alignment == 512)
          return RDMA_QUEUE_ROLE_SRQ_SGB;
        if (size == 4096)
          return (ordinal >= 5) ? RDMA_QUEUE_ROLE_SRFQ_PD :
                                  RDMA_QUEUE_ROLE_SRQ_PD;
        return (ordinal == 2) ? RDMA_QUEUE_ROLE_SRFQ_RING :
                                RDMA_QUEUE_ROLE_SRQ_RING;
      end
      RDMA_RESOURCE_CEQ:
        return (size == 4096 && alignment == 4096) ?
          RDMA_QUEUE_ROLE_CEQ_PD : RDMA_QUEUE_ROLE_CEQ_RING;
      RDMA_RESOURCE_AEQ:
        return (size == 4096 && alignment == 4096) ?
          RDMA_QUEUE_ROLE_AEQ_PD : RDMA_QUEUE_ROLE_AEQ_RING;
      default: return RDMA_QUEUE_ROLE_CQ_RING;
    endcase
  endfunction

  // 功能：在 rdma_mock_host_mem 中，record_call 记录 record_call 的调用名称和顺序，供测试断言转发路径；不改变被测事务业务结果。
  // 输入/输出及副作用：method_name（输入）、request_context（输入）、mapping（输入）、size（输入）、alignment（输入）、direction（输入）、offset（输入）、data（输入）；输入
  //   request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过 output 返回结果。
  // 失败/边界：记录操作仅影响测试 trace；不得因注入记录故障改变生产状态或吞掉真实错误。
  function automatic rdma_mock_host_mem_call record_call(
    string method_name,
    rdma_dma_request_context request_context = null,
    rdma_dma_mapping mapping = null,
    int unsigned size = 0,
    int unsigned alignment = 0,
    rdma_dma_direction_e direction = RDMA_DMA_DEVICE_READ,
    longint unsigned offset = 0,
    byte data[] = '{}
  );
    rdma_mock_host_mem_call call_record;

    call_record = rdma_mock_host_mem_call::type_id::create(
      $sformatf("host_call_%0d", next_sequence + 1'b1)
    );
    next_sequence++;
    call_record.call_sequence = next_sequence;
    call_record.method_name = method_name;
    method_ordinals[method_name]++;
    call_record.request_context =
      rdma_mock_clone_dma_context(request_context);
    call_record.mapping = rdma_mock_clone_mapping(mapping);
    call_record.size = size;
    call_record.alignment = alignment;
    call_record.direction = direction;
    call_record.offset = offset;
    call_record.data = data;
    calls.push_back(call_record);
    if (call_trace != null)
      call_trace.record({"host_", method_name});
    return call_record;
  endfunction

  // 功能：在 rdma_mock_host_mem 中由 same_handle 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_handle 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  function automatic bit same_handle(rdma_handle lhs, rdma_handle rhs);
    if (lhs == null || rhs == null)
      return lhs == null && rhs == null;
    return lhs.same_instance(rhs);
  endfunction

  // 功能：在 rdma_mock_host_mem 中，mapping_authority_matches 逐字段比较输入快照或镜像，确认其身份、布局和 payload 完全一致后返回布尔结果。
  // 输入/输出及副作用：candidate（输入）、authority（输入）；mapping_authority_matches 读取 candidate、authority 并使用输入参数和固定枚举/常量；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：mapping_authority_matches 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  function automatic bit mapping_authority_matches(
    rdma_dma_mapping candidate,
    rdma_dma_mapping authority
  );
    if (candidate == null || authority == null)
      return 1'b0;
    return same_handle(candidate.function_h, authority.function_h) &&
           candidate.requester_bdf == authority.requester_bdf &&
           candidate.pasid_valid == authority.pasid_valid &&
           candidate.pasid == authority.pasid &&
           candidate.dma_domain_valid == authority.dma_domain_valid &&
           candidate.dma_domain_id == authority.dma_domain_id &&
           candidate.route_valid == authority.route_valid &&
           candidate.route.host_topology_key ==
             authority.route.host_topology_key &&
           candidate.route.root_id == authority.route.root_id &&
           candidate.route.segment == authority.route.segment &&
           rdma_bdf_same(candidate.route.bdf, authority.route.bdf) &&
           candidate.epoch_valid == authority.epoch_valid &&
           candidate.reset_epoch == authority.reset_epoch &&
           same_handle(candidate.owner_h, authority.owner_h);
  endfunction

  // 功能：在 rdma_mock_host_mem 中，find_region 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：mapping（输入）；find_region 读取 mapping 并使用字段 regions；函数返回 int，不取得调用方资源所有权。
  // 失败/边界：find_region 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  function automatic int find_region(rdma_dma_mapping mapping);
    rdma_mock_dma_mapping requested_mapping;
    rdma_mock_dma_mapping region_mapping;

    if (mapping == null)
      return -1;
    if (!$cast(requested_mapping, mapping))
      return -1;
    foreach (regions[i]) begin
      if (!$cast(region_mapping, regions[i].mapping))
        continue;
      if (region_mapping.same_allocation(requested_mapping) &&
          mapping_authority_matches(mapping, region_mapping))
        return i;
    end
    return -1;
  endfunction

  // 功能：在 rdma_mock_host_mem 中，allocate 检查容量后预留资源并返回带 owner 证据的句柄/计划；失败时回滚已登记的局部状态。
  // 输入/输出及副作用：request_context（输入）、size（输入）、alignment（输入）、direction（输入）、mapping（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或
  //   output 发布新句柄/映射。
  // 失败/边界：容量不足、范围非法、重复占用或身份过期时返回错误；失败不得泄漏半分配资源。
  virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    rdma_status failure;
    rdma_status status;
    rdma_status token_status;
    rdma_mock_memory_region region;
    rdma_mock_dma_mapping allocated_mapping;
    rdma_queue_backing_role_e role;
    longint unsigned aligned_address;
    longint unsigned alignment_mask;

    mapping = null;
    record_call("allocate", request_context, null, size, alignment,
                direction);
    role = request_role(request_context, size, alignment);
    failure = take_role_failure("allocate", role);
    if (failure != null) return failure;
    if (request_context == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "DMA request context is null");
    status = request_context.validate();
    if (!status.ok())
      return status;
    failure = take_failure("allocate");
    if (failure != null)
      return failure;
    if (size == 0 || alignment == 0 ||
        (alignment & (alignment - 1'b1)) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "size or alignment is invalid");
    if (!(direction inside {RDMA_DMA_DEVICE_READ, RDMA_DMA_DEVICE_WRITE,
                            RDMA_DMA_BIDIRECTIONAL}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "DMA direction is invalid");

    alignment_mask = alignment - 1'b1;
    if (next_address > (64'hffff_ffff_ffff_ffff - alignment_mask))
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "aligned DMA address overflows");
    aligned_address = (next_address + alignment_mask) & ~alignment_mask;
    if (size > (64'hffff_ffff_ffff_ffff - aligned_address))
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "DMA allocation end overflows");
    allocated_mapping = rdma_mock_dma_mapping::type_id::create(
      $sformatf("mapping_%0d", regions.size())
    );
    token_status = allocated_mapping.initialize_allocation_token(release_seal);
    if (!token_status.ok())
      return token_status;
    allocated_mapping.function_h =
      rdma_mock_clone_function_handle(request_context.function_h);
    allocated_mapping.requester_bdf = request_context.requester_bdf;
    allocated_mapping.pasid_valid = request_context.pasid_valid;
    allocated_mapping.pasid = request_context.pasid;
    allocated_mapping.dma_domain_valid = request_context.dma_domain_valid;
    allocated_mapping.dma_domain_id = request_context.dma_domain_id;
    allocated_mapping.route = request_context.route;
    allocated_mapping.route_valid = request_context.route_valid;
    allocated_mapping.reset_epoch = request_context.reset_epoch;
    allocated_mapping.epoch_valid = request_context.epoch_valid;
    allocated_mapping.backing_addr.value = aligned_address;
    allocated_mapping.iova.value = aligned_address;
    allocated_mapping.size = size;
    allocated_mapping.direction = direction;
    allocated_mapping.permissions.device_read =
      direction inside {RDMA_DMA_DEVICE_READ, RDMA_DMA_BIDIRECTIONAL};
    allocated_mapping.permissions.device_write =
      direction inside {RDMA_DMA_DEVICE_WRITE, RDMA_DMA_BIDIRECTIONAL};
    allocated_mapping.permissions.atomic = 1'b0;
    allocated_mapping.state = RDMA_MAPPING_ACTIVE;
    allocated_mapping.owner_h = (request_context.owner_h == null) ? null :
      rdma_clone_handle_value(request_context.owner_h,
                              "mock host memory mapping owner");
    mapping = allocated_mapping;
    mapping_roles[allocated_mapping.iova.value] = role;

    region = rdma_mock_memory_region::type_id::create(
      $sformatf("region_%0d", regions.size())
    );
    region.mapping = rdma_mock_clone_mapping(mapping);
    region.data = new[size];
    regions.push_back(region);
    next_address = aligned_address + size;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_mock_host_mem 中，write 把请求数据写入指定后端并保留返回状态；只有写入成功才允许本地游标继续推进。
  // 输入/输出及副作用：mapping（输入）、offset（输入）、data（输入）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending
  //   journal，并通过 output 返回结果。
  // 失败/边界：write 遇到后端拒绝、范围溢出或 DMA 权限不足时保留失败证据，不推进本地游标。
  virtual function rdma_status write(
    rdma_dma_mapping mapping,
    longint unsigned offset,
    byte data[]
  );
    rdma_status failure;
    int region_index;
    longint unsigned allocated_size;
    rdma_queue_backing_role_e role;

    record_call("write", null, mapping, data.size(), 0,
                RDMA_DMA_DEVICE_READ, offset, data);
    void'(mapping_role(mapping, role));
    failure = take_role_failure("write", role);
    if (failure != null) return failure;
    if (writes_until_failure == 0) begin
      failure = rdma_mock_clone_status(delayed_write_failure);
    writes_until_failure = -1;
    delayed_write_failure = null;
    corrupt_next_readback = 1'b0;
      return failure;
    end
    if (writes_until_failure > 0)
      writes_until_failure--;
    failure = take_failure("write");
    if (failure != null)
      return failure;
    if (mapping == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "DMA mapping is null");
    if (mapping.state != RDMA_MAPPING_ACTIVE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "DMA mapping is not active");
    region_index = find_region(mapping);
    if (region_index < 0)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "DMA mapping is unknown");
    if (regions[region_index].mapping.state != RDMA_MAPPING_ACTIVE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "DMA allocation is not active");
    allocated_size = regions[region_index].mapping.size;
    if (offset > allocated_size)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "write is outside the DMA mapping");
    if (data.size() > (allocated_size - offset))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "write is outside the DMA mapping");
    foreach (data[i])
      regions[region_index].data[offset + i] = data[i];
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_mock_host_mem 中，read 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：mapping（输入）、offset（输入）、size（输入）、data（输出）；输入 handle/key/cursor 用于选择读取范围；返回值或 output 为 detached
  //   快照，读取不取得外部资源所有权。
  // 失败/边界：read 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  virtual function rdma_status read(
    rdma_dma_mapping mapping,
    longint unsigned offset,
    int unsigned size,
    output byte data[]
  );
    rdma_status failure;
    int region_index;
    longint unsigned allocated_size;
    rdma_queue_backing_role_e role;

    record_call("read", null, mapping, size, 0, RDMA_DMA_DEVICE_READ,
                offset);
    void'(mapping_role(mapping, role));
    failure = take_role_failure("read", role);
    if (failure != null) return failure;
    data = new[0];
    failure = take_failure("read");
    if (failure != null)
      return failure;
    if (mapping == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "DMA mapping is null");
    if (mapping.state != RDMA_MAPPING_ACTIVE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "DMA mapping is not active");
    region_index = find_region(mapping);
    if (region_index < 0)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "DMA mapping is unknown");
    if (regions[region_index].mapping.state != RDMA_MAPPING_ACTIVE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "DMA allocation is not active");
    allocated_size = regions[region_index].mapping.size;
    if (offset > allocated_size)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "read is outside the DMA mapping");
    if (size > (allocated_size - offset))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "read is outside the DMA mapping");
    data = new[size];
    foreach (data[i])
      data[i] = regions[region_index].data[offset + i];
    if (corrupt_next_readback && size != 0) begin
      data[0] = data[0] ^ 8'hff;
      corrupt_next_readback = 1'b0;
    end
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_mock_host_mem 中，release 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：mapping（输入）；输入 handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：release 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  virtual function rdma_status \release (rdma_dma_mapping mapping);
    rdma_status failure;
    rdma_status status;
    int region_index;
    rdma_mock_dma_mapping concrete_mapping;
    rdma_queue_backing_role_e role;

    record_call("release", null, mapping);
    void'(mapping_role(mapping, role));
    failure = take_role_failure("release", role);
    if (failure != null) return failure;
    failure = take_failure("release");
    if (failure != null)
      return failure;
    if (mapping == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "DMA mapping is null");
    if (mapping.state != RDMA_MAPPING_ACTIVE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "DMA mapping is not active");
    region_index = find_region(mapping);
    if (region_index < 0)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "DMA mapping is unknown");
    if (regions[region_index].mapping.state != RDMA_MAPPING_ACTIVE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "DMA allocation is not active");
    if (!$cast(concrete_mapping, mapping) || concrete_mapping == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "mock DMA mapping lost its concrete type");
    status = concrete_mapping.mark_release_complete(release_seal);
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "mock release completion marking returned null"
      );
    if (!status.ok())
      return status;
    mapping.state = RDMA_MAPPING_RELEASED;
    regions[region_index].mapping.state = RDMA_MAPPING_RELEASED;
    return rdma_status::success();
  endfunction

  // 功能：release_opaque 仅依据 mock mapping 的不透明 allocation token 查找
  //       region，模拟真实 adapter 在畸形 public 字段回滚时仍可释放 backing。
  // 输入/输出及副作用：mapping（输入）；成功时更新 region 和 mapping 的释放状态；
  //       不使用可篡改的 route、IOVA 或 size 字段定位 allocation。
  // 失败/边界：mapping 类型错误、token 未登记、region 已释放或 completion seal
  //       无效时返回错误；不会修改其他 region。
  virtual function rdma_status release_opaque(rdma_dma_mapping mapping);
    rdma_mock_dma_mapping concrete_mapping;
    rdma_mock_dma_mapping region_mapping;
    rdma_status failure;
    rdma_status status;
    int region_index;
    rdma_queue_backing_role_e role;

    record_call("release_opaque", null, mapping);
    void'(mapping_role(mapping, role));
    failure = take_role_failure("release_opaque", role);
    if (failure != null)
      return failure;
    failure = take_failure("release_opaque");
    if (failure != null)
      return failure;
    if (!$cast(concrete_mapping, mapping) || concrete_mapping == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "opaque mock mapping has no allocation token"
      );
    region_index = -1;
    foreach (regions[i]) begin
      if (!$cast(region_mapping, regions[i].mapping))
        continue;
      if (region_mapping.same_allocation(concrete_mapping)) begin
        region_index = i;
        break;
      end
    end
    if (region_index < 0)
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "opaque mock mapping is unknown"
      );
    if (regions[region_index].mapping.state != RDMA_MAPPING_ACTIVE)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "opaque mock mapping has already been released"
      );
    status = concrete_mapping.mark_release_complete(release_seal);
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "opaque mock release completion returned null"
      );
    if (!status.ok())
      return status;
    concrete_mapping.state = RDMA_MAPPING_RELEASED;
    regions[region_index].mapping.state = RDMA_MAPPING_RELEASED;
    return rdma_status::success();
  endfunction
endclass

class rdma_mock_pcie_call extends uvm_object;
  `uvm_object_utils(rdma_mock_pcie_call)

  longint unsigned call_sequence;
  string method_name;
  rdma_bdf_t target;
  rdma_cfg_offset_t offset;
  bit [31:0] cfg_data;
  bit [3:0] byte_enable;
  rdma_function_handle function_h;
  rdma_bar_addr_t address;
  byte data[];

  // 功能：构造 rdma_mock_pcie_call，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：call_sequence=0；method_name=""；target='0；offset='0；cfg_data='0；byte_enable='0；function_h=null；address='0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_mock_pcie_call 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_mock_pcie_call");
    super.new(name);
    call_sequence = 0;
    method_name = "";
    target = '0;
    offset = '0;
    cfg_data = '0;
    byte_enable = '0;
    function_h = null;
    address = '0;
  endfunction
endclass

class rdma_mock_pcie extends rdma_pcie_api;
  `uvm_object_utils(rdma_mock_pcie)

  rdma_mock_pcie_call calls[$];
  rdma_status failures[string];
  longint unsigned next_sequence;
  bit [31:0] cfg_read_value;
  rdma_pcie_function_info function_info_response;
  rdma_bar_decode decode_response;
  rdma_mock_call_trace call_trace;
  rdma_status role_failures[string];
  int unsigned method_ordinals[string];

  // 功能：构造 rdma_mock_pcie，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：next_sequence=0；cfg_read_value='0；function_info_response=null；decode_response=null；call_trace=null。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_mock_pcie 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_mock_pcie");
    super.new(name);
    next_sequence = 0;
    cfg_read_value = '0;
    function_info_response = null;
    decode_response = null;
    call_trace = null;
  endfunction

  // 功能：在 rdma_mock_pcie 中，set_call_trace 记录 set_call_trace 的调用名称和顺序，供测试断言转发路径；不改变被测事务业务结果。
  // 输入/输出及副作用：trace（输入）；set_call_trace 先依据 依赖存在性、authority 和 generation 条件 校验 trace；成功时更新本对象配置/状态并保存非拥有引用，返回 void。
  // 失败/边界：记录操作仅影响测试 trace；不得因注入记录故障改变生产状态或吞掉真实错误。
  function void set_call_trace(rdma_mock_call_trace trace);
    call_trace = trace;
  endfunction

  // 功能：在 rdma_mock_pcie 中，fail_next 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：method_name（输入）、status（输入）；fail_next 读取 method_name、status 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：fail_next 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“unknown PCIe method”“failure status is null”；失败路径不提交部分状态或转移未声明资源。
  function rdma_status fail_next(string method_name, rdma_status status);
    if (!(method_name inside {
          "cfg_read32", "cfg_write32", "mmio_write",
          "dma_visibility_barrier", "mmio_ordering_barrier",
          "get_function_info", "decode_bar"
        }))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "unknown PCIe method");
    if (status == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "failure status is null");
    failures[method_name] = rdma_mock_clone_status(status);
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_mock_pcie 中，fail_role_call 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：method_name（输入）、role（输入）、ordinal（输入）、status（输入）；fail_role_call 读取 method_name、role、ordinal、status 并使用输入参数和固定枚举/常量；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：fail_role_call 无返回值，仅执行 函数体中的顺序操作；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  function void fail_role_call(string method_name,
                               rdma_queue_backing_role_e role,
                               int unsigned ordinal,
                               rdma_status status);
    if (status != null && ordinal != 0)
      role_failures[$sformatf("%s:%0d:%0d", method_name, role, ordinal)] =
        rdma_mock_clone_status(status);
  endfunction

  // 功能：在 rdma_mock_pcie 中，reset reset 清理当前运行状态并建立新的复位/代际边界，使旧句柄或旧事务不能继续生效。
  // 输入/输出及副作用：无显式参数；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：复位参数为零、代际回退或存在未处理 pending 事务时拒绝更新 authority。
  function void reset();
    calls.delete(); failures.delete(); role_failures.delete();
    method_ordinals.delete();
    next_sequence = 0;
  endfunction

  // 功能：在 rdma_mock_pcie 中，take_role_failure 执行 take_role_failure 的take_role_failure 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：method_name（输入）、role（输入）；take_role_failure 读取 method_name、role 并使用字段 ordinal、key、result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：take_role_failure 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  function automatic rdma_status take_role_failure(
    string method_name,
    rdma_queue_backing_role_e role
  );
    string key;
    rdma_status result;
    int unsigned ordinal;

    ordinal = method_ordinals.exists(method_name) ? method_ordinals[method_name] : 0;
    key = $sformatf("%s:%0d:%0d", method_name, role, ordinal);
    if (!role_failures.exists(key)) return null;
    result = rdma_mock_clone_status(role_failures[key]);
    role_failures.delete(key);
    return result;
  endfunction

  // 功能：在 rdma_mock_pcie 中，take_failure 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：method_name（输入）；take_failure 读取 method_name 并使用字段 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：take_failure 输入对象为空或查找未命中时返回 null；该路径不隐式重试，也不转移未声明资源。
  function automatic rdma_status take_failure(string method_name);
    rdma_status result;

    if (!failures.exists(method_name))
      return null;
    result = rdma_mock_clone_status(failures[method_name]);
    failures.delete(method_name);
    return result;
  endfunction

  // 功能：在 rdma_mock_pcie 中，record_call 记录 record_call 的调用名称和顺序，供测试断言转发路径；不改变被测事务业务结果。
  // 输入/输出及副作用：method_name（输入）、target（输入）、offset（输入）、cfg_data（输入）、byte_enable（输入）、function_h（输入）、address（输入）、data（输入）；输入
  //   request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过 output 返回结果。
  // 失败/边界：记录操作仅影响测试 trace；不得因注入记录故障改变生产状态或吞掉真实错误。
  function automatic rdma_mock_pcie_call record_call(
    string method_name,
    rdma_bdf_t target = '0,
    rdma_cfg_offset_t offset = '0,
    bit [31:0] cfg_data = '0,
    bit [3:0] byte_enable = '0,
    rdma_function_handle function_h = null,
    rdma_bar_addr_t address = '0,
    byte data[] = '{}
  );
    rdma_mock_pcie_call call_record;

    call_record = rdma_mock_pcie_call::type_id::create(
      $sformatf("pcie_call_%0d", next_sequence + 1'b1)
    );
    next_sequence++;
    call_record.call_sequence = next_sequence;
    call_record.method_name = method_name;
    method_ordinals[method_name]++;
    call_record.target = target;
    call_record.offset = offset;
    call_record.cfg_data = cfg_data;
    call_record.byte_enable = byte_enable;
    call_record.function_h = rdma_mock_clone_function_handle(function_h);
    call_record.address = address;
    call_record.data = data;
    calls.push_back(call_record);
    if (call_trace != null)
      call_trace.record({"pcie_", method_name});
    return call_record;
  endfunction

  // 功能：在 rdma_mock_pcie 中，cfg_read32 把 cfg_read32 的配置/编程请求提交到后端适配器，并返回后端确认状态。
  // 输入/输出及副作用：target（输入）、offset（输入）、data（输出）、status（输出）；cfg_read32 驱动下游事务，并写入 data、status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：cfg_read32 遇到后端拒绝、范围溢出或 DMA 权限不足时保留失败证据，不推进本地游标。
  virtual task cfg_read32(
    rdma_bdf_t target,
    rdma_cfg_offset_t offset,
    output bit [31:0] data,
    output rdma_status status
  );
    record_call("cfg_read32", target, offset);
    data = '0;
    status = take_role_failure("cfg_read32", RDMA_QUEUE_ROLE_CQ_RING);
    if (status == null) status = take_failure("cfg_read32");
    if (status != null)
      return;
    data = cfg_read_value;
    status = rdma_status::success();
  endtask

  // 功能：在 rdma_mock_pcie 中，cfg_write32 把 cfg_write32 的配置/编程请求提交到后端适配器，并返回后端确认状态。
  // 输入/输出及副作用：target（输入）、offset（输入）、data（输入）、byte_enable（输入）、status（输出）；cfg_write32 驱动下游事务，并写入 status；函数返回 无直接返回值，不取得调用方资源所有权。

  // 失败/边界：cfg_write32 遇到后端拒绝、范围溢出或 DMA 权限不足时保留失败证据，不推进本地游标。
  virtual task cfg_write32(
    rdma_bdf_t target,
    rdma_cfg_offset_t offset,
    bit [31:0] data,
    bit [3:0] byte_enable,
    output rdma_status status
  );
    record_call("cfg_write32", target, offset, data, byte_enable);
    status = take_role_failure("cfg_write32", RDMA_QUEUE_ROLE_CQ_RING);
    if (status == null) status = take_failure("cfg_write32");
    if (status == null)
      status = rdma_status::success();
  endtask

  // 功能：在 rdma_mock_pcie 中，mmio_write 把请求数据写入指定后端并保留返回状态；只有写入成功才允许本地游标继续推进。
  // 输入/输出及副作用：function_h（输入）、address（输入）、data（输入）、status（输出）；mmio_write 驱动下游事务，并写入 status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：mmio_write 遇到后端拒绝、范围溢出或 DMA 权限不足时保留失败证据，不推进本地游标。
  virtual task mmio_write(
    rdma_function_handle function_h,
    rdma_bar_addr_t address,
    byte data[],
    output rdma_status status
  );
    record_call("mmio_write", '0, '0, '0, '0, function_h, address, data);
    status = take_role_failure("mmio_write", RDMA_QUEUE_ROLE_CQ_RING);
    if (status == null) status = take_failure("mmio_write");
    if (status == null)
      status = rdma_status::success();
  endtask

  // 功能：在 rdma_mock_pcie 中，dma_visibility_barrier 在截止时间内执行 DMA 可见性或 MMIO 顺序屏障，确保 doorbell 之前的数据写入已按序可见。
  // 输入/输出及副作用：function_h（输入）、status（输出）；dma_visibility_barrier 驱动下游事务，并写入 status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：dma_visibility_barrier 失败或超时通过 status 明确发布；该路径不隐式重试，也不转移未声明资源。
  virtual task dma_visibility_barrier(
    rdma_function_handle function_h,
    output rdma_status status
  );
    record_call("dma_visibility_barrier", '0, '0, '0, '0, function_h);
    status = take_role_failure("dma_visibility_barrier", RDMA_QUEUE_ROLE_CQ_RING);
    if (status == null) status = take_failure("dma_visibility_barrier");
    if (status == null)
      status = rdma_status::success();
  endtask

  // 功能：在 rdma_mock_pcie 中，mmio_ordering_barrier 在截止时间内执行 DMA 可见性或 MMIO 顺序屏障，确保 doorbell 之前的数据写入已按序可见。
  // 输入/输出及副作用：function_h（输入）、status（输出）；mmio_ordering_barrier 驱动下游事务，并写入 status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：mmio_ordering_barrier 失败或超时通过 status 明确发布；该路径不隐式重试，也不转移未声明资源。
  virtual task mmio_ordering_barrier(
    rdma_function_handle function_h,
    output rdma_status status
  );
    record_call("mmio_ordering_barrier", '0, '0, '0, '0, function_h);
    status = take_role_failure("mmio_ordering_barrier", RDMA_QUEUE_ROLE_CQ_RING);
    if (status == null) status = take_failure("mmio_ordering_barrier");
    if (status == null)
      status = rdma_status::success();
  endtask

  // 功能：在 rdma_mock_pcie 中，get_function_info 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：bdf（输入）、info（输出）；get_function_info 读取 bdf、info 并使用字段 info、failure，并写入 info；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：get_function_info 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  virtual function rdma_status get_function_info(
    rdma_bdf_t bdf,
    output rdma_pcie_function_info info
  );
    rdma_status failure;

    record_call("get_function_info", bdf);
    info = null;
    failure = take_role_failure("get_function_info", RDMA_QUEUE_ROLE_CQ_RING);
    if (failure == null) failure = take_failure("get_function_info");
    if (failure != null)
      return failure;
    if (function_info_response == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "function info response is not configured");
    info = rdma_mock_clone_function_info(function_info_response);
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_mock_pcie 中，decode_bar 从硬件 image/缓冲区解码字段，验证长度、布局和完整性后返回模型或状态。
  // 输入/输出及副作用：address（输入）、result（输出）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：decode_bar 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  virtual function rdma_status decode_bar(
    rdma_bar_addr_t address,
    output rdma_bar_decode result
  );
    rdma_status failure;

    record_call("decode_bar", '0, '0, '0, '0, null, address);
    result = null;
    failure = take_role_failure("decode_bar", RDMA_QUEUE_ROLE_CQ_RING);
    if (failure == null) failure = take_failure("decode_bar");
    if (failure != null)
      return failure;
    if (decode_response == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "BAR decode response is not configured");
    result = rdma_mock_clone_bar_decode(decode_response);
    return rdma_status::success();
  endfunction
endclass

class rdma_mock_function_table_call extends uvm_object;
  `uvm_object_utils(rdma_mock_function_table_call)

  longint unsigned call_sequence;
  string method_name;
  rdma_function_binding binding;

  // 功能：构造 rdma_mock_function_table_call，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：call_sequence=0；method_name=""；binding=null。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_mock_function_table_call 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_mock_function_table_call");
    super.new(name);
    call_sequence = 0;
    method_name = "";
    binding = null;
  endfunction
endclass

class rdma_mock_function_table extends rdma_function_table_api;
  `uvm_object_utils(rdma_mock_function_table)

  rdma_mock_function_table_call calls[$];
  rdma_status failures[string];
  rdma_status role_failures[string];
  int unsigned method_ordinals[string];
  longint unsigned next_sequence;

  // 功能：构造 rdma_mock_function_table，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：next_sequence=0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_mock_function_table 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_mock_function_table");
    super.new(name);
    next_sequence = 0;
  endfunction

  // 功能：在 rdma_mock_function_table 中，fail_next 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：method_name（输入）、status（输入）；fail_next 读取 method_name、status 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：fail_next 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“unknown function table method”“failure status is null”；失败路径不提交部分状态或转移未声明资源。
  function rdma_status fail_next(string method_name, rdma_status status);
    if (!(method_name inside {
          "program_notify", "clear_notify", "program_dmi", "clear_dmi",
          "program_vft", "clear_vft"
        }))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "unknown function table method");
    if (status == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "failure status is null");
    failures[method_name] = rdma_mock_clone_status(status);
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_mock_function_table 中，fail_role_call 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：method_name（输入）、role（输入）、ordinal（输入）、status（输入）；fail_role_call 读取 method_name、role、ordinal、status 并使用输入参数和固定枚举/常量；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：fail_role_call 无返回值，仅执行 函数体中的顺序操作；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  function void fail_role_call(string method_name,
                               rdma_queue_backing_role_e role,
                               int unsigned ordinal,
                               rdma_status status);
    if (status != null && ordinal != 0)
      role_failures[$sformatf("%s:%0d:%0d", method_name, role, ordinal)] =
        rdma_mock_clone_status(status);
  endfunction

  // 功能：在 rdma_mock_function_table 中，reset reset 清理当前运行状态并建立新的复位/代际边界，使旧句柄或旧事务不能继续生效。
  // 输入/输出及副作用：无显式参数；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：复位参数为零、代际回退或存在未处理 pending 事务时拒绝更新 authority。
  function void reset();
    calls.delete(); failures.delete(); role_failures.delete();
    method_ordinals.delete();
    next_sequence = 0;
  endfunction

  // 功能：在 rdma_mock_function_table 中，take_role_failure 执行 take_role_failure 的take_role_failure 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：method_name（输入）、role（输入）；take_role_failure 读取 method_name、role 并使用字段 ordinal、key、result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：take_role_failure 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  function automatic rdma_status take_role_failure(
    string method_name,
    rdma_queue_backing_role_e role
  );
    string key;
    rdma_status result;
    int unsigned ordinal;

    ordinal = method_ordinals.exists(method_name) ? method_ordinals[method_name] : 0;
    key = $sformatf("%s:%0d:%0d", method_name, role, ordinal);
    if (!role_failures.exists(key)) return null;
    result = rdma_mock_clone_status(role_failures[key]);
    role_failures.delete(key);
    return result;
  endfunction

  // 功能：在 rdma_mock_function_table 中，take_failure 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：method_name（输入）；take_failure 读取 method_name 并使用字段 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：take_failure 输入对象为空或查找未命中时返回 null；该路径不隐式重试，也不转移未声明资源。
  function automatic rdma_status take_failure(string method_name);
    rdma_status result;

    if (!failures.exists(method_name))
      return null;
    result = rdma_mock_clone_status(failures[method_name]);
    failures.delete(method_name);
    return result;
  endfunction

  // 功能：在 rdma_mock_function_table 中，record_call 记录 record_call 的调用名称和顺序，供测试断言转发路径；不改变被测事务业务结果。
  // 输入/输出及副作用：method_name（输入）、binding（输入）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending
  //   journal，并通过 output 返回结果。
  // 失败/边界：记录操作仅影响测试 trace；不得因注入记录故障改变生产状态或吞掉真实错误。
  function void record_call(string method_name,
                            rdma_function_binding binding);
    rdma_mock_function_table_call call_record;

    call_record = rdma_mock_function_table_call::type_id::create(
      $sformatf("table_call_%0d", next_sequence + 1'b1)
    );
    next_sequence++;
    call_record.call_sequence = next_sequence;
    call_record.method_name = method_name;
    method_ordinals[method_name]++;
    call_record.binding = rdma_mock_clone_binding(binding);
    calls.push_back(call_record);
  endfunction

  // 功能：在 rdma_mock_function_table 中，complete_call 提交当前事务阶段并发布 detached 结果，只有成功路径才推进游标或状态。
  // 输入/输出及副作用：method_name（输入）、binding（输入）、status（输出）；complete_call 驱动下游事务，并写入 status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：complete_call 失败或超时通过 status 明确发布；该路径不隐式重试，也不转移未声明资源。
  task automatic complete_call(string method_name,
                               rdma_function_binding binding,
                               output rdma_status status);
    record_call(method_name, binding);
    status = take_role_failure(method_name, RDMA_QUEUE_ROLE_CQ_RING);
    if (status == null) status = take_failure(method_name);
    if (status == null)
      status = rdma_status::success();
  endtask

  // 功能：在 rdma_mock_function_table 中，program_notify 把 program_notify 的配置/编程请求提交到后端适配器，并返回后端确认状态。
  // 输入/输出及副作用：binding（输入）、status（输出）；program_notify 驱动下游事务，并写入 status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：program_notify 遇到后端拒绝、范围溢出或 DMA 权限不足时保留失败证据，不推进本地游标。
  virtual task program_notify(rdma_function_binding binding,
                              output rdma_status status);
    complete_call("program_notify", binding, status);
  endtask

  // 功能：在 rdma_mock_function_table 中，clear_notify 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：binding（输入）、status（输出）；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：clear_notify 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  virtual task clear_notify(rdma_function_binding binding,
                            output rdma_status status);
    complete_call("clear_notify", binding, status);
  endtask

  // 功能：在 rdma_mock_function_table 中，program_dmi 把 program_dmi 的配置/编程请求提交到后端适配器，并返回后端确认状态。
  // 输入/输出及副作用：binding（输入）、status（输出）；program_dmi 驱动下游事务，并写入 status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：program_dmi 遇到后端拒绝、范围溢出或 DMA 权限不足时保留失败证据，不推进本地游标。
  virtual task program_dmi(rdma_function_binding binding,
                           output rdma_status status);
    complete_call("program_dmi", binding, status);
  endtask

  // 功能：在 rdma_mock_function_table 中，clear_dmi 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：binding（输入）、status（输出）；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：clear_dmi 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  virtual task clear_dmi(rdma_function_binding binding,
                         output rdma_status status);
    complete_call("clear_dmi", binding, status);
  endtask

  // 功能：在 rdma_mock_function_table 中，program_vft 把 program_vft 的配置/编程请求提交到后端适配器，并返回后端确认状态。
  // 输入/输出及副作用：binding（输入）、status（输出）；program_vft 驱动下游事务，并写入 status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：program_vft 遇到后端拒绝、范围溢出或 DMA 权限不足时保留失败证据，不推进本地游标。
  virtual task program_vft(rdma_function_binding binding,
                           output rdma_status status);
    complete_call("program_vft", binding, status);
  endtask

  // 功能：在 rdma_mock_function_table 中，clear_vft 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：binding（输入）、status（输出）；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：clear_vft 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  virtual task clear_vft(rdma_function_binding binding,
                         output rdma_status status);
    complete_call("clear_vft", binding, status);
  endtask
endclass

class rdma_mock_net_call extends uvm_object;
  `uvm_object_utils(rdma_mock_net_call)

  longint unsigned call_sequence;
  string method_name;
  rdma_packet packet;
  bit observer_present;
  string observer_type_name;
  string observer_instance_name;
  rdma_net_response_policy policy;
  rdma_net_fault fault;

  // 功能：构造 rdma_mock_net_call，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：call_sequence=0；method_name=""；packet=null；observer_present=1'b0；observer_type_name=""；observer_instance_name=""；policy=null；fault=null。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_mock_net_call 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_mock_net_call");
    super.new(name);
    call_sequence = 0;
    method_name = "";
    packet = null;
    observer_present = 1'b0;
    observer_type_name = "";
    observer_instance_name = "";
    policy = null;
    fault = null;
  endfunction
endclass

class rdma_mock_net extends rdma_net_api;
  `uvm_object_utils(rdma_mock_net)

  rdma_mock_net_call calls[$];
  rdma_status failures[string];
  rdma_net_observer observers[$];
  rdma_packet receive_queue[$];
  longint unsigned next_sequence;

  // 功能：构造 rdma_mock_net，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：next_sequence=0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_mock_net 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_mock_net");
    super.new(name);
    next_sequence = 0;
  endfunction

  // 功能：在 rdma_mock_net 中，fail_next 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：method_name（输入）、status（输入）；fail_next 读取 method_name、status 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：fail_next 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“unknown network method”“failure status is null”；失败路径不提交部分状态或转移未声明资源。
  function rdma_status fail_next(string method_name, rdma_status status);
    if (!(method_name inside {
          "send_packet", "receive_packet", "configure_response_policy",
          "inject_fault"
        }))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "unknown network method");
    if (status == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "failure status is null");
    failures[method_name] = rdma_mock_clone_status(status);
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_mock_net 中，take_failure 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：method_name（输入）；take_failure 读取 method_name 并使用字段 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：take_failure 输入对象为空或查找未命中时返回 null；该路径不隐式重试，也不转移未声明资源。
  function automatic rdma_status take_failure(string method_name);
    rdma_status result;

    if (!failures.exists(method_name))
      return null;
    result = rdma_mock_clone_status(failures[method_name]);
    failures.delete(method_name);
    return result;
  endfunction

  // 功能：在 rdma_mock_net 中，record_call 记录 record_call 的调用名称和顺序，供测试断言转发路径；不改变被测事务业务结果。
  // 输入/输出及副作用：method_name（输入）、packet（输入）、observer（输入）、policy（输入）、fault（输入）；输入 request/image/cursor 决定写入内容；成功时更新
  //   PI/CI、slot ledger 或 pending journal，并通过 output 返回结果。
  // 失败/边界：记录操作仅影响测试 trace；不得因注入记录故障改变生产状态或吞掉真实错误。
  function automatic rdma_mock_net_call record_call(
    string method_name,
    rdma_packet packet = null,
    rdma_net_observer observer = null,
    rdma_net_response_policy policy = null,
    rdma_net_fault fault = null
  );
    rdma_mock_net_call call_record;

    call_record = rdma_mock_net_call::type_id::create(
      $sformatf("net_call_%0d", next_sequence + 1'b1)
    );
    next_sequence++;
    call_record.call_sequence = next_sequence;
    call_record.method_name = method_name;
    call_record.packet = rdma_mock_clone_packet(packet);
    call_record.observer_present = observer != null;
    if (observer != null) begin
      call_record.observer_type_name = observer.get_type_name();
      call_record.observer_instance_name = observer.get_name();
    end
    call_record.policy = rdma_mock_clone_policy(policy);
    call_record.fault = rdma_mock_clone_fault(fault);
    calls.push_back(call_record);
    return call_record;
  endfunction

  // 功能：在 rdma_mock_net 中，enqueue_receive 推进队列/事务游标或执行对应 I/O，并把结果写回声明的输出参数。
  // 输入/输出及副作用：packet（输入）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过 output 返回结果。
  // 失败/边界：队列未激活、credit 不足、请求身份过期或后端写入失败时返回错误；不得提前推进游标或重复提交。
  function void enqueue_receive(rdma_packet packet);
    receive_queue.push_back(rdma_mock_clone_packet(packet));
  endfunction

  // 功能：在 rdma_mock_net 中，send_packet 推进队列/事务游标或执行对应 I/O，并把结果写回声明的输出参数。
  // 输入/输出及副作用：packet（输入）、status（输出）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过
  //   output 返回结果。
  // 失败/边界：队列未激活、credit 不足、请求身份过期或后端写入失败时返回错误；不得提前推进游标或重复提交。
  virtual task send_packet(rdma_packet packet, output rdma_status status);
    rdma_packet observer_packet;

    record_call("send_packet", packet);
    status = take_failure("send_packet");
    if (status != null)
      return;
    if (packet == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "packet is null");
      return;
    end
    foreach (observers[i]) begin
      if (observers[i] != null) begin
        observer_packet = rdma_mock_clone_packet(packet);
        observers[i].write(observer_packet);
      end
    end
    status = rdma_status::success();
  endtask

  // 功能：在 rdma_mock_net 中，receive_packet 推进队列/事务游标或执行对应 I/O，并把结果写回声明的输出参数。
  // 输入/输出及副作用：packet（输出）、status（输出）；receive_packet 驱动下游事务，并写入 packet、status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：receive_packet 返回 RDMA_SC_QUEUE_EMPTY；典型拒绝条件为“receive queue is empty”；失败路径不提交部分状态或转移未声明资源。
  virtual task receive_packet(output rdma_packet packet,
                              output rdma_status status);
    rdma_mock_net_call call_record;

    call_record = record_call("receive_packet");
    packet = null;
    status = take_failure("receive_packet");
    if (status != null)
      return;
    if (receive_queue.size() == 0) begin
      status = rdma_status::make(RDMA_SC_QUEUE_EMPTY,
                                 "receive queue is empty");
      return;
    end
    packet = receive_queue.pop_front();
    call_record.packet = rdma_mock_clone_packet(packet);
    status = rdma_status::success();
  endtask

  // 功能：在 rdma_mock_net 中，register_observer 把 register_observer 指定的资源或后端能力绑定到当前对象索引，并校验 Function、generation 和队列类型一致。
  // 输入/输出及副作用：observer（输入）；register_observer 先依据 observer != null 校验 observer；成功时更新本对象配置/状态并保存非拥有引用，返回 void。
  // 失败/边界：资源不存在、类型不符、重复登记或跨 Function 串线时拒绝绑定并保持索引不变。
  virtual function void register_observer(rdma_net_observer observer);
    record_call("register_observer", null, observer);
    if (observer != null)
      observers.push_back(observer);
  endfunction

  // 功能：在 rdma_mock_net 中，configure_response_policy 校验依赖和 binding 后建立运行边界，只保存非拥有引用并拒绝重复配置。
  // 输入/输出及副作用：policy（输入）；configure_response_policy 先依据 failure != null；policy == null 校验 policy；成功时更新本对象配置/状态并保存非拥有引用，返回 rdma_status。
  // 失败/边界：实现中的空依赖、重复登记、状态或 generation/authority 校验失败时返回错误；失败时保留旧配置。
  virtual function rdma_status configure_response_policy(
    rdma_net_response_policy policy
  );
    rdma_status failure;

    record_call("configure_response_policy", null, null, policy);
    failure = take_failure("configure_response_policy");
    if (failure != null)
      return failure;
    if (policy == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "response policy is null");
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_mock_net 中，inject_fault 执行 inject_fault 的inject_fault 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：fault（输入）；inject_fault 读取 fault 并使用字段 failure；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：inject_fault 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  virtual function rdma_status inject_fault(rdma_net_fault fault);
    rdma_status failure;

    record_call("inject_fault", null, null, null, fault);
    failure = take_failure("inject_fault");
    if (failure != null)
      return failure;
    if (fault == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "network fault is null");
    return rdma_status::success();
  endfunction
endclass
