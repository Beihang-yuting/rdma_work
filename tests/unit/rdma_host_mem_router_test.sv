// 目录：tests/unit/，位于 integration router 的单元测试层。
// 职责：用可控的 Host-memory manager 验证多 Host 相同 IOVA 的隔离、完整 authority
//       ledger、重配置边界和 reset epoch 过期处理。
// 依赖：rdma_host_mem_router、rdma_host_mem_api、UVM；测试 manager 只模拟接口，不拥有
//       生产 Host-memory backing。
// 所有权与生命周期：夹具对象由 UVM 测试创建；router 返回的 mapping 在测试结束前由
//       manager/测试共同管理，测试不触碰外部 Host-memory 实现。
class rdma_test_host_mgr extends rdma_host_mem_api;
  `uvm_object_utils(rdma_test_host_mgr)

  int unsigned tag;

  // 功能：构造带可控 IOVA 标签的测试 Host manager，用于区分不同 Host 路由。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：构造过程不分配 Host-memory、PCIe endpoint 或 manager 资源；空 name 也必须得到可配置对象。
  function new(string name = "mgr");
    super.new(name);
    tag = 0;
  endfunction

  // 功能：模拟 Host-memory allocation，复制请求中的 Function/owner authority 和 requester
  //       BDF，返回一个 active mapping；tag 决定可观察的 IOVA 值。
  // 输入/输出及副作用：request_context（输入）、size（输入）、alignment（输入）、direction（输入）、mapping（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或
  //   output 发布新句柄/映射。
  // 失败/边界：容量不足、范围非法、重复占用或身份过期时返回错误；失败不得泄漏半分配资源。
  function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    uvm_object cloned_object;
    mapping = rdma_dma_mapping::type_id::create("mapping");
    mapping.state = RDMA_MAPPING_ACTIVE;
    mapping.iova.value = tag;
    mapping.size = size;
    mapping.direction = direction;
    cloned_object = request_context.function_h.clone();
    if (!$cast(mapping.function_h, cloned_object))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "test Function clone failed");
    if (request_context.owner_h != null) begin
      cloned_object = request_context.owner_h.clone();
      if (!$cast(mapping.owner_h, cloned_object))
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "test owner clone failed");
    end
    mapping.requester_bdf = request_context.requester_bdf;
    mapping.route = request_context.route;
    mapping.route_valid = request_context.route_valid;
    mapping.reset_epoch = request_context.reset_epoch;
    mapping.epoch_valid = request_context.epoch_valid;
    return rdma_status::success();
  endfunction

  // 功能：模拟写入成功，不实际访问 Host memory；用于确认 router 已完成前置校验。
  // 输入/输出及副作用：mapping（输入）、offset（输入）、data（输入）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending
  //   journal，并通过 output 返回结果。
  // 失败/边界：队列未激活、credit 不足、请求身份过期或后端写入失败时返回错误；不得提前推进游标或重复提交。
  function rdma_status write(
    rdma_dma_mapping mapping,
    longint unsigned offset,
    byte data[]
  );
    return rdma_status::success();
  endfunction

  // 功能：模拟读取成功并返回指定长度的零字节数组；不承担真实 backing 生命周期。
  // 输入/输出及副作用：mapping（输入）、offset（输入）、size（输入）、data（输出）；输入 handle/key/cursor 用于选择读取范围；返回值或 output 为 detached
  //   快照，读取不取得外部资源所有权。
  // 失败/边界：目标不存在、route/authority 不匹配或快照代际失效时返回错误/空值；不得返回陈旧或歧义条目。
  function rdma_status read(
    rdma_dma_mapping mapping,
    longint unsigned offset,
    int unsigned size,
    output byte data[]
  );
    data = new[size];
    return rdma_status::success();
  endfunction

  // 功能：模拟释放成功；router 负责随后删除自身 authority ledger。
  // 输入/输出及副作用：mapping（输入）；输入 handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：目标为空、owner/generation 不匹配、仍有未完成引用或已释放时返回错误；不得二次释放。
  function rdma_status \release (rdma_dma_mapping mapping);
    return rdma_status::success();
  endfunction

  // 功能：声明本测试 manager 的 release_opaque 对 active mapping 满足 failure-atomic 契约。
  // 输入/输出及副作用：mapping 为只读输入；不执行 release，也不修改 mapping 或测试状态。
  // 失败/边界：mapping 为空或非 ACTIVE 时返回错误；不为未知生命周期猜测能力。
  virtual function rdma_status validate_failure_atomic_release(
    rdma_dma_mapping mapping
  );
    if (mapping == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "test failure-atomic mapping is null"
      );
    if (mapping.state != RDMA_MAPPING_ACTIVE)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "test failure-atomic mapping is not active"
      );
    return rdma_status::success();
  endfunction

  // 功能：为 router 的 opaque 路径模拟一次成功释放，并保留普通 release 的测试语义。
  // 输入/输出及副作用：mapping 为释放目标；委托 release，不持有 router parallel ledger。
  // 失败/边界：普通 release 的拒绝结果原样返回；本 helper 不伪造额外 identity。
  virtual function rdma_status release_opaque(rdma_dma_mapping mapping);
    return \release (mapping);
  endfunction
endclass

// 功能：构造一个“分配成功但返回 mapping 路由被篡改”的 Host-memory manager，
//       用于验证 router 在 public geometry/route 校验失败时仍能通过 opaque
//       allocation identity 回滚真实 backing。
// 输入/输出及副作用：继承 mock manager 的真实 allocation ledger；allocate() 只
//       修改返回给 router 的可变 route，release_opaque() 统计回滚调用次数。
// 失败/边界：内部 region 保留未篡改的 allocation token；任何依赖 route/size 查找
//       的普通 release 都不应被用于该故障路径。
class rdma_malformed_host_mgr extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_malformed_host_mgr)

  bit corrupt_route;
  int unsigned opaque_release_calls;

  // 功能：构造可注入 route 畸形返回值的 manager，并清零 opaque release 计数。
  // 输入/输出及副作用：name（输入）；建立本地故障注入状态，不分配 Host backing。
  // 失败/边界：默认开启 route 篡改，测试可显式关闭以复用该 fixture。
  function new(string name = "rdma_malformed_host_mgr");
    super.new(name);
    corrupt_route = 1'b1;
    opaque_release_calls = 0;
  endfunction

  // 功能：先执行真实 mock allocation，再仅篡改返回 alias 的 route，模拟后端
  //       发布不可信 public geometry 的错误实现。
  // 输入/输出及副作用：参数完全转发给父类；成功时更新父类 region ledger，
  //       并可能修改 output mapping 的 route；返回父类状态。
  // 失败/边界：父类分配失败或 mapping 为空时不篡改；route key 溢出时按定宽
  //       算术回绕，router 必须仍以完整 route 比较拒绝。
  virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    rdma_status status;

    status = super.allocate(request_context, size, alignment, direction,
                            mapping);
    if (status != null && status.ok() && mapping != null && corrupt_route)
      mapping.route.host_topology_key++;
    return status;
  endfunction

  // 功能：记录 router 的 opaque rollback 调用，再交由父类按 allocation token
  //       释放 backing；该计数用于确认异常 mapping 没有泄漏。
  // 输入/输出及副作用：mapping（输入）；递增 opaque_release_calls，并可能将
  //       对应 region 标记为 RELEASED；返回父类释放状态。
  // 失败/边界：mapping/token 无效时仍记录调用，父类返回明确错误且不修改其他 region。
  virtual function rdma_status release_opaque(rdma_dma_mapping mapping);
    opaque_release_calls++;
    return super.release_opaque(mapping);
  endfunction
endclass

// 中文设计：manager.allocate() 收到的是 router 生成的工作副本，测试故意在该副本上
// 篡改 route 与 epoch，再让父类按篡改值建立真实 mock backing；router 必须仍以 caller
// 的 immutable snapshot 校验返回 mapping，并通过 opaque token 回滚 backing。
class rdma_mutating_request_host_mgr extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_mutating_request_host_mgr)

  bit mutate_request;
  int unsigned allocate_calls;
  int unsigned opaque_release_calls;

  // 功能：构造可注入 request snapshot 篡改的 Host manager，并清零调用计数。
  // 输入/输出及副作用：name（输入）；初始化故障开关与计数，不分配 Host backing。
  // 失败/边界：默认不篡改请求；只有 mutate_request=1 时才在父类 allocation 前改变工作副本。
  function new(string name = "rdma_mutating_request_host_mgr");
    super.new(name);
    mutate_request = 1'b0;
    allocate_calls = 0;
    opaque_release_calls = 0;
  endfunction

  // 功能：记录 allocation 次数，并在父类建立 backing 前篡改 manager 工作副本的 route
  //       与 reset epoch，模拟不可信 adapter 试图自改 authority 的边界。
  // 输入/输出及副作用：request_context（输入，可被本 helper 修改）、size/alignment/direction
  //   （输入）、mapping（输出）；父类成功时创建可由 opaque token 回滚的 mock allocation。
  // 失败/边界：request_context 为空时不解引用；父类失败原样返回，router 仍需处理任何
  //   success+mapping 的 authority 不匹配并清理 backing。
  virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    rdma_status status;

    allocate_calls++;
    if (mutate_request && request_context != null) begin
      request_context.route.host_topology_key++;
      request_context.reset_epoch++;
    end
    status = super.allocate(
      request_context, size, alignment, direction, mapping
    );
    return status;
  endfunction

  // 功能：记录 opaque rollback 调用，并依据父类 allocation token 释放被篡改请求产生的
  //       backing，验证 router 没有因 public authority 失败泄漏资源。
  // 输入/输出及副作用：mapping（输入）；递增 opaque_release_calls，成功时更新父类 region
  //   ledger；不修改 router parallel ledger。
  // 失败/边界：mapping/token 无效时仍记录调用，父类返回错误且保留未匹配 backing 供诊断。
  virtual function rdma_status release_opaque(rdma_dma_mapping mapping);
    opaque_release_calls++;
    return super.release_opaque(mapping);
  endfunction
endclass

// 中文设计：router 的 failure-atomic 测试需要把 validator 与实际 release 两个
// 外部返回点分别置为 non-OK/null，同时保留 mock 的真实 opaque allocation ledger。
// 该 fixture 只增加一次性故障与调用计数，不替代 mock 的 identity 校验。
class rdma_failure_atomic_router_mgr extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_failure_atomic_router_mgr)

  int unsigned validation_calls;
  int unsigned opaque_release_calls;
  bit return_null_validation_once;
  bit return_null_release_once;
  bit return_null_write_once;
  bit return_null_read_once;
  bit return_null_plain_release_once;
  rdma_status next_validation_failure;

  // 功能：构造 failure-atomic router manager，并清零一次性故障和调用计数。
  // 输入/输出及副作用：name 为 UVM 对象名；只初始化测试控制字段，不分配 backing。
  // 失败/边界：默认无故障；只有测试显式设置的下一次调用会偏离父类行为。
  function new(string name = "rdma_failure_atomic_router_mgr");
    super.new(name);
    validation_calls = 0;
    opaque_release_calls = 0;
    return_null_validation_once = 1'b0;
    return_null_release_once = 1'b0;
    return_null_write_once = 1'b0;
    return_null_read_once = 1'b0;
    return_null_plain_release_once = 1'b0;
    next_validation_failure = null;
  endfunction

  // 功能：记录 capability 查询，并可在委托真实 mock identity 校验前注入一次 null/non-OK。
  // 输入/输出及副作用：mapping 为只读 opaque authority；递增 validation_calls，消费一次故障。
  // 失败/边界：null/non-OK 注入不修改 region、mapping、release seal 或 bytes。
  virtual function rdma_status validate_failure_atomic_release(
    rdma_dma_mapping mapping
  );
    rdma_status failure;

    validation_calls++;
    if (return_null_validation_once) begin
      return_null_validation_once = 1'b0;
      return null;
    end
    if (next_validation_failure != null) begin
      failure = next_validation_failure;
      next_validation_failure = null;
      return failure;
    end
    return super.validate_failure_atomic_release(mapping);
  endfunction

  // 功能：记录 opaque release，并可在父类 seal/region mutation 前返回一次 null。
  // 输入/输出及副作用：mapping 为释放 authority；递增 opaque_release_calls，成功才委托父类。
  // 失败/边界：null 注入保持 allocation 可读可重试；其他失败由父类原样返回。
  virtual function rdma_status release_opaque(rdma_dma_mapping mapping);
    opaque_release_calls++;
    if (return_null_release_once) begin
      return_null_release_once = 1'b0;
      return null;
    end
    return super.release_opaque(mapping);
  endfunction

  // 功能：在 router 普通 write 边界注入一次 null status，验证数据写入失败时不崩溃。
  // 输入/输出及副作用：mapping、offset、data 为输入；故障时不修改 mock backing，随后恢复父类行为。
  // 失败/边界：null 返回必须由 router 转换为 INVALID_STATE，不能被当成成功或继续推进 ledger。
  virtual function rdma_status write(
    rdma_dma_mapping mapping,
    longint unsigned offset,
    byte data[]
  );
    if (return_null_write_once) begin
      return_null_write_once = 1'b0;
      return null;
    end
    return super.write(mapping, offset, data);
  endfunction

  // 功能：在 router 普通 read 边界注入一次 null status，验证输出数据会被清空。
  // 输入/输出及副作用：mapping、offset、size 为输入，data 为输出；故障时清空 data 并不改 backing。
  // 失败/边界：null 返回必须转换为 INVALID_STATE，调用方不得消费旧的 read buffer。
  virtual function rdma_status read(
    rdma_dma_mapping mapping,
    longint unsigned offset,
    int unsigned size,
    output byte data[]
  );
    if (return_null_read_once) begin
      return_null_read_once = 1'b0;
      data = new[0];
      return null;
    end
    return super.read(mapping, offset, size, data);
  endfunction

  // 功能：在 router 普通 release 边界注入一次 null status，验证 authority row 保留可重试。
  // 输入/输出及副作用：mapping 为释放输入；故障时不修改 mock allocation 或 release seal。
  // 失败/边界：null 返回必须转换为 INVALID_STATE，router 不得删除自身 parallel ledger。
  virtual function rdma_status \release (rdma_dma_mapping mapping);
    if (return_null_plain_release_once) begin
      return_null_plain_release_once = 1'b0;
      return null;
    end
    return super.\release (mapping);
  endfunction
endclass

// 中文设计：Host manager 是 router 的外部可重入边界；该 fixture 在一次 allocate() 进入
// manager 时同步开启 reset transaction，模拟 adapter callback 在 router 提交 ledger 前
// 改变 coordinator admission。父类仍负责建立真实 opaque allocation，便于断言 router
// 在拒绝提交后确实执行回滚而不泄漏 backing。
class rdma_reentrant_reset_host_mgr extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_reentrant_reset_host_mgr)

  rdma_reset_coordinator callback_coordinator;
  uvm_object callback_owner;
  longint unsigned callback_token;
  bit trigger_reset_once;
  int unsigned callback_calls;
  rdma_status callback_status;

  // 功能：构造可注入同步 reset callback 的 Host manager，并清空 callback 控制字段。
  // 输入/输出及副作用：name（输入）；初始化本地 fixture 状态，不创建 coordinator、lease
  // 或 Host backing；父类仍建立空 allocation ledger。
  // 失败/边界：默认不触发 callback；调用方必须先提供有效 coordinator、owner/token，才能
  // 开启 trigger_reset_once，否则该 fixture 只执行父类 allocation。
  function new(string name = "rdma_reentrant_reset_host_mgr");
    super.new(name);
    callback_coordinator = null;
    callback_owner = null;
    callback_token = 0;
    trigger_reset_once = 1'b0;
    callback_calls = 0;
    callback_status = null;
  endfunction

  // 功能：在第一次启用 callback 的 allocate() 中同步调用 coordinator.begin_reset()，随后
  //       委托父类建立可通过 opaque identity 回滚的 mapping。
  // 输入/输出及副作用：request_context/size/alignment/direction/mapping（输入/输出）仍按
  //   Host API 传递；成功触发时更新 callback_status/callback_calls，并可能使 coordinator
  //   transaction active；父类随后可能写入 regions/calls。
  // 失败/边界：callback 条件不完整或 begin_reset() 拒绝时仍执行父类 allocation，router
  //   必须依据当前 admission 结果决定是否提交；trigger_reset_once 只消费一次，避免污染
  //   后续正常分配。
  virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    if (trigger_reset_once && callback_coordinator != null &&
        callback_owner != null && callback_token != 0) begin
      trigger_reset_once = 1'b0;
      callback_calls++;
      callback_status = callback_coordinator.begin_reset(
        callback_owner, callback_token
      );
    end
    return super.allocate(request_context, size, alignment, direction, mapping);
  endfunction
endclass

// 中文设计：router allocation 的 coordinator authority 由 reset coordinator 持有；
// 测试需要在合法 registration 之后构造一个重复 UID ledger，才能覆盖
// validate_registered_function_handle() 的 fail-closed 分支。该 probe 只向受保护
// ledger 注入 detached identity，不改变生产 registration API 或 router 生命周期。
class rdma_host_mem_router_reset_probe extends rdma_reset_coordinator;
  `uvm_object_utils(rdma_host_mem_router_reset_probe)

  // 功能：构造用于 router allocation authority 测试的 reset coordinator probe，沿用
  //       生产 coordinator 的空 Function/epoch ledger。
  // 输入/输出及副作用：name（输入）；调用基类构造，不创建或接管 Host router、Function
  //       identity 或 manager 资源。
  // 失败/边界：probe 只用于构造重复 UID 故障；未完成正常 registration 时不得把注入
  //       ledger 当作有效业务状态。
  function new(string name = "rdma_host_mem_router_reset_probe");
    super.new(name);
  endfunction

  // 功能：把 source 的 detached identity 复制到独立 ledger key，故意制造与现有
  //       registration 相同的 Function UID，以验证 router allocation 在 manager 调用前
  //       拒绝重复 UID authority。
  // 输入/输出及副作用：source（输入）被 clone 后写入 m_functions[injected_key]，并为该
  //       key 建立 registration/absolute epoch baseline；函数不修改 source、router 或
  //       外部 backing，返回 void。
  // 失败/边界：source 为空、clone 返回 null 或类型转换失败时保持 ledger 不变；injected_key
  //       仅允许测试使用，调用方必须在断言后调用 remove_injected_function() 清理三张 map。
  function void inject_duplicate_uid(
    rdma_function_identity source,
    string injected_key
  );
    uvm_object cloned_object;
    rdma_function_identity copy;

    if (source == null)
      return;
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(copy, cloned_object))
      return;
    m_functions[injected_key] = copy;
    m_function_registration_epochs[injected_key] = 0;
    m_function_epochs[injected_key] = 0;
  endfunction

  // 功能：删除 inject_duplicate_uid() 创建的测试 alias，恢复 coordinator 的 Function
  //       snapshot、registration baseline 和 absolute epoch ledger，供后续场景继续使用。
  // 输入/输出及副作用：injected_key（输入）从三张受保护 map 中删除；函数无返回值，不
  //       触碰其它 registration、Host router 绑定或 reset epoch。
  // 失败/边界：key 不存在时 delete 保持幂等；该 helper 不是生产 unregister API，调用方
  //       不得用它绕过 Function 生命周期契约。
  function void remove_injected_function(string injected_key);
    m_functions.delete(injected_key);
    m_function_registration_epochs.delete(injected_key);
    m_function_epochs.delete(injected_key);
  endfunction

  // 功能：在不启动 reset transaction 的情况下打开 coordinator 的同步 publication
  //       guard，供 Batch112 验证 router tokenless dataplane 在 publication-only 窗口也会
  //       fail-closed。
  // 输入/输出及副作用：无输入；调用受保护的 enter_reset_operation()，成功时只设置
  //   coordinator 内部同步 guard 并返回 status，不修改 Function/Host/Device epoch 或 lease。
  // 失败/边界：已有 publication guard 时返回 RESOURCE_BUSY 且不改变原 guard；该 probe 仅供
  //   测试构造同步 callback 窗口，生产代码不通过公开 API 暴露此入口。
  function rdma_status enter_publication_probe();
    return enter_reset_operation();
  endfunction

  // 功能：关闭 enter_publication_probe() 建立的同步 publication guard，恢复测试夹具的
  //       tokenless dataplane 正常 admission 状态。
  // 输入/输出及副作用：无输入；调用受保护的 leave_reset_operation()，只清除同步 guard，
  //   不回滚已提交的 epoch、mapping 或 lease。
  // 失败/边界：重复清除保持幂等；调用方必须在 probe 场景的所有正常返回路径调用本函数，
  //   否则后续测试会持续观察 RESOURCE_BUSY。
  function void leave_publication_probe();
    leave_reset_operation();
  endfunction
