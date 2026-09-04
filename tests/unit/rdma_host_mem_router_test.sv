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
  function new(string name = "mgr");
    super.new(name);
    tag = 0;
  endfunction

  // 功能：模拟 Host-memory allocation，复制请求中的 Function/owner authority 和 requester
  //       BDF，返回一个 active mapping；tag 决定可观察的 IOVA 值。
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
    return rdma_status::success();
  endfunction

  // 功能：模拟写入成功，不实际访问 Host memory；用于确认 router 已完成前置校验。
  function rdma_status write(
    rdma_dma_mapping mapping,
    longint unsigned offset,
    byte data[]
  );
    return rdma_status::success();
  endfunction

  // 功能：模拟读取成功并返回指定长度的零字节数组；不承担真实 backing 生命周期。
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
  function rdma_status \release (rdma_dma_mapping mapping);
    return rdma_status::success();
  endfunction
endclass

class rdma_host_mem_router_test extends uvm_test;
  `uvm_component_utils(rdma_host_mem_router_test)

  // 功能：构造 UVM 测试组件；场景搭建和断言集中在 run_phase()。
  function new(string name = "rdma_host_mem_router_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：按 Host key 构造带完整 route、requester BDF 和初始 epoch 的 DMA 请求上下文，
  //       供两个 Host 使用相同 IOVA 的隔离测试复用。
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
  task run_phase(uvm_phase phase);
    rdma_host_mem_router router;
    rdma_host_mem_route_entry entries[$];
    rdma_test_host_mgr manager0, manager1;
    rdma_dma_request_context context0, context1, missing_epoch;
    rdma_function_handle function_h;
    rdma_handle owner_h;
    rdma_dma_mapping mapping0, mapping1;
    byte data[];
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

    missing_epoch = make_context(0, function_h, owner_h);
    missing_epoch.epoch_valid = 1'b0;
    status = router.allocate(missing_epoch, 16, 4, RDMA_DMA_DEVICE_READ,
                             mapping1);
    if (status.ok())
      `uvm_error("HOST_ROUTE", "DMA request without epoch was accepted")
    phase.drop_objection(this);
  endtask
endclass
