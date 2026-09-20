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
  //       authority 篡改、Host reset 过期和缺失 epoch 请求等错误路径。
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
    rdma_status authority_status;
    rdma_host_mem_route_entry detached_entries[$];
    byte data[];
    byte atomic_bytes[] = '{8'h19, 8'h2a, 8'h3b, 8'h4c};
    bit release_done;
    int unsigned validation_calls_before;
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
    phase.drop_objection(this);
  endtask
endclass