endclass

// 中文设计：parallel ledger 是 router 自己的 authority；测试只暴露只读行数，
// 避免用 reconfigure 的间接结果替代“失败分支未删除 exact row”的断言。
class rdma_host_mem_router_probe extends rdma_host_mem_router;
  `uvm_object_utils(rdma_host_mem_router_probe)

  // 功能：构造空 router probe；全部生产状态和生命周期仍由父类维护。
  // 输入/输出及副作用：name 为 UVM 对象名；仅调用父类构造，不创建 manager/backing。
  // 失败/边界：未 configure 时 ledger_count 返回零，其他业务入口沿父类拒绝。
  function new(string name = "rdma_host_mem_router_probe");
    super.new(name);
  endfunction

  // 功能：只读返回 router 当前 mapping parallel ledger 行数，供 failure-atomic 断言。
  // 输入/输出及副作用：无输入；返回 m_maps.size()，不暴露可变 row handle。
  // 失败/边界：空 ledger 返回零；函数不调用 manager 或修改任一 parallel array。
  function int unsigned ledger_count();
    return m_maps.size();
  endfunction

  // 功能：按对象身份只读确认 router 是否已经绑定指定 reset coordinator，供 capability
  //       spoof/replay 测试断言拒绝路径没有发布单侧 coordinator 引用。
  // 输入/输出及副作用：expected（输入）为待比较的 coordinator；函数只读取 m_reset，返回
  //       对象句柄身份比较结果，不修改 mapping、route 或任何 lifecycle ledger。
  // 失败/边界：expected 为 null 时仅在 router 也未绑定 coordinator 时返回 1；不同对象、
  //       已清除绑定或未知 router 状态返回 0，调用方不能把“未绑定”解释为 attach 成功。
  function bit has_reset_coordinator(rdma_reset_coordinator expected);
    return m_reset === expected;
  endfunction
endclass

class rdma_host_mem_router_test extends uvm_test;
  `uvm_component_utils(rdma_host_mem_router_test)

  // 功能：构造 UVM 测试组件；场景搭建和断言集中在 run_phase()。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：构造过程不分配 Host-memory、PCIe endpoint 或 manager 资源；空 name 也必须得到可配置对象。
  function new(string name = "rdma_host_mem_router_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：按 Host key 构造带完整 route、requester BDF 和初始 epoch 的 DMA 请求上下文，
  //       供两个 Host 使用相同 IOVA 的隔离测试复用。
  // 输入/输出及副作用：host_key（输入）、function_h（输入）、owner_h（输入）；make_context 读取 host_key、function_h、owner_h 并使用字段 request_context、request_context.function_h、request_context.owner_h、route.host_topology_key、route.root_id、route.segment、route.bdf、request_context.requester_bdf；函数返回 rdma_dma_request_context，不取得调用方资源所有权。
  // 失败/边界：输入为空、类型不匹配或字段组合非法时返回空值/错误；不得发布不完整快照。
  function automatic rdma_dma_request_context make_context(
    int unsigned host_key,
    rdma_function_handle function_h,
    rdma_handle owner_h
  );
    rdma_dma_request_context request_context;
    request_context = rdma_dma_request_context::type_id::create(
      $sformatf("host_%0d_context", host_key));
    request_context.function_h = function_h;
    request_context.owner_h = owner_h;
    request_context.route.host_topology_key = host_key;
    request_context.route.root_id = host_key;
    request_context.route.segment = 0;
    request_context.route.bdf = '{segment:0, bus:1,
                                  device:host_key[4:0], function_num:0};
    request_context.requester_bdf = request_context.route.bdf;
    request_context.route_valid = 1'b1;
    request_context.reset_epoch = 0;
    request_context.epoch_valid = 1'b1;
    return request_context;
  endfunction

  // 功能：执行 Host-memory router 回归场景，检查跨 Host 路由、active mapping 重配置、
  //       authority 篡改、Host reset 过期、缺失 epoch 请求以及 Batch109 coordinator
  //       lease/detach 生命周期错误路径。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：仿真超时、事务返回错误或断言不满足时报告 UVM_ERROR/UVM_FATAL；空 fixture 不得被当作成功。
  task run_phase(uvm_phase phase);
    rdma_host_mem_router router;
    rdma_host_mem_route_entry entries[$];
    rdma_test_host_mgr manager0, manager1;
    rdma_dma_request_context context0, context1, missing_epoch;
    rdma_function_handle function_h;
    rdma_handle owner_h;
    rdma_dma_mapping mapping0, mapping1;
    rdma_host_mem_router_probe mutation_router;
    rdma_mutating_request_host_mgr mutation_manager;
    rdma_host_mem_route_entry mutation_entry;
    rdma_host_mem_route_entry mutation_entries[$];
    rdma_dma_mapping mutation_mapping;
    rdma_host_mem_router detached_router;
    rdma_mock_host_mem opaque_manager;
    rdma_malformed_host_mgr malformed_manager;
    rdma_host_mem_route_entry detached_entry;
    rdma_host_mem_route_entry malformed_entry;
    rdma_dma_mapping detached_mapping, detached_authority;
    rdma_dma_mapping malformed_mapping;
    rdma_host_mem_router_probe atomic_router;
    rdma_failure_atomic_router_mgr atomic_manager;
    rdma_mock_host_mem foreign_manager;
    rdma_host_mem_route_entry atomic_entry;
    rdma_host_mem_route_entry atomic_entries[$];
    rdma_dma_mapping atomic_mapping;
    rdma_dma_mapping atomic_authority;
    rdma_dma_mapping foreign_mapping;
    rdma_dma_mapping default_mapping;
    // reset rebuild canonical-epoch fixture：coordinator 会在 Host/Device reset
    // 时同时推进 Function incarnation 与独立 Host/Device ledger；fresh request
    // 必须携带重建 identity 的 Function reset_epoch，而不是四维计数之和。
    rdma_host_mem_router canonical_router;
    rdma_test_host_mgr canonical_manager;
    rdma_host_mem_route_entry canonical_entry;
    rdma_host_mem_route_entry canonical_entries[$];
    rdma_reset_coordinator canonical_coordinator;
    rdma_function_identity canonical_identity;
    rdma_function_handle canonical_function_h;
    rdma_dma_request_context canonical_context;
    rdma_dma_mapping canonical_mapping;
    rdma_dma_mapping canonical_host_mapping;
    rdma_dma_mapping canonical_device_mapping;
    rdma_function_key_t canonical_key;
    // Batch109 生命周期夹具：单独的 coordinator/owner pair 与 active mapping，用于
    // 验证跨 coordinator rebind、双侧 detach 和 lease release 的失败原子性。
    rdma_reset_coordinator lifecycle_coordinator_a;
    rdma_reset_coordinator lifecycle_coordinator_b;
    rdma_host_mem_router lifecycle_router;
    rdma_test_host_mgr lifecycle_manager;
    rdma_host_mem_route_entry lifecycle_entry;
    rdma_host_mem_route_entry lifecycle_entries[$];
    rdma_host_mem_router_probe lifecycle_unbound_router;
    rdma_host_mem_route_entry forged_capability;
    rdma_function_identity lifecycle_identity;
    rdma_function_key_t lifecycle_key;
    rdma_function_handle lifecycle_function_h;
    rdma_dma_request_context lifecycle_context;
    rdma_dma_mapping lifecycle_mapping;
    uvm_object lifecycle_owner_a;
    uvm_object lifecycle_owner_b;
    longint unsigned lifecycle_token_a;
    longint unsigned lifecycle_token_b;
    rdma_status authority_status;
    rdma_host_mem_route_entry detached_entries[$];
    byte data[];
    byte atomic_bytes[] = '{8'h19, 8'h2a, 8'h3b, 8'h4c};
    bit release_done;
    int unsigned validation_calls_before;
    // coordinator-bound allocation authority fixture：同一 router 先覆盖 unknown UID，
    // 再由 probe 注入 duplicate UID；两条拒绝路径都必须在 manager.allocate() 前结束。
    rdma_host_mem_router_probe authority_router;
    rdma_host_mem_router_reset_probe authority_coordinator;
    rdma_mutating_request_host_mgr authority_manager;
    rdma_host_mem_route_entry authority_entry;
    rdma_host_mem_route_entry authority_entries[$];
    rdma_function_identity authority_identity;
    rdma_function_key_t authority_key;
    rdma_function_handle authority_function_h;
    rdma_function_handle unknown_function_h;
    rdma_dma_request_context authority_context;
    rdma_dma_request_context unknown_context;
    rdma_dma_request_context duplicate_context;
    rdma_dma_mapping rejected_mapping;
    int unsigned authority_allocate_calls_before;
    int unsigned authority_manager_calls_before;
    int unsigned authority_live_before;
    int unsigned authority_ledger_before;
    // Batch112 tokenless dataplane admission fixture：leased router 仍可正常访问，
    // begin_reset() 后只允许 release/release_opaque 作为 cleanup seam 排空 mapping。
    rdma_host_mem_router_reset_probe dataplane_coordinator;
    rdma_host_mem_router_probe dataplane_router;
    rdma_reentrant_reset_host_mgr dataplane_manager;
    rdma_host_mem_route_entry dataplane_entry;
    rdma_host_mem_route_entry dataplane_entries[$];
    rdma_function_identity dataplane_identity;
    rdma_function_key_t dataplane_key;
    rdma_function_handle dataplane_function_h;
    rdma_dma_request_context dataplane_context;
    rdma_dma_mapping dataplane_mapping;
    rdma_dma_mapping dataplane_reentrant_mapping;
    rdma_dma_mapping dataplane_rejected_mapping;
    rdma_dma_mapping dataplane_opaque_mapping;
    rdma_dma_mapping dataplane_stale_mapping;
    rdma_dma_mapping dataplane_post_reset_mapping;
    uvm_object dataplane_owner;
    longint unsigned dataplane_token;
    int unsigned dataplane_ledger_before;
    int unsigned dataplane_allocate_calls_before;
    int unsigned dataplane_write_calls_before;
    int unsigned dataplane_read_calls_before;
    rdma_status status;

    phase.raise_objection(this);
    router = rdma_host_mem_router::type_id::create("router");
    manager0 = rdma_test_host_mgr::type_id::create("manager0");
    manager1 = rdma_test_host_mgr::type_id::create("manager1");
    manager0.tag = 32'h1000;
    manager1.tag = 32'h1000;
    entries.push_back(rdma_host_mem_route_entry::type_id::create("entry0"));
    entries[0].host_topology_key = 0;
    entries[0].manager = manager0;
    entries.push_back(rdma_host_mem_route_entry::type_id::create("entry1"));
    entries[1].host_topology_key = 1;
    entries[1].manager = manager1;
    status = router.configure(entries);
    if (!status.ok())
      `uvm_fatal("HOST_ROUTE", "configure failed")

    function_h = rdma_function_handle::type_id::create("function_h");
    function_h.function_uid = 1;
    function_h.object_id = 7;
    function_h.generation = 1;
    owner_h = rdma_handle::type_id::create("owner_h");
    owner_h.kind = RDMA_RESOURCE_QP;
    owner_h.function_uid = function_h.function_uid;
    owner_h.object_id = 55;
    owner_h.generation = function_h.generation;

    context0 = make_context(0, function_h, owner_h);
    context1 = make_context(1, function_h, owner_h);
    status = router.allocate(context0, 16, 4, RDMA_DMA_DEVICE_READ,
                             mapping0);
    if (!status.ok() || mapping0 == null)
      `uvm_fatal("HOST_ROUTE", "Host0 allocation failed")
    status = router.allocate(context1, 16, 4, RDMA_DMA_DEVICE_READ,
                             mapping1);
    if (!status.ok() || mapping1 == null)
      `uvm_fatal("HOST_ROUTE", "Host1 allocation failed")
    if (mapping0.iova.value != mapping1.iova.value ||
        mapping0.route.host_topology_key == mapping1.route.host_topology_key)
      `uvm_error("HOST_ROUTE", "same IOVA did not retain independent Host routes")

    // active mapping 时修改路由表会破坏 manager ownership，必须拒绝。
    status = router.configure(entries);
    if (status.code != RDMA_SC_RESOURCE_BUSY)
      `uvm_error("HOST_ROUTE", "active mapping reconfigure was accepted")

    // mapping 暴露给调用方后仍是可变对象，router 的私有 ledger 必须抓住
    // owner authority 篡改，不能把访问转交给底层 manager。
    mapping0.owner_h.object_id++;
    status = router.read(mapping0, 0, 1, data);
    if (status.code != RDMA_SC_DMA_TRANSLATION)
      `uvm_error("HOST_ROUTE", "modified mapping owner was accepted")
    mapping0.owner_h.object_id--;

    router.advance_host_epoch(1);
    status = router.read(mapping1, 0, 1, data);
    if (status.code != RDMA_SC_STALE_GENERATION)
      `uvm_error("HOST_ROUTE", "stale Host epoch was not rejected")
    // Reset cleanup is allowed to drain an otherwise valid old mapping, while
    // normal read/write access remains blocked by the stale epoch above.
    status = router.\release (mapping1);
    if (status == null || !status.ok())
      `uvm_error("HOST_ROUTE", "stale mapping release was not allowed")

    missing_epoch = make_context(0, function_h, owner_h);
    missing_epoch.epoch_valid = 1'b0;
    status = router.allocate(missing_epoch, 16, 4, RDMA_DMA_DEVICE_READ,
                             mapping1);
    if (status.ok())
      `uvm_error("HOST_ROUTE", "DMA request without epoch was accepted")

    // coordinator-bound router allocation 的 authority 预检必须发生在
    // manager.allocate() 之前。先登记一个合法 PF，随后分别提交 unknown UID
    // 与 coordinator ledger 中的 duplicate UID；两条失败路径都不得产生 backing、
    // router parallel row 或 manager call。
    authority_router = rdma_host_mem_router_probe::type_id::create(
      "authority_router"
    );
    authority_manager = rdma_mutating_request_host_mgr::type_id::create(
      "authority_manager"
    );
    authority_entry = rdma_host_mem_route_entry::type_id::create(
      "authority_entry"
    );
    authority_entry.host_topology_key = 8;
    authority_entry.manager = authority_manager;
    authority_entries.push_back(authority_entry);
    status = authority_router.configure(authority_entries);
    if (status == null || !status.ok())
      `uvm_fatal("HOST_ROUTE_AUTHORITY", "authority router configure failed")

    authority_coordinator = rdma_host_mem_router_reset_probe::type_id::create(
      "authority_coordinator"
    );
    status = authority_coordinator.attach_host_router_status(authority_router);
    if (status == null || !status.ok() ||
        !authority_router.has_reset_coordinator(authority_coordinator))
      `uvm_fatal("HOST_ROUTE_AUTHORITY", "authority coordinator attach failed")

    authority_key = '0;
    authority_key.host_topology_key = 8;
    authority_key.root_id = 8;
    authority_key.function_kind = RDMA_FUNCTION_PF;
    authority_key.vf_index = 0;
    authority_key.bdf = '{segment:0, bus:1, device:8, function_num:0};
    authority_key.parent_pf_bdf = '0;
    authority_identity = rdma_function_identity::type_id::create(
      "authority_identity"
    );
    status = authority_identity.configure(
      authority_key, 32'h808, 64'h0000_0000_0000_0808, 1, 0
    );
    if (status == null || !status.ok())
      `uvm_fatal("HOST_ROUTE_AUTHORITY", "authority identity configure failed")
    authority_coordinator.register_function(authority_identity);

    authority_function_h = rdma_function_handle::type_id::create(
      "authority_function_h"
    );
    authority_function_h.kind = RDMA_RESOURCE_FUNCTION;
    authority_function_h.function_uid = authority_identity.function_uid;
    authority_function_h.object_id = authority_identity.global_function_id;
    authority_function_h.generation = authority_identity.generation;
    authority_context = make_context(8, authority_function_h, null);
    authority_context.reset_epoch = authority_identity.reset_epoch;

    unknown_function_h = rdma_function_handle::type_id::create(
      "unknown_function_h"
    );
    unknown_function_h.kind = RDMA_RESOURCE_FUNCTION;
    unknown_function_h.function_uid = 64'hffff_0000_0000_0808;
    unknown_function_h.object_id = authority_function_h.object_id;
    unknown_function_h.generation = authority_function_h.generation;
    unknown_context = rdma_dma_request_context::type_id::create(
      "unknown_uid_context"
    );
    unknown_context.copy(authority_context);
    unknown_context.function_h = unknown_function_h;
    authority_allocate_calls_before = authority_manager.allocate_calls;
    authority_manager_calls_before = authority_manager.calls.size();
    authority_live_before = authority_manager.live_allocations();
    authority_ledger_before = authority_router.ledger_count();
    rejected_mapping = null;
    status = authority_router.allocate(
      unknown_context, 32, 8, RDMA_DMA_DEVICE_READ, rejected_mapping
    );
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        rejected_mapping != null ||
        authority_manager.allocate_calls != authority_allocate_calls_before ||
        authority_manager.calls.size() != authority_manager_calls_before ||
        authority_manager.live_allocations() != authority_live_before ||
        authority_router.ledger_count() != authority_ledger_before)
      `uvm_error(
        "HOST_ROUTE_AUTHORITY_UNKNOWN_UID",
        "unknown Function UID reached manager or changed allocation ledger"
      )

    // 通过测试专用 probe 注入第二个同 UID snapshot；合法 UID 本身不能掩盖
    // ledger duplication，router 必须仍返回 INVALID_STATE 且不触碰 manager。
    authority_coordinator.inject_duplicate_uid(
      authority_identity, "router_duplicate_uid_alias"
    );
    duplicate_context = rdma_dma_request_context::type_id::create(
      "duplicate_uid_context"
    );
    duplicate_context.copy(authority_context);
    authority_allocate_calls_before = authority_manager.allocate_calls;
    authority_manager_calls_before = authority_manager.calls.size();
    authority_live_before = authority_manager.live_allocations();
    authority_ledger_before = authority_router.ledger_count();
    rejected_mapping = null;
    status = authority_router.allocate(
      duplicate_context, 32, 8, RDMA_DMA_DEVICE_READ, rejected_mapping
    );
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        rejected_mapping != null ||
        authority_manager.allocate_calls != authority_allocate_calls_before ||
        authority_manager.calls.size() != authority_manager_calls_before ||
        authority_manager.live_allocations() != authority_live_before ||
        authority_router.ledger_count() != authority_ledger_before)
      `uvm_error(
        "HOST_ROUTE_AUTHORITY_DUPLICATE_UID",
        "duplicate Function UID reached manager or changed allocation ledger"
      )
    authority_coordinator.remove_injected_function(
      "router_duplicate_uid_alias"
    );

    // manager 只能修改 router 传给它的工作副本；若它把 route/epoch 改后再返回
    // success，router 必须依据 caller snapshot 拒绝并用 opaque token 回滚 backing。
    mutation_router = rdma_host_mem_router_probe::type_id::create(
      "mutation_router"
    );
    mutation_manager = rdma_mutating_request_host_mgr::type_id::create(
      "mutation_manager"
    );
    mutation_manager.mutate_request = 1'b1;
    mutation_entry = rdma_host_mem_route_entry::type_id::create(
      "mutation_entry"
    );
    mutation_entry.host_topology_key = 0;
    mutation_entry.manager = mutation_manager;
    mutation_entries.push_back(mutation_entry);
    status = mutation_router.configure(mutation_entries);
    if (status == null || !status.ok())
      `uvm_fatal("HOST_ROUTE_MUTATION", "mutation router configure failed")
    mutation_mapping = null;
    status = mutation_router.allocate(
      context0, 16, 4, RDMA_DMA_DEVICE_READ, mutation_mapping
    );
    if (status == null || status.code != RDMA_SC_DMA_TRANSLATION ||
        mutation_mapping != null || mutation_manager.allocate_calls != 1 ||
        mutation_manager.opaque_release_calls != 1 ||
        mutation_manager.live_allocations() != 0 ||
        mutation_router.ledger_count() != 0 ||
        context0.route.host_topology_key != 0 || context0.reset_epoch != 0)
      `uvm_error(
        "HOST_ROUTE_MUTATION",
        "manager-mutated request authority was accepted or leaked"
      )

    // Host/Device reset rebuild contract：identity.reset_epoch 是唯一公开给
    // request_context/mapping 的 canonical scalar；router-local Host、coordinator
    // Host 和 Device epoch 只作为独立 stale dimensions 保存。先登记一个与
    // route 完全一致的 PF，再验证两种级联 reset 后 fresh allocation 不会把
    // Function epoch 与其它维度重复相加。
    canonical_router = rdma_host_mem_router::type_id::create(
      "canonical_epoch_router"
    );
    canonical_manager = rdma_test_host_mgr::type_id::create(
      "canonical_epoch_manager"
    );
    canonical_manager.tag = 32'h2100;
    canonical_entry = rdma_host_mem_route_entry::type_id::create(
      "canonical_epoch_entry"
    );
    canonical_entry.host_topology_key = 2;
    canonical_entry.manager = canonical_manager;
    canonical_entries.push_back(canonical_entry);
    status = canonical_router.configure(canonical_entries);
    if (status == null || !status.ok())
      `uvm_fatal("HOST_ROUTE_EPOCH", "canonical epoch router configure failed")

    canonical_coordinator = rdma_reset_coordinator::type_id::create(
      "canonical_epoch_coordinator"
    );
    canonical_coordinator.attach_host_router(canonical_router);
    canonical_key = '0;
    canonical_key.host_topology_key = 2;
    canonical_key.root_id = 2;
    canonical_key.function_kind = RDMA_FUNCTION_PF;
    canonical_key.vf_index = 0;
    canonical_key.bdf = '{segment:0, bus:1, device:2, function_num:0};
    canonical_key.parent_pf_bdf = '0;
    canonical_identity = rdma_function_identity::type_id::create(
      "canonical_epoch_identity"
    );
    status = canonical_identity.configure(
      canonical_key, 7, 2, 1, 0
    );
    if (status == null || !status.ok())
      `uvm_fatal("HOST_ROUTE_EPOCH", "canonical epoch identity configure failed")
    canonical_coordinator.register_function(canonical_identity);

    canonical_function_h = rdma_function_handle::type_id::create(
      "canonical_epoch_function_h"
    );
    canonical_function_h.function_uid = canonical_identity.function_uid;
    canonical_function_h.object_id = canonical_identity.global_function_id;
    canonical_function_h.generation = canonical_identity.generation;
    canonical_context = make_context(2, canonical_function_h, null);
    canonical_context.reset_epoch = canonical_identity.reset_epoch;
    status = canonical_router.allocate(
      canonical_context, 32, 8, RDMA_DMA_DEVICE_READ, canonical_mapping
    );
    if (status == null || !status.ok() || canonical_mapping == null ||
        canonical_mapping.reset_epoch != canonical_context.reset_epoch)
      `uvm_fatal(
        "HOST_ROUTE_EPOCH",
        "initial canonical epoch allocation failed"
      )

    status = canonical_coordinator.request_host_reset(2);
    if (status == null || !status.ok() ||
        canonical_coordinator.host_epoch(2) != 1 ||
        canonical_coordinator.function_epoch_uid(
          canonical_identity.function_uid
        ) != 1)
      `uvm_fatal("HOST_ROUTE_EPOCH", "Host reset epoch publication failed")
    status = canonical_router.read(canonical_mapping, 0, 1, data);
    if (status == null || status.code != RDMA_SC_STALE_GENERATION)
      `uvm_error(
        "HOST_ROUTE_EPOCH",
        "Host reset did not stale the old mapping"
      )

    canonical_function_h.generation = 2;
    canonical_context = make_context(2, canonical_function_h, null);
    canonical_context.reset_epoch = canonical_coordinator.function_epoch_uid(
      canonical_function_h.function_uid
    );
    status = canonical_router.allocate(
      canonical_context, 32, 8, RDMA_DMA_DEVICE_READ, canonical_host_mapping
    );
    if (status == null || !status.ok() || canonical_host_mapping == null ||
        canonical_host_mapping.reset_epoch != canonical_context.reset_epoch ||
        canonical_context.reset_epoch != 1)
      `uvm_error(
        "HOST_ROUTE_EPOCH",
        "fresh Host-reset request was rejected or used a non-canonical epoch"
      )

    status = canonical_coordinator.request_device_reset();
    if (status == null || !status.ok() ||
        canonical_coordinator.device_epoch() != 1 ||
        canonical_coordinator.function_epoch_uid(
          canonical_function_h.function_uid
        ) != 2)
      `uvm_fatal("HOST_ROUTE_EPOCH", "Device reset epoch publication failed")
    status = canonical_router.read(canonical_host_mapping, 0, 1, data);
    if (status == null || status.code != RDMA_SC_STALE_GENERATION)
      `uvm_error(
        "HOST_ROUTE_EPOCH",
        "Device reset did not stale the Host-reset mapping"
      )

    canonical_function_h.generation = 3;
    canonical_context = make_context(2, canonical_function_h, null);
    canonical_context.reset_epoch = canonical_coordinator.function_epoch_uid(
      canonical_function_h.function_uid
    );
    status = canonical_router.allocate(
      canonical_context, 32, 8, RDMA_DMA_DEVICE_READ, canonical_device_mapping
    );
    if (status == null || !status.ok() || canonical_device_mapping == null ||
        canonical_device_mapping.reset_epoch != canonical_context.reset_epoch ||
        canonical_context.reset_epoch != 2)
      `uvm_error(
        "HOST_ROUTE_EPOCH",
        "fresh Device-reset request was rejected or used a non-canonical epoch"
      )
    // Reset drain 允许旧 mapping 在 stale epoch 下 release；这同时证明
    // canonical scalar 修复没有绕过原有四维 stale/release 边界。
    status = canonical_router.\release (canonical_mapping);
    if (status == null || !status.ok())
      `uvm_error("HOST_ROUTE_EPOCH", "initial stale mapping drain failed")
    status = canonical_router.\release (canonical_host_mapping);
    if (status == null || !status.ok())
      `uvm_error("HOST_ROUTE_EPOCH", "Host-reset stale mapping drain failed")
    status = canonical_router.\release (canonical_device_mapping);
    if (status == null || !status.ok())
      `uvm_error("HOST_ROUTE_EPOCH", "Device-reset mapping release failed")

    // The queue planner stores a detached release-authority snapshot rather
    // than the manager's original object.  Router lookup must resolve that
    // opaque capability and release exactly the original allocation.
    detached_router = rdma_host_mem_router::type_id::create(
      "detached_router");
    opaque_manager = rdma_mock_host_mem::type_id::create("opaque_manager");
    detached_entry = rdma_host_mem_route_entry::type_id::create(
      "detached_entry");
    detached_entry.host_topology_key = 0;
    detached_entry.manager = opaque_manager;
    detached_entries.push_back(detached_entry);
    status = detached_router.configure(detached_entries);
    if (status == null || !status.ok())
      `uvm_fatal("HOST_ROUTE", "detached router configure failed")
    status = detached_router.allocate(context0, 16, 4,
                                      RDMA_DMA_DEVICE_READ,
                                      detached_mapping);
    if (status == null || !status.ok() || detached_mapping == null)
      `uvm_fatal("HOST_ROUTE", "detached router allocation failed")
    detached_authority = null;
    authority_status = detached_mapping.snapshot_release_authority(
      detached_authority);
    if (authority_status == null || !authority_status.ok() ||
        detached_authority == null)
      `uvm_fatal("HOST_ROUTE", "detached release authority snapshot failed")
    // The planner copies checked public geometry onto the opaque authority;
    // reproduce that step here before handing it back to the router.
    detached_authority.copy(detached_mapping);
    status = detached_router.\release (detached_authority);
    if (status == null || !status.ok())
      `uvm_error("HOST_ROUTE", "detached release authority was rejected")

    // manager 返回的 route 畸形时，router 必须先拒绝该 mapping，再通过
    // opaque allocation identity 回滚底层真实 backing；否则异常路径会泄漏。
    malformed_manager = rdma_malformed_host_mgr::type_id::create(
      "malformed_manager");
    malformed_entry = rdma_host_mem_route_entry::type_id::create(
      "malformed_entry");
    malformed_entry.host_topology_key = 0;
    malformed_entry.manager = malformed_manager;
    detached_router = rdma_host_mem_router::type_id::create(
      "malformed_router");
    detached_entries.delete();
    detached_entries.push_back(malformed_entry);
    status = detached_router.configure(detached_entries);
    if (status == null || !status.ok())
      `uvm_fatal("HOST_ROUTE", "malformed router configure failed")
    malformed_mapping = null;
    status = detached_router.allocate(context0, 64, 8,
                                      RDMA_DMA_DEVICE_READ,
                                      malformed_mapping);
    if (status == null || status.code != RDMA_SC_DMA_TRANSLATION)
      `uvm_error("HOST_ROUTE", "malformed manager route was accepted")
    if (malformed_manager.opaque_release_calls != 1)
      `uvm_error("HOST_ROUTE", $sformatf(
        "opaque rollback count is %0d, expected one",
        malformed_manager.opaque_release_calls))
    if (malformed_manager.live_allocations() != 0)
      `uvm_error("HOST_ROUTE", "malformed mapping rollback leaked backing")

    // validator/release 必须先由 router 的 opaque row 选择 stored manager。
    // caller route 即使被篡改，也不能把 release 改投到另一 Host 或提前删 ledger。
    atomic_router = rdma_host_mem_router_probe::type_id::create(
      "failure_atomic_router"
    );
    atomic_manager = rdma_failure_atomic_router_mgr::type_id::create(
      "failure_atomic_manager"
    );
    atomic_entry = rdma_host_mem_route_entry::type_id::create(
      "failure_atomic_entry"
    );
    atomic_entry.host_topology_key = 0;
    atomic_entry.manager = atomic_manager;
    atomic_entries.push_back(atomic_entry);
    status = atomic_router.configure(atomic_entries);
    if (status == null || !status.ok())
      `uvm_fatal("FAILURE_ATOMIC_ROUTE", "router configure failed")
    status = atomic_router.allocate(
      context0, 64, 8, RDMA_DMA_BIDIRECTIONAL, atomic_mapping
    );
    if (status == null || !status.ok() || atomic_mapping == null)
      `uvm_fatal("FAILURE_ATOMIC_ROUTE", "router allocation failed")

    // 普通转发路径同样必须把 manager 的 null status 归一化；写失败不能
    // 推进 router ledger，读失败还必须丢弃调用方可能保留的旧 buffer。
    atomic_manager.return_null_write_once = 1'b1;
    status = atomic_router.write(atomic_mapping, 0, atomic_bytes);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        atomic_router.ledger_count() != 1 ||
        atomic_manager.live_allocations() != 1)
      `uvm_error(
        "FAILURE_ATOMIC_ROUTE_NULL_WRITE",
        "null manager write status was not fail-closed"
      )
    data = '{8'hde, 8'had};
    atomic_manager.return_null_read_once = 1'b1;
    status = atomic_router.read(atomic_mapping, 0, atomic_bytes.size(), data);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        data.size() != 0 || atomic_router.ledger_count() != 1)
      `uvm_error(
        "FAILURE_ATOMIC_ROUTE_NULL_READ",
        "null manager read status retained stale output or changed ledger"
      )
    atomic_manager.return_null_plain_release_once = 1'b1;
    status = atomic_router.\release (atomic_mapping);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        atomic_router.ledger_count() != 1 ||
        atomic_manager.live_allocations() != 1)
      `uvm_error(
        "FAILURE_ATOMIC_ROUTE_NULL_RELEASE",
        "null manager release status retired the router row"
      )

    status = atomic_router.write(atomic_mapping, 0, atomic_bytes);
    if (status == null || !status.ok())
      `uvm_fatal("FAILURE_ATOMIC_ROUTE", "router seed write failed")
    authority_status = atomic_mapping.snapshot_release_authority(
      atomic_authority
    );
    if (authority_status == null || !authority_status.ok() ||
        atomic_authority == null)
      `uvm_fatal("FAILURE_ATOMIC_ROUTE", "authority snapshot failed")
    atomic_authority.copy(atomic_mapping);
    atomic_authority.route.host_topology_key = 32'hffff_fffe;

    status = atomic_router.validate_failure_atomic_release(
      atomic_authority
    );
    if (status == null || !status.ok() ||
        atomic_manager.validation_calls != 1 ||
        atomic_manager.opaque_release_calls != 0 ||
        atomic_router.ledger_count() != 1 ||
        atomic_manager.live_allocations() != 1)
      `uvm_error(
        "FAILURE_ATOMIC_ROUTE_VALIDATE",
        "read-only validation changed ledger or selected the caller route"
      )
    status = atomic_router.read(
      atomic_mapping, 0, atomic_bytes.size(), data
    );
    if (status == null || !status.ok() || data != atomic_bytes)
      `uvm_error(
        "FAILURE_ATOMIC_ROUTE_VALIDATE_READ",
        "validation changed active allocation bytes"
      )

    validation_calls_before = atomic_manager.validation_calls;
    default_mapping = rdma_dma_mapping::type_id::create(
      "failure_atomic_route_default"
    );
    status = atomic_router.validate_failure_atomic_release(default_mapping);
    if (status == null || status.ok() ||
        atomic_manager.validation_calls != validation_calls_before)
      `uvm_error(
        "FAILURE_ATOMIC_ROUTE_UNKNOWN",
        "unknown mapping reached the stored manager"
      )
    foreign_manager = rdma_mock_host_mem::type_id::create(
      "failure_atomic_foreign_manager"
    );
    status = foreign_manager.allocate(
      context0, 64, 8, RDMA_DMA_BIDIRECTIONAL, foreign_mapping
    );
    if (status == null || !status.ok() || foreign_mapping == null)
      `uvm_fatal("FAILURE_ATOMIC_ROUTE", "foreign allocation failed")
    status = atomic_router.validate_failure_atomic_release(foreign_mapping);
    if (status == null || status.ok() ||
        atomic_manager.validation_calls != validation_calls_before)
      `uvm_error(
        "FAILURE_ATOMIC_ROUTE_FOREIGN",
        "foreign allocation reached the stored manager"
      )

    atomic_manager.next_validation_failure = rdma_status::make(
      RDMA_SC_UNKNOWN_HW_ERROR,
      "injected router manager validation failure"
    );
    status = atomic_router.release_opaque(atomic_authority);
    if (status == null || status.code != RDMA_SC_UNKNOWN_HW_ERROR ||
        atomic_manager.opaque_release_calls != 0 ||
        atomic_router.ledger_count() != 1 ||
        atomic_manager.live_allocations() != 1)
      `uvm_error(
        "FAILURE_ATOMIC_ROUTE_VALIDATION_FAILURE",
        "validator failure reached release or changed ledger"
      )
    atomic_manager.return_null_validation_once = 1'b1;
    status = atomic_router.release_opaque(atomic_authority);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        atomic_manager.opaque_release_calls != 0 ||
        atomic_router.ledger_count() != 1 ||
        atomic_manager.live_allocations() != 1)
      `uvm_error(
        "FAILURE_ATOMIC_ROUTE_NULL_VALIDATION",
        "null validator result reached release or changed ledger"
      )

    status = atomic_manager.fail_next(
      "release_opaque",
      rdma_status::make(
        RDMA_SC_UNKNOWN_HW_ERROR,
        "injected router manager release failure"
      )
    );
    if (status == null || !status.ok())
      `uvm_fatal("FAILURE_ATOMIC_ROUTE", "release injection failed")
    status = atomic_router.release_opaque(atomic_authority);
    if (status == null || status.code != RDMA_SC_UNKNOWN_HW_ERROR ||
        atomic_router.ledger_count() != 1 ||
        atomic_manager.live_allocations() != 1)
      `uvm_error(
        "FAILURE_ATOMIC_ROUTE_RELEASE_FAILURE",
        "non-OK manager release changed router or manager ledger"
      )
    atomic_manager.return_null_release_once = 1'b1;
    status = atomic_router.release_opaque(atomic_authority);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        atomic_router.ledger_count() != 1 ||
        atomic_manager.live_allocations() != 1)
      `uvm_error(
        "FAILURE_ATOMIC_ROUTE_NULL_RELEASE",
        "null manager release changed router or manager ledger"
      )
    release_done = 1'b1;
    authority_status = atomic_mapping.release_completion_status(release_done);
    status = atomic_router.read(
      atomic_mapping, 0, atomic_bytes.size(), data
    );
    if (authority_status == null || !authority_status.ok() || release_done ||
        status == null || !status.ok() || data != atomic_bytes)
      `uvm_error(
        "FAILURE_ATOMIC_ROUTE_RETRYABLE",
        "failed release changed seal, bytes or read authority"
      )

    status = atomic_router.release_opaque(atomic_authority);
    if (status == null || !status.ok() ||
        atomic_router.ledger_count() != 0 ||
        atomic_manager.live_allocations() != 0)
      `uvm_error(
        "FAILURE_ATOMIC_ROUTE_RETRY",
        "successful retry did not retire exact ledger row"
      )
    release_done = 1'b0;
    authority_status = atomic_mapping.release_completion_status(release_done);
    if (authority_status == null || !authority_status.ok() || !release_done)
      `uvm_error(
        "FAILURE_ATOMIC_ROUTE_FINAL_SEAL",
        "successful release did not complete shared seal"
      )
    status = atomic_router.validate_failure_atomic_release(atomic_mapping);
    if (status == null || status.ok())
      `uvm_error(
        "FAILURE_ATOMIC_ROUTE_RELEASED",
        "released router mapping retained capability"
      )
    status = foreign_manager.release_opaque(foreign_mapping);
    if (status == null || !status.ok())
      `uvm_error("FAILURE_ATOMIC_ROUTE_FOREIGN", "foreign cleanup failed")

    // Batch109 生命周期边界：router 与 coordinator 必须通过同一个 owner/token pair
    // 建立一对一绑定。active mapping 存在时，跨 coordinator rebind、单侧 legacy detach
    // 和任意一侧 lease release 都必须 fail-closed；释放 mapping 后再走 coordinator facade
    // 的双侧 detach，最后释放 lease，验证失败路径没有偷换旧 authority。
    lifecycle_coordinator_a = rdma_reset_coordinator::type_id::create(
      "lifecycle_coordinator_a"
    );
    lifecycle_coordinator_b = rdma_reset_coordinator::type_id::create(
      "lifecycle_coordinator_b"
    );
    lifecycle_router = rdma_host_mem_router::type_id::create(
      "lifecycle_router"
    );
    lifecycle_manager = rdma_test_host_mgr::type_id::create(
      "lifecycle_manager"
    );
    lifecycle_manager.tag = 32'h7000;
    lifecycle_entry = rdma_host_mem_route_entry::type_id::create(
      "lifecycle_entry"
    );
    lifecycle_entry.host_topology_key = 7;
    lifecycle_entry.manager = lifecycle_manager;
    lifecycle_entries.push_back(lifecycle_entry);
    status = lifecycle_router.configure(lifecycle_entries);
    if (status == null || !status.ok())
      `uvm_fatal("ROUTER_LIFECYCLE", "lifecycle router configure failed")

    // coordinator-bound allocation requires a registered dpu_common Function
    // authority.  Register a PF whose route and global ID match the lifecycle
    // handle before claiming the coordinator lease.
    lifecycle_key = '0;
    lifecycle_key.host_topology_key = 7;
    lifecycle_key.root_id = 7;
    lifecycle_key.function_kind = RDMA_FUNCTION_PF;
    lifecycle_key.vf_index = 0;
    lifecycle_key.bdf = '{segment:0, bus:1, device:7, function_num:0};
    lifecycle_key.parent_pf_bdf = '0;
    lifecycle_identity = rdma_function_identity::type_id::create(
      "lifecycle_identity"
    );
    status = lifecycle_identity.configure(
      lifecycle_key, 32'h701, 32'h7001, 1, 0
    );
    if (status == null || !status.ok())
      `uvm_fatal("ROUTER_LIFECYCLE", "lifecycle identity configure failed")
    lifecycle_coordinator_a.register_function(lifecycle_identity);

    lifecycle_owner_a = rdma_host_mem_route_entry::type_id::create(
      "lifecycle_owner_a"
    );
    lifecycle_owner_b = rdma_host_mem_route_entry::type_id::create(
      "lifecycle_owner_b"
    );
    lifecycle_token_a = 0;
    lifecycle_token_b = 0;
    status = lifecycle_coordinator_a.acquire_lease(
      lifecycle_owner_a, lifecycle_token_a
    );
    if (status == null || !status.ok() || lifecycle_token_a == 0)
      `uvm_fatal("ROUTER_LIFECYCLE", "primary lifecycle lease acquire failed")
    status = lifecycle_coordinator_a.attach_host_router_owned(
      lifecycle_router, lifecycle_owner_a, lifecycle_token_a
    );
    if (status == null || !status.ok() ||
        !lifecycle_coordinator_a.host_router_bound())
      `uvm_fatal("ROUTER_LIFECYCLE", "primary coordinator/router attach failed")

    lifecycle_function_h = rdma_function_handle::type_id::create(
      "lifecycle_function_h"
    );
    lifecycle_function_h.kind = RDMA_RESOURCE_FUNCTION;
    lifecycle_function_h.function_uid = 32'h7001;
    lifecycle_function_h.object_id = 32'h701;
    lifecycle_function_h.generation = 1;
    lifecycle_context = make_context(7, lifecycle_function_h, null);
    status = lifecycle_router.allocate(
      lifecycle_context, 32, 8, RDMA_DMA_DEVICE_READ, lifecycle_mapping
    );
    if (status == null || !status.ok() || lifecycle_mapping == null)
      `uvm_fatal("ROUTER_LIFECYCLE", "active lifecycle mapping allocation failed")

    status = lifecycle_coordinator_a.release_lease(
      lifecycle_owner_a, lifecycle_token_a
    );
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY ||
        !lifecycle_coordinator_a.lease_held() ||
        !lifecycle_coordinator_a.host_router_bound())
      `uvm_error("ROUTER_LIFECYCLE",
                 "lease release bypassed an attached active router")

    status = lifecycle_coordinator_b.acquire_lease(
      lifecycle_owner_b, lifecycle_token_b
    );
    if (status == null || !status.ok() || lifecycle_token_b == 0)
      `uvm_fatal("ROUTER_LIFECYCLE", "foreign lifecycle lease acquire failed")
    // Foreign coordinator 没有自己的 m_host_router 时，也不能把仍由
    // coordinator A 绑定的 router 误判为已完成 detach；否则 B 可以释放自己的
    // lease，而 A/router 双侧 authority 仍然存活。
    status = lifecycle_coordinator_b.detach_host_router_owned(
      lifecycle_router, lifecycle_owner_b, lifecycle_token_b
    );
    if (status == null || status.ok() ||
        !lifecycle_coordinator_a.host_router_bound() ||
        lifecycle_coordinator_b.host_router_bound())
      `uvm_error("ROUTER_LIFECYCLE",
                 "foreign coordinator detached an unowned router")
    status = lifecycle_coordinator_b.attach_host_router_owned(
      lifecycle_router, lifecycle_owner_b, lifecycle_token_b
    );
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY ||
        !lifecycle_coordinator_a.host_router_bound())
      `uvm_error("ROUTER_LIFECYCLE",
                 "foreign coordinator rebound an active router")
    status = lifecycle_router.attach_reset_coordinator_status(
      lifecycle_coordinator_b, 1'b0
    );
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY)
      `uvm_error("ROUTER_LIFECYCLE",
                 "router status attach accepted a non-facade caller")
    lifecycle_router.attach_reset_coordinator(null);
    status = lifecycle_coordinator_a.detach_host_router_owned(
      lifecycle_router, lifecycle_owner_a, lifecycle_token_a
    );
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY ||
        !lifecycle_coordinator_a.host_router_bound())
      `uvm_error("ROUTER_LIFECYCLE",
                 "active mapping allowed single-sided coordinator detach")

    status = lifecycle_router.\release (lifecycle_mapping);
    if (status == null || !status.ok())
      `uvm_fatal("ROUTER_LIFECYCLE", "active lifecycle mapping release failed")
    status = lifecycle_coordinator_a.detach_host_router_owned(
      lifecycle_router, lifecycle_owner_a, lifecycle_token_a
    );
    if (status == null || !status.ok() ||
        lifecycle_coordinator_a.host_router_bound())
      `uvm_error("ROUTER_LIFECYCLE", "bilateral router detach failed after drain")
    status = lifecycle_coordinator_a.release_lease(
      lifecycle_owner_a, lifecycle_token_a
    );
    if (status == null || !status.ok() || lifecycle_coordinator_a.lease_held())
      `uvm_error("ROUTER_LIFECYCLE", "primary lifecycle lease did not release")
    status = lifecycle_coordinator_b.release_lease(
      lifecycle_owner_b, lifecycle_token_b
    );
    if (status == null || !status.ok() || lifecycle_coordinator_b.lease_held())
      `uvm_error("ROUTER_LIFECYCLE", "foreign lifecycle lease did not release")

    // 公开 status seam 不携带 coordinator 内部 capability；即使调用方传入旧的
    // coordinator_initiated 位也不能直接制造 binding。空 router 的成功 attach/detach
    // 只通过 coordinator owned facade 观察，避免测试依赖一个可被任意 caller 伪造的 bit。
    lifecycle_unbound_router = rdma_host_mem_router_probe::type_id::create(
      "lifecycle_unbound_router"
    );
    // coordinator_initiated=1 只是历史兼容 bit；没有 coordinator 当前暂存的 capability
    // 时，任意 caller 传入 fake object 都必须被拒绝，且 coordinator/router 两侧均保持未绑定。
    forged_capability = rdma_host_mem_route_entry::type_id::create(
      "forged_router_attach_capability"
    );
    status = lifecycle_unbound_router.attach_reset_coordinator_status(
      lifecycle_coordinator_b, 1'b1, forged_capability
    );
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY ||
        lifecycle_coordinator_b.host_router_bound() ||
        lifecycle_unbound_router.has_reset_coordinator(lifecycle_coordinator_b))
      `uvm_error("ROUTER_LIFECYCLE",
                 "forged coordinator attach capability changed binding")
    status = lifecycle_unbound_router.attach_reset_coordinator_status(
      lifecycle_coordinator_b, 1'b0
    );
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY)
      `uvm_error("ROUTER_LIFECYCLE",
                 "unbound router accepted a non-facade coordinator attach")
    status = lifecycle_coordinator_b.acquire_lease(
      lifecycle_owner_b, lifecycle_token_b
    );
    if (status == null || !status.ok() || lifecycle_token_b == 0)
      `uvm_error("ROUTER_LIFECYCLE",
                 "empty-router facade lease acquire failed")
    // m_host_router 为空且目标 router 也未绑定时，detach 仍须返回明确错误，
    // 不能以幂等 success 掩盖调用方传错生命周期对象。
    status = lifecycle_coordinator_b.detach_host_router_owned(
      lifecycle_unbound_router, lifecycle_owner_b, lifecycle_token_b
    );
    if (status == null || status.ok() ||
        lifecycle_coordinator_b.host_router_bound() ||
        lifecycle_unbound_router.has_reset_coordinator(null) == 1'b0)
      `uvm_error("ROUTER_LIFECYCLE",
                 "unbound router detach was reported as success")
    status = lifecycle_coordinator_b.attach_host_router_owned(
      lifecycle_unbound_router, lifecycle_owner_b, lifecycle_token_b
    );
    if (status == null || !status.ok())
      `uvm_error("ROUTER_LIFECYCLE", status == null ?
                 "coordinator facade attach returned null" :
                 $sformatf("coordinator facade could not attach an empty router: %s",
                           status.message))
    status = lifecycle_coordinator_b.detach_host_router_owned(
      lifecycle_unbound_router, lifecycle_owner_b, lifecycle_token_b
    );
    if (status == null || !status.ok())
      `uvm_error("ROUTER_LIFECYCLE",
                 "coordinator facade could not detach an empty router")
    status = lifecycle_coordinator_b.release_lease(
      lifecycle_owner_b, lifecycle_token_b
    );
    if (status == null || !status.ok())
      `uvm_error("ROUTER_LIFECYCLE",
                 "empty-router facade lease did not release")
    // Batch112：tokenless dataplane 只接受正常 admission；reset transaction 期间
    // allocate/write/read 必须 fail closed，而 release/release_opaque 继续作为明确的
    // cleanup seam 排空 current/stale mapping，不能被 owner/token gate 误伤。
    dataplane_router = rdma_host_mem_router_probe::type_id::create(
      "dataplane_router"
    );
    dataplane_manager = rdma_reentrant_reset_host_mgr::type_id::create(
      "dataplane_manager"
    );
    dataplane_entry = rdma_host_mem_route_entry::type_id::create(
      "dataplane_entry"
    );
    dataplane_entry.host_topology_key = 8;
    dataplane_entry.manager = dataplane_manager;
    dataplane_entries.push_back(dataplane_entry);
    status = dataplane_router.configure(dataplane_entries);
    if (status == null || !status.ok())
      `uvm_fatal("ROUTER_ADMISSION", "dataplane router configure failed")
    dataplane_coordinator = rdma_host_mem_router_reset_probe::type_id::create(
      "dataplane_coordinator"
    );
    dataplane_key = '0;
    dataplane_key.host_topology_key = 8;
    dataplane_key.root_id = 8;
    dataplane_key.function_kind = RDMA_FUNCTION_PF;
    dataplane_key.vf_index = 0;
    dataplane_key.bdf = '{segment:0, bus:1, device:8, function_num:0};
    dataplane_key.parent_pf_bdf = '0;
    dataplane_identity = rdma_function_identity::type_id::create(
      "dataplane_identity"
    );
    status = dataplane_identity.configure(
      dataplane_key, 32'h881, 32'h8801, 1, 0
    );
    if (status == null || !status.ok())
      `uvm_fatal("ROUTER_ADMISSION", "dataplane identity configure failed")
    dataplane_coordinator.register_function(dataplane_identity);
    if (dataplane_coordinator.function_count() != 1)
      `uvm_fatal("ROUTER_ADMISSION", "dataplane registration failed")
    dataplane_owner = rdma_host_mem_route_entry::type_id::create(
      "dataplane_owner"
    );
    status = dataplane_coordinator.acquire_lease(
      dataplane_owner, dataplane_token
    );
    if (status == null || !status.ok() || dataplane_token == 0)
      `uvm_fatal("ROUTER_ADMISSION", "dataplane lease acquire failed")
    status = dataplane_coordinator.attach_host_router_owned(
      dataplane_router, dataplane_owner, dataplane_token
    );
    if (status == null || !status.ok())
      `uvm_fatal("ROUTER_ADMISSION", "dataplane router attach failed")
    dataplane_function_h = rdma_function_handle::type_id::create(
      "dataplane_function_h"
    );
    dataplane_function_h.kind = RDMA_RESOURCE_FUNCTION;
    dataplane_function_h.function_uid = 32'h8801;
    dataplane_function_h.object_id = 32'h881;
    dataplane_function_h.generation = 1;
    dataplane_context = make_context(
      8, dataplane_function_h, null
    );
    status = dataplane_router.allocate(
      dataplane_context, 32, 8, RDMA_DMA_DEVICE_READ,
      dataplane_mapping
    );
    if (status == null || !status.ok() || dataplane_mapping == null)
      `uvm_fatal("ROUTER_ADMISSION", "initial dataplane allocation failed")
    status = dataplane_router.allocate(
      dataplane_context, 32, 8, RDMA_DMA_DEVICE_READ,
      dataplane_opaque_mapping
    );
    if (status == null || !status.ok() || dataplane_opaque_mapping == null)
      `uvm_fatal("ROUTER_ADMISSION", "opaque dataplane allocation failed")
    status = dataplane_router.allocate(
      dataplane_context, 32, 8, RDMA_DMA_DEVICE_READ,
      dataplane_stale_mapping
    );
    if (status == null || !status.ok() || dataplane_stale_mapping == null)
      `uvm_fatal("ROUTER_ADMISSION", "stale dataplane allocation failed")
    dataplane_ledger_before = dataplane_router.ledger_count();
    status = dataplane_router.write(dataplane_mapping, 0, atomic_bytes);
    if (status == null || !status.ok())
      `uvm_error("ROUTER_ADMISSION", "normal tokenless write was rejected")
    status = dataplane_router.read(
      dataplane_mapping, 0, atomic_bytes.size(), data
    );
    if (status == null || !status.ok() || data.size() != atomic_bytes.size())
      `uvm_error("ROUTER_ADMISSION", "normal tokenless read was rejected")

    // publication-only guard 不推进 reset transaction，但同样必须阻止 tokenless
    // dataplane 入口；释放路径不在本场景调用，避免把 cleanup seam 与普通数据面混淆。
    dataplane_allocate_calls_before = dataplane_manager.calls.size();
    status = dataplane_coordinator.enter_publication_probe();
    if (status == null || !status.ok() ||
        dataplane_coordinator.reset_transaction_active())
      `uvm_error("ROUTER_ADMISSION",
                 "publication-only guard did not open as expected")
    status = dataplane_router.allocate(
      dataplane_context, 32, 8, RDMA_DMA_DEVICE_READ,
      dataplane_rejected_mapping
    );
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY ||
        dataplane_manager.calls.size() != dataplane_allocate_calls_before ||
        dataplane_router.ledger_count() != dataplane_ledger_before ||
        dataplane_rejected_mapping != null)
      `uvm_error("ROUTER_ADMISSION",
                 "publication-only guard admitted tokenless allocation")
    dataplane_write_calls_before = dataplane_manager.calls.size();
    status = dataplane_router.write(dataplane_mapping, 0, atomic_bytes);
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY ||
        dataplane_manager.calls.size() != dataplane_write_calls_before)
      `uvm_error("ROUTER_ADMISSION",
                 "publication-only guard admitted tokenless write")
    data = new[atomic_bytes.size()];
    dataplane_read_calls_before = dataplane_manager.calls.size();
    status = dataplane_router.read(
      dataplane_mapping, 0, atomic_bytes.size(), data
    );
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY ||
        dataplane_manager.calls.size() != dataplane_read_calls_before ||
        data.size() != 0)
      `uvm_error("ROUTER_ADMISSION",
                 "publication-only guard admitted tokenless read")
    dataplane_coordinator.leave_publication_probe();
    status = dataplane_router.write(dataplane_mapping, 0, atomic_bytes);
    if (status == null || !status.ok())
      `uvm_error("ROUTER_ADMISSION",
                 "tokenless write did not recover after publication guard")
    data = new[atomic_bytes.size()];
    status = dataplane_router.read(
      dataplane_mapping, 0, atomic_bytes.size(), data
    );
    if (status == null || !status.ok() || data.size() != atomic_bytes.size())
      `uvm_error("ROUTER_ADMISSION",
                 "tokenless read did not recover after publication guard")

    // manager.allocate() 的同步 callback 可以在 router 首次 admission 之后开启
    // reset transaction；router 必须在 ledger commit 前再次 admission，并通过
    // opaque identity 回滚这次尚未登记的 backing。
    dataplane_manager.callback_coordinator = dataplane_coordinator;
    dataplane_manager.callback_owner = dataplane_owner;
    dataplane_manager.callback_token = dataplane_token;
    dataplane_manager.trigger_reset_once = 1'b1;
    dataplane_allocate_calls_before = dataplane_manager.calls.size();
    status = dataplane_router.allocate(
      dataplane_context, 32, 8, RDMA_DMA_DEVICE_READ,
      dataplane_reentrant_mapping
    );
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY ||
        dataplane_manager.callback_calls != 1 ||
        dataplane_manager.callback_status == null ||
        !dataplane_manager.callback_status.ok() ||
        dataplane_manager.calls.size() != dataplane_allocate_calls_before + 2 ||
        dataplane_manager.live_allocations() != dataplane_ledger_before ||
        dataplane_router.ledger_count() != dataplane_ledger_before ||
        dataplane_reentrant_mapping != null)
      `uvm_error("ROUTER_ADMISSION",
                 "reentrant reset admitted or leaked tokenless allocation")
    status = dataplane_coordinator.end_reset(
      dataplane_owner, dataplane_token
    );
    if (status == null || !status.ok())
      `uvm_fatal("ROUTER_ADMISSION",
                 "reentrant dataplane reset transaction did not close")

    status = dataplane_coordinator.begin_reset(
      dataplane_owner, dataplane_token
    );
    if (status == null || !status.ok())
      `uvm_fatal("ROUTER_ADMISSION", "dataplane reset begin failed")
    dataplane_allocate_calls_before = dataplane_manager.calls.size();
    status = dataplane_router.allocate(
      dataplane_context, 32, 8, RDMA_DMA_DEVICE_READ,
      dataplane_rejected_mapping
    );
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY ||
        dataplane_manager.calls.size() != dataplane_allocate_calls_before ||
        dataplane_router.ledger_count() != dataplane_ledger_before ||
        dataplane_rejected_mapping != null)
      `uvm_error("ROUTER_ADMISSION",
                 "active reset admitted tokenless allocation")
    dataplane_write_calls_before = dataplane_manager.calls.size();
    status = dataplane_router.write(dataplane_mapping, 0, atomic_bytes);
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY ||
        dataplane_manager.calls.size() != dataplane_write_calls_before)
      `uvm_error("ROUTER_ADMISSION",
                 "active reset admitted tokenless write")
    data = new[atomic_bytes.size()];
    dataplane_read_calls_before = dataplane_manager.calls.size();
    status = dataplane_router.read(
      dataplane_mapping, 0, atomic_bytes.size(), data
    );
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY ||
        dataplane_manager.calls.size() != dataplane_read_calls_before ||
        data.size() != 0)
      `uvm_error("ROUTER_ADMISSION",
                 "active reset admitted tokenless read or retained data")
    status = dataplane_router.\release (dataplane_opaque_mapping);
    if (status == null || !status.ok() ||
        dataplane_router.ledger_count() != dataplane_ledger_before - 1)
      `uvm_error("ROUTER_ADMISSION",
                 "active reset blocked cleanup release")
    status = dataplane_coordinator.request_host_reset(
      8, dataplane_owner, dataplane_token
    );
    if (status == null || !status.ok())
      `uvm_fatal("ROUTER_ADMISSION", "dataplane host reset publication failed")
    status = dataplane_router.release_opaque(dataplane_stale_mapping);
    if (status == null || !status.ok())
      `uvm_error("ROUTER_ADMISSION",
                 "active reset blocked stale opaque cleanup")
    status = dataplane_router.\release (dataplane_mapping);
    if (status == null || !status.ok())
      `uvm_error("ROUTER_ADMISSION",
                 "active reset blocked final cleanup release")
    status = dataplane_coordinator.end_reset(
      dataplane_owner, dataplane_token
    );
    if (status == null || !status.ok() || dataplane_router.ledger_count() != 0)
      `uvm_error("ROUTER_ADMISSION",
                 "dataplane reset transaction did not close cleanly")

    // Host reset 后旧 mapping 已排空；fresh context 必须携带 coordinator 发布的
    // Function incarnation epoch，验证 tokenless dataplane 能在新代际恢复工作。
    dataplane_function_h.generation = 2;
    dataplane_context.reset_epoch = dataplane_coordinator.function_epoch_uid(
      dataplane_function_h.function_uid
    );
    dataplane_context.epoch_valid = 1'b1;
    status = dataplane_router.allocate(
      dataplane_context, 32, 8, RDMA_DMA_DEVICE_READ,
      dataplane_post_reset_mapping
    );
    if (status == null || !status.ok() || dataplane_post_reset_mapping == null)
      `uvm_error("ROUTER_ADMISSION",
                 "fresh context allocation failed after Host reset")
    status = dataplane_router.write(
      dataplane_post_reset_mapping, 0, atomic_bytes
    );
    if (status == null || !status.ok())
      `uvm_error("ROUTER_ADMISSION",
                 "fresh context write failed after Host reset")
    data = new[atomic_bytes.size()];
    status = dataplane_router.read(
      dataplane_post_reset_mapping, 0, atomic_bytes.size(), data
    );
    if (status == null || !status.ok() || data.size() != atomic_bytes.size())
      `uvm_error("ROUTER_ADMISSION",
                 "fresh context read failed after Host reset")
    status = dataplane_router.\release (dataplane_post_reset_mapping);
    if (status == null || !status.ok() || dataplane_router.ledger_count() != 0)
      `uvm_error("ROUTER_ADMISSION",
                 "fresh context cleanup failed after Host reset")
    status = dataplane_coordinator.detach_host_router_owned(
      dataplane_router, dataplane_owner, dataplane_token
    );
    if (status == null || !status.ok())
      `uvm_error("ROUTER_ADMISSION", "dataplane router detach failed")
    status = dataplane_coordinator.release_lease(
      dataplane_owner, dataplane_token
    );
    if (status == null || !status.ok())
      `uvm_error("ROUTER_ADMISSION", "dataplane lease release failed")
    phase.drop_objection(this);
  endtask
endclass
